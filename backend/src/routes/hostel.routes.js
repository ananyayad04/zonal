import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { env } from '../config/env.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole } from '../middleware/auth.js';
import {
  allotWorker,
  releaseWorker,
  findAllFreeWorkersCampusWide,
} from '../services/allocation.js';
import { transition, notify, notifyMany } from '../services/workflow.js';
import {
  complaintInclude,
  serializeComplaint,
  loadComplaintForResponse,
} from '../utils/serialize.js';

const router = Router();

router.use(authenticate, requireRole('ADMIN', 'WORKER_SUPERVISOR', 'WARDEN'));

/**
 * A Warden is locked to their own hostel. Admin/Supervisor may look at one
 * hostel via ?landmarkId=, or leave it off for every hostel at once - they
 * are campus-wide by design, unlike a Warden.
 */
function hostelFilter(req) {
  if (req.user.role === 'WARDEN') {
    if (!req.user.hostelOwned) {
      throw new ApiError(403, 'You are not currently assigned to any hostel');
    }
    return { landmarkId: req.user.hostelOwned.id };
  }
  const landmarkId = req.query.landmarkId ?? req.body?.landmarkId;
  return landmarkId ? { landmarkId } : {};
}

/** GET /api/hostel/dashboard */
router.get(
  '/dashboard',
  asyncHandler(async (req, res) => {
    const where = { isHostelComplaint: true, ...hostelFilter(req) };

    const [byStatus, actionQueue] = await Promise.all([
      prisma.complaint.groupBy({ by: ['status'], where, _count: { _all: true } }),
      prisma.complaint.findMany({
        where: { ...where, status: 'ALLOTTED_TO_HOSTEL_STAFF' },
        include: complaintInclude,
        orderBy: { submittedAt: 'asc' },
      }),
    ]);

    res.json({
      counts: Object.fromEntries(byStatus.map((r) => [r.status, r._count._all])),
      needsAllotment: actionQueue.map(serializeComplaint),
    });
  }),
);

/** GET /api/hostel/complaints - filterable by status. */
router.get(
  '/complaints',
  asyncHandler(async (req, res) => {
    const { status } = req.query;
    const complaints = await prisma.complaint.findMany({
      where: { isHostelComplaint: true, ...hostelFilter(req), ...(status ? { status } : {}) },
      include: complaintInclude,
      orderBy: { submittedAt: 'desc' },
    });
    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/** GET /api/hostel/free-workers - every free worker on campus, by zone. */
router.get(
  '/free-workers',
  asyncHandler(async (_req, res) => {
    res.json({ zones: await findAllFreeWorkersCampusWide() });
  }),
);

/** Load a hostel complaint and confirm the caller may act on it. */
async function loadOwnHostelComplaint(req) {
  const complaint = await prisma.complaint.findUnique({
    where: { id: req.params.id },
    include: { zone: true },
  });
  if (!complaint) throw new ApiError(404, 'Complaint not found');
  if (!complaint.isHostelComplaint) throw new ApiError(400, 'This is not a hostel complaint');

  if (req.user.role === 'WARDEN' && complaint.assignedWardenId !== req.user.id) {
    throw new ApiError(403, 'This complaint belongs to another hostel');
  }
  return complaint;
}

/** POST /api/hostel/complaints/:id/allot  { workerUserId, instructions?, durationHours? } */
router.post(
  '/complaints/:id/allot',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      workerUserId: z.string().min(1),
      instructions: z.string().trim().max(500).optional(),
      durationHours: z.number().positive().max(2160).optional(),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'workerUserId is required');

    const complaint = await loadOwnHostelComplaint(req);
    if (!['ALLOTTED_TO_HOSTEL_STAFF', 'ESCALATED', 'REOPENED'].includes(complaint.status)) {
      throw new ApiError(409, `A complaint in ${complaint.status} cannot be allotted`);
    }

    const updated = await allotWorker({
      complaint: { ...complaint, zoneName: complaint.zone.name },
      workerUserId: parsed.data.workerUserId,
      actor: req.user,
      instructions: parsed.data.instructions,
      durationHours: parsed.data.durationHours,
    });

    res.json({ complaint: serializeComplaint(updated), message: 'Worker allotted.' });
  }),
);

/**
 * POST /api/hostel/complaints/:id/approve  { note }
 * Warden or Worker Supervisor: the reporting student does NOT get the usual
 * confirm/reopen step for a hostel complaint - either of these approving
 * alone closes it. A Supervisor is campus-wide and not tied to one hostel,
 * so loadOwnHostelComplaint's own-hostel check only applies to WARDEN.
 */
router.post(
  '/complaints/:id/approve',
  requireRole('WARDEN', 'WORKER_SUPERVISOR'),
  asyncHandler(async (req, res) => {
    const schema = z.object({
      note: z.string({ required_error: 'Say a few words about the work' }).trim().min(3).max(500),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, parsed.error.flatten().fieldErrors.note?.[0] ?? 'A note is required');
    }

    const complaint = await loadOwnHostelComplaint(req);
    if (complaint.status !== 'WORK_DONE') {
      throw new ApiError(409, 'This complaint is not waiting for your approval');
    }

    await releaseWorker(complaint.assignedWorkerId, { completed: true });

    await transition({
      complaintId: complaint.id,
      toStatus: 'CLOSED',
      actor: req.user,
      note: `${req.user.name} approved the work: ${parsed.data.note}`,
      data: { satisfaction: 'SATISFIED', feedbackNote: parsed.data.note },
    });

    await notifyMany([
      {
        userId: complaint.assignedWorkerId,
        complaintId: complaint.id,
        title: 'Work approved',
        body: `${complaint.ref} was approved by ${req.user.name}. "${parsed.data.note}"`,
      },
      {
        userId: complaint.reporterId,
        complaintId: complaint.id,
        title: 'Complaint closed',
        body: `${complaint.ref} has been closed.`,
      },
    ]);

    const closed = await loadComplaintForResponse(prisma, complaint.id);
    res.json({ complaint: serializeComplaint(closed), message: 'Complaint closed.' });
  }),
);

/**
 * POST /api/hostel/complaints/:id/reject-completion  { note }
 * Warden or Worker Supervisor mirror of the reporter's "not satisfied"
 * branch: back to the same worker once, then escalated to the admin.
 */
router.post(
  '/complaints/:id/reject-completion',
  requireRole('WARDEN', 'WORKER_SUPERVISOR'),
  asyncHandler(async (req, res) => {
    const schema = z.object({
      note: z.string({ required_error: 'Say a few words about the work' }).trim().min(3).max(500),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, parsed.error.flatten().fieldErrors.note?.[0] ?? 'A note is required');
    }

    const complaint = await loadOwnHostelComplaint(req);
    if (complaint.status !== 'WORK_DONE') {
      throw new ApiError(409, 'This complaint is not waiting for your approval');
    }

    const nextReopenCount = complaint.reopenCount + 1;
    const exhausted = nextReopenCount > env.maxReopenCount;

    if (exhausted) {
      await releaseWorker(complaint.assignedWorkerId, { completed: false });

      await transition({
        complaintId: complaint.id,
        toStatus: 'ESCALATED',
        actor: req.user,
        note: `${req.user.name} rejected ${nextReopenCount} times - escalated to admin`,
        data: {
          satisfaction: 'UNSATISFIED',
          unsatisfiedNote: parsed.data.note,
          reopenCount: nextReopenCount,
          escalationReason: 'HOSTEL_REJECTED_TWICE',
          assignedWorkerId: null,
        },
      });

      const admins = await prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } });
      await notifyMany([
        ...admins.map((a) => ({
          userId: a.id,
          complaintId: complaint.id,
          title: 'Hostel complaint escalated',
          body: `${complaint.ref} was rejected more than once.`,
        })),
        {
          userId: complaint.reporterId,
          complaintId: complaint.id,
          title: 'Complaint escalated to admin',
          body: `${complaint.ref} was rejected again and is now with the admin.`,
        },
      ]);

      const escalated = await loadComplaintForResponse(prisma, complaint.id);
      return res.json({
        complaint: serializeComplaint(escalated),
        message: 'This has been escalated to the campus admin.',
      });
    }

    await transition({
      complaintId: complaint.id,
      toStatus: 'REOPENED',
      actor: req.user,
      note: `${req.user.name} not satisfied: ${parsed.data.note}`,
      data: {
        satisfaction: 'UNSATISFIED',
        unsatisfiedNote: parsed.data.note,
        reopenCount: nextReopenCount,
      },
    });

    await notifyMany([
      {
        userId: complaint.assignedWorkerId,
        complaintId: complaint.id,
        title: 'Work sent back',
        body: `${complaint.ref}: ${parsed.data.note}. Please redo it.`,
      },
      {
        userId: complaint.reporterId,
        complaintId: complaint.id,
        title: 'Complaint reopened',
        body: `${complaint.ref} was sent back by ${req.user.name}.`,
      },
    ]);

    const reopened = await loadComplaintForResponse(prisma, complaint.id);
    res.json({ complaint: serializeComplaint(reopened), message: 'Sent back to the worker.' });
  }),
);

export { router as hostelRouter };
