import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole, requireApprovedWorker } from '../middleware/auth.js';
import { uploadMedia } from '../middleware/upload.js';
import { transition, notify } from '../services/workflow.js';
import { releaseWorker } from '../services/allocation.js';
import { startTask, completeTask } from '../services/taskActions.js';
import {
  complaintInclude,
  serializeComplaint,
  loadComplaintForResponse,
} from '../utils/serialize.js';

const router = Router();

router.use(authenticate, requireRole('WORKER'));

/**
 * GET /api/worker/status
 * Deliberately NOT behind the approval gate - an unverified worker needs this
 * to render their "waiting for admin verification" screen.
 */
router.get(
  '/status',
  asyncHandler(async (req, res) => {
    const profile = await prisma.workerProfile.findUnique({
      where: { userId: req.user.id },
      include: { zone: { select: { id: true, code: true, name: true, label: true, colorHex: true } } },
    });
    if (!profile) throw new ApiError(404, 'No worker profile on this account');

    res.json({
      approvalStatus: profile.approvalStatus,
      rejectionNote: profile.rejectionNote,
      dutyStatus: profile.dutyStatus,
      availability: profile.availability,
      activeTaskCount: profile.activeTaskCount,
      tasksCompletedToday: profile.tasksCompletedToday,
      tasksCompletedTotal: profile.tasksCompletedTotal,
      zone: profile.zone,
    });
  }),
);

// Everything past this point requires admin verification.
router.use(requireApprovedWorker);

/**
 * POST /api/worker/duty  { dutyStatus: "ON" | "OFF" }
 * Clocking off is refused while holding a live task, otherwise a complaint
 * would be stranded with nobody accountable for it.
 */
router.post(
  '/duty',
  asyncHandler(async (req, res) => {
    const schema = z.object({ dutyStatus: z.enum(['ON', 'OFF']) });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'dutyStatus must be ON or OFF');

    const profile = await prisma.workerProfile.findUnique({ where: { userId: req.user.id } });

    if (parsed.data.dutyStatus === 'OFF' && profile.activeTaskCount > 0) {
      throw new ApiError(409, 'Finish or hand back your current task before going off duty');
    }

    const updated = await prisma.workerProfile.update({
      where: { userId: req.user.id },
      data: { dutyStatus: parsed.data.dutyStatus },
    });

    res.json({
      dutyStatus: updated.dutyStatus,
      availability: updated.availability,
      message: updated.dutyStatus === 'ON' ? 'You are on duty.' : 'You are off duty.',
    });
  }),
);

/** GET /api/worker/tasks - live task first, then recent history. */
router.get(
  '/tasks',
  asyncHandler(async (req, res) => {
    const [active, history] = await Promise.all([
      prisma.complaint.findMany({
        where: {
          assignedWorkerId: req.user.id,
          status: { in: ['ALLOTTED_TO_WORKER', 'IN_PROGRESS', 'REOPENED', 'WORK_DONE'] },
        },
        include: complaintInclude,
        orderBy: { allottedWorkerAt: 'asc' },
      }),
      prisma.complaint.findMany({
        where: {
          assignedWorkerId: req.user.id,
          status: { in: ['CLOSED', 'AUTO_CLOSED'] },
        },
        include: complaintInclude,
        orderBy: { closedAt: 'desc' },
        take: 30,
      }),
    ]);

    res.json({
      active: active.map(serializeComplaint),
      history: history.map(serializeComplaint),
    });
  }),
);

/** Load a task and confirm it really belongs to this worker. */
async function loadOwnTask(req) {
  const complaint = await prisma.complaint.findUnique({
    where: { id: req.params.id },
    include: { zone: true },
  });
  if (!complaint) throw new ApiError(404, 'Task not found');
  if (complaint.assignedWorkerId !== req.user.id) {
    throw new ApiError(403, 'This task is not assigned to you');
  }
  return complaint;
}

/** POST /api/worker/tasks/:id/start */
router.post(
  '/tasks/:id/start',
  asyncHandler(async (req, res) => {
    const complaint = await loadOwnTask(req);
    const result = await startTask({ complaint, actor: req.user, workerName: req.user.name });
    res.json(result);
  }),
);

/**
 * POST /api/worker/tasks/:id/done
 *
 * Proof of work is compulsory: at least one AFTER attachment. Without it the
 * resident has nothing to judge, and the satisfaction step is meaningless.
 *
 * Note the worker is NOT released here - they stay attached until the resident
 * responds, so a rejection can go straight back to the same person.
 */
router.post(
  '/tasks/:id/done',
  uploadMedia.array('media', 5),
  asyncHandler(async (req, res) => {
    const complaint = await loadOwnTask(req);
    const result = await completeTask({
      complaint,
      actor: req.user,
      files: req.files,
      mediaMetaRaw: req.body?.mediaMeta,
      note: req.body?.note,
    });
    res.json(result);
  }),
);

/**
 * POST /api/worker/tasks/:id/hand-back  { reason }
 * Escape hatch - a worker who cannot do the job (wrong tools, unsafe, wrong
 * location) returns it to their officer instead of sitting on it until the
 * SLA blows.
 */
router.post(
  '/tasks/:id/hand-back',
  asyncHandler(async (req, res) => {
    const schema = z.object({ reason: z.string().min(3).max(500) });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'A reason is required');

    const complaint = await loadOwnTask(req);
    if (!['ALLOTTED_TO_WORKER', 'IN_PROGRESS', 'REOPENED'].includes(complaint.status)) {
      throw new ApiError(409, 'This task cannot be handed back');
    }

    await releaseWorker(req.user.id, { completed: false });

    await transition({
      complaintId: complaint.id,
      toStatus: 'ALLOTTED_TO_OFFICER',
      actor: req.user,
      note: `Handed back by ${req.user.name}: ${parsed.data.reason}`,
      data: { assignedWorkerId: null },
    });
    const updated = await loadComplaintForResponse(prisma, complaint.id);

    await notify({
      userId: complaint.assignedOfficerId,
      complaintId: complaint.id,
      title: 'Task handed back',
      body: `${req.user.name} returned ${complaint.ref}: ${parsed.data.reason}`,
    });

    res.json({ complaint: serializeComplaint(updated), message: 'Returned to your zone officer.' });
  }),
);

export { router as workerRouter };


