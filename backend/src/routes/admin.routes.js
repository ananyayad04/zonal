import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole } from '../middleware/auth.js';
import { transition, notify, notifyMany } from '../services/workflow.js';
import { routeToZoneOfficer, allotWorker, findFreeWorkers } from '../services/allocation.js';
import {
  complaintInclude,
  serializeComplaint,
  loadComplaintForResponse,
} from '../utils/serialize.js';

const router = Router();

router.use(authenticate, requireRole('ADMIN'));

/** GET /api/admin/dashboard - the two queues the admin must clear, plus totals. */
router.get(
  '/dashboard',
  asyncHandler(async (_req, res) => {
    const [pendingWorkers, pendingOfficers, pendingComplaints, escalated, byStatus, zones] =
      await Promise.all([
      prisma.workerProfile.count({ where: { approvalStatus: 'PENDING' } }),
      prisma.officerProfile.count({ where: { approvalStatus: 'PENDING' } }),
      prisma.complaint.count({ where: { status: 'UNDER_REVIEW' } }),
      prisma.complaint.count({ where: { status: 'ESCALATED' } }),
      prisma.complaint.groupBy({ by: ['status'], _count: { _all: true } }),
      prisma.zone.findMany({ orderBy: { code: 'asc' }, include: { officer: true } }),
    ]);

    const zoneStats = await Promise.all(
      zones.map(async (z) => {
        const [open, closed, free, total] = await Promise.all([
          prisma.complaint.count({
            where: { zoneId: z.id, status: { notIn: ['CLOSED', 'AUTO_CLOSED', 'REJECTED_INVALID'] } },
          }),
          prisma.complaint.count({ where: { zoneId: z.id, status: { in: ['CLOSED', 'AUTO_CLOSED'] } } }),
          (await findFreeWorkers(z.id)).length,
          prisma.workerProfile.count({ where: { zoneId: z.id, approvalStatus: 'ACTIVE' } }),
        ]);
        return {
          code: z.code,
          name: z.name,
          label: z.label,
          colorHex: z.colorHex,
          officer: z.officer ? { id: z.officer.id, name: z.officer.name } : null,
          openComplaints: open,
          closedComplaints: closed,
          workersFree: free,
          workersTotal: total,
        };
      }),
    );

    res.json({
      queues: { pendingWorkers, pendingOfficers, pendingComplaints, escalated },
      statusCounts: Object.fromEntries(byStatus.map((r) => [r.status, r._count._all])),
      zones: zoneStats,
    });
  }),
);

// ---------------------------------------------------------------------------
// Worker verification
// ---------------------------------------------------------------------------

/** GET /api/admin/workers?status=PENDING */
router.get(
  '/workers',
  asyncHandler(async (req, res) => {
    const status = req.query.status ?? 'PENDING';

    const workers = await prisma.workerProfile.findMany({
      where: { approvalStatus: status },
      include: {
        user: { select: { id: true, name: true, email: true, phone: true, createdAt: true } },
        zone: { select: { code: true, name: true, label: true } },
      },
      orderBy: { createdAt: 'asc' },
    });

    res.json({
      workers: workers.map((w) => ({
        userId: w.userId,
        name: w.user.name,
        email: w.user.email,
        phone: w.user.phone,
        registeredAt: w.user.createdAt,
        zone: w.zone,
        idProofUrl: w.idProofUrl,
        approvalStatus: w.approvalStatus,
        dutyStatus: w.dutyStatus,
        availability: w.availability,
        tasksCompletedTotal: w.tasksCompletedTotal,
      })),
    });
  }),
);

/**
 * POST /api/admin/workers/:userId/verify  { approve: bool, note? }
 * This is the onboarding gate - until it passes, the worker cannot be
 * allotted a single task.
 */
router.post(
  '/workers/:userId/verify',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      approve: z.coerce.boolean(),
      note: z.string().max(500).optional(),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, '`approve` must be true or false');

    const profile = await prisma.workerProfile.findUnique({
      where: { userId: req.params.userId },
      include: { user: true, zone: true },
    });
    if (!profile) throw new ApiError(404, 'Worker not found');
    if (profile.approvalStatus === 'ACTIVE' && parsed.data.approve) {
      throw new ApiError(409, 'That worker is already verified');
    }

    const updated = await prisma.workerProfile.update({
      where: { userId: req.params.userId },
      data: {
        approvalStatus: parsed.data.approve ? 'ACTIVE' : 'REJECTED',
        approvedAt: parsed.data.approve ? new Date() : null,
        rejectionNote: parsed.data.approve ? null : (parsed.data.note ?? 'Not approved'),
        dutyStatus: 'OFF',
      },
    });

    await notify({
      userId: profile.userId,
      title: parsed.data.approve ? 'You have been verified' : 'Registration not approved',
      body: parsed.data.approve
        ? `You are now an active worker for ${profile.zone.name}. Go on duty to start receiving tasks.`
        : (parsed.data.note ?? 'Your worker registration was not approved. Contact the campus admin.'),
    });

    // The zone officer should know their roster changed.
    const zone = await prisma.zone.findUnique({ where: { id: profile.zoneId } });
    if (parsed.data.approve && zone?.officerId) {
      await notify({
        userId: zone.officerId,
        title: 'New worker added to your zone',
        body: `${profile.user.name} has been verified for ${zone.name}.`,
      });
    }

    res.json({
      approvalStatus: updated.approvalStatus,
      message: parsed.data.approve
        ? `${profile.user.name} is now active in ${profile.zone.name}.`
        : `${profile.user.name} was rejected.`,
    });
  }),
);

// ---------------------------------------------------------------------------
// Officer verification
//
// Officers self-register the same way workers do. What differs is what
// approval grants: a zone has exactly one officer, so approving an application
// is an appointment, and the zone must actually be free at that moment.
// ---------------------------------------------------------------------------

/** GET /api/admin/officers?status=PENDING */
router.get(
  '/officers',
  asyncHandler(async (req, res) => {
    const status = req.query.status ?? 'PENDING';

    const officers = await prisma.officerProfile.findMany({
      where: { approvalStatus: status },
      include: {
        user: { select: { id: true, name: true, email: true, phone: true, createdAt: true } },
        zone: {
          select: { id: true, code: true, name: true, label: true, officerId: true },
        },
      },
      orderBy: { createdAt: 'asc' },
    });

    // Whether the zone applied for is still free decides if the admin can
    // approve at all, so send it rather than making the app work it out.
    res.json({
      officers: officers.map((o) => ({
        userId: o.userId,
        name: o.user.name,
        email: o.user.email,
        phone: o.user.phone,
        registeredAt: o.user.createdAt,
        zone: { code: o.zone.code, name: o.zone.name, label: o.zone.label },
        zoneIsTaken: Boolean(o.zone.officerId) && o.zone.officerId !== o.userId,
        idProofUrl: o.idProofUrl,
        approvalStatus: o.approvalStatus,
      })),
    });
  }),
);

/**
 * POST /api/admin/officers/:userId/verify  { approve: bool, note? }
 *
 * Approving appoints them: Zone.officerId is set here and nowhere else in the
 * signup path, so an unapproved application never holds a zone hostage.
 */
router.post(
  '/officers/:userId/verify',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      approve: z.coerce.boolean(),
      note: z.string().max(500).optional(),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, '`approve` must be true or false');

    const profile = await prisma.officerProfile.findUnique({
      where: { userId: req.params.userId },
      include: { user: true, zone: true },
    });
    if (!profile) throw new ApiError(404, 'Officer application not found');
    if (profile.approvalStatus === 'ACTIVE' && parsed.data.approve) {
      throw new ApiError(409, 'That officer is already verified');
    }

    // Someone else may have been appointed while this application sat in the
    // queue. Approving anyway would silently unseat them.
    if (parsed.data.approve && profile.zone.officerId && profile.zone.officerId !== profile.userId) {
      const incumbent = await prisma.user.findUnique({
        where: { id: profile.zone.officerId },
        select: { name: true },
      });
      throw new ApiError(
        409,
        `${profile.zone.name} is already run by ${incumbent?.name ?? 'another officer'}. ` +
          'Remove them first if you want to appoint someone else.',
      );
    }

    const updated = await prisma.$transaction(async (tx) => {
      const row = await tx.officerProfile.update({
        where: { userId: req.params.userId },
        data: {
          approvalStatus: parsed.data.approve ? 'ACTIVE' : 'REJECTED',
          approvedAt: parsed.data.approve ? new Date() : null,
          rejectionNote: parsed.data.approve ? null : (parsed.data.note ?? 'Not approved'),
        },
      });

      if (parsed.data.approve) {
        await tx.zone.update({
          where: { id: profile.zoneId },
          data: { officerId: profile.userId },
        });
      }
      return row;
    });

    await notify({
      userId: profile.userId,
      title: parsed.data.approve ? 'You have been appointed' : 'Application not approved',
      body: parsed.data.approve
        ? `You are now the officer for ${profile.zone.name} (${profile.zone.label}). ` +
          'Complaints from this zone will come straight to you.'
        : (parsed.data.note ?? 'Your officer application was not approved. Contact the campus admin.'),
    });

    // The zone's workers should know who they now answer to.
    if (parsed.data.approve) {
      const roster = await prisma.workerProfile.findMany({
        where: { zoneId: profile.zoneId, approvalStatus: 'ACTIVE' },
        select: { userId: true },
      });
      for (const w of roster) {
        await notify({
          userId: w.userId,
          title: 'New zone officer',
          body: `${profile.user.name} is now the officer for ${profile.zone.name}.`,
        });
      }
    }

    res.json({
      approvalStatus: updated.approvalStatus,
      message: parsed.data.approve
        ? `${profile.user.name} now runs ${profile.zone.name}.`
        : `${profile.user.name} was rejected.`,
    });
  }),
);

// ---------------------------------------------------------------------------
// Complaint verification
// ---------------------------------------------------------------------------

/** GET /api/admin/complaints/pending - the verification queue. */
router.get(
  '/complaints/pending',
  asyncHandler(async (_req, res) => {
    const complaints = await prisma.complaint.findMany({
      where: { status: 'UNDER_REVIEW' },
      include: complaintInclude,
      orderBy: { submittedAt: 'asc' },
    });
    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/**
 * POST /api/admin/complaints/:id/review  { approve: bool, reason? }
 *
 * On approval the engine immediately auto-routes the complaint to the officer
 * of the zone it was reported in - no human picks the officer.
 */
router.post(
  '/complaints/:id/review',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      approve: z.coerce.boolean(),
      reason: z.string().max(500).optional(),
      /// Set when the admin corrects a boundary case before routing it.
      zoneCode: z.coerce.number().int().min(1).max(8).optional(),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, '`approve` must be true or false');

    const complaint = await prisma.complaint.findUnique({
      where: { id: req.params.id },
      include: { zone: true },
    });
    if (!complaint) throw new ApiError(404, 'Complaint not found');
    if (complaint.status !== 'UNDER_REVIEW') {
      throw new ApiError(409, `This complaint is ${complaint.status}, not awaiting review`);
    }

    if (!parsed.data.approve) {
      await transition({
        complaintId: complaint.id,
        toStatus: 'REJECTED_INVALID',
        actor: req.user,
        note: parsed.data.reason ?? 'Rejected by admin',
        data: { rejectionReason: parsed.data.reason ?? 'Rejected by admin' },
      });
      const rejected = await loadComplaintForResponse(prisma, complaint.id);

      await notify({
        userId: complaint.reporterId,
        complaintId: complaint.id,
        title: 'Complaint not accepted',
        body: `${complaint.ref}: ${parsed.data.reason ?? 'the admin could not accept this complaint.'}`,
      });

      return res.json({
        complaint: serializeComplaint(rejected),
        message: 'Complaint rejected.',
      });
    }

    // The admin may correct the zone before it is routed - this is where a
    // boundary case gets a human decision, rather than silently landing on the
    // wrong officer's screen.
    let targetZone = complaint.zone;
    if (parsed.data.zoneCode && parsed.data.zoneCode !== complaint.zone.code) {
      const corrected = await prisma.zone.findUnique({ where: { code: parsed.data.zoneCode } });
      if (!corrected) throw new ApiError(404, `Zone ${parsed.data.zoneCode} not found`);
      targetZone = corrected;

      await prisma.statusLog.create({
        data: {
          complaintId: complaint.id,
          fromStatus: complaint.status,
          toStatus: complaint.status,
          actorId: req.user.id,
          note: `Zone corrected by admin: ${complaint.zone.name} -> ${corrected.name}`,
        },
      });
    }

    await prisma.complaint.update({
      where: { id: complaint.id },
      data: {
        approvedByAdminId: req.user.id,
        approvedAt: new Date(),
        ...(targetZone.id !== complaint.zoneId
          ? { zoneId: targetZone.id, zoneResolvedBy: 'ADMIN_OVERRIDE', zoneDistanceM: null }
          : {}),
      },
    });

    const routed = await routeToZoneOfficer(
      { ...complaint, zoneId: targetZone.id },
      { actor: req.user },
    );

    await notify({
      userId: complaint.reporterId,
      complaintId: complaint.id,
      title: 'Complaint verified',
      body: `${complaint.ref} has been verified and sent to the ${targetZone.name} officer.`,
    });

    const full = await prisma.complaint.findUnique({
      where: { id: complaint.id },
      include: complaintInclude,
    });

    res.json({
      complaint: serializeComplaint(full),
      message:
        routed.status === 'ESCALATED'
          ? 'Approved, but that zone has no officer - it is now with you.'
          : `Approved and routed to the ${targetZone.name} officer.` +
            (targetZone.id !== complaint.zoneId ? ' Zone corrected.' : ''),
    });
  }),
);

/** GET /api/admin/complaints - everything, filterable. */
router.get(
  '/complaints',
  asyncHandler(async (req, res) => {
    const { status, zoneCode, category } = req.query;

    const zone = zoneCode ? await prisma.zone.findUnique({ where: { code: Number(zoneCode) } }) : null;
    // A comma-separated list ("ALLOTTED_TO_OFFICER,HELP_REQUESTED") lets a caller
    // ask for "not yet allotted to a worker, campus-wide" in one request.
    const statuses = status ? String(status).split(',').filter(Boolean) : null;

    const complaints = await prisma.complaint.findMany({
      where: {
        ...(statuses ? { status: statuses.length > 1 ? { in: statuses } : statuses[0] } : {}),
        ...(zone ? { zoneId: zone.id } : {}),
        ...(category ? { category } : {}),
      },
      include: complaintInclude,
      orderBy: { submittedAt: 'desc' },
      take: 200,
    });

    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/** GET /api/admin/escalations - everything that fell through a crack. */
router.get(
  '/escalations',
  asyncHandler(async (_req, res) => {
    const complaints = await prisma.complaint.findMany({
      where: { status: 'ESCALATED' },
      include: complaintInclude,
      orderBy: { escalatedAt: 'asc' },
    });
    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/**
 * POST /api/admin/complaints/:id/force-allot  { workerUserId }
 * The admin's override: allot any worker on campus, ignoring zone.
 */
router.post(
  '/complaints/:id/force-allot',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      workerUserId: z.string().min(1),
      instructions: z.string().trim().max(500).optional(),
      durationHours: z.number().positive().max(2160).optional(),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'workerUserId is required');

    const complaint = await prisma.complaint.findUnique({
      where: { id: req.params.id },
      include: { zone: true },
    });
    if (!complaint) throw new ApiError(404, 'Complaint not found');

    const updated = await allotWorker({
      complaint: { ...complaint, zoneName: complaint.zone.name },
      workerUserId: parsed.data.workerUserId,
      actor: req.user,
      instructions: parsed.data.instructions,
      durationHours: parsed.data.durationHours,
    });

    res.json({ complaint: serializeComplaint(updated), message: 'Worker allotted by admin.' });
  }),
);

/**
 * GET /api/admin/free-workers - every free worker on campus, by zone.
 *
 * Each zone also reports its own open-complaint count, so an admin picking a
 * worker for cross-zone lending can see at a glance whether that worker's own
 * zone actually has slack to spare, rather than lending blind.
 */
router.get(
  '/free-workers',
  asyncHandler(async (_req, res) => {
    const zones = await prisma.zone.findMany({ orderBy: { code: 'asc' } });

    const result = [];
    for (const z of zones) {
      const [free, openComplaintCount] = await Promise.all([
        findFreeWorkers(z.id),
        prisma.complaint.count({
          where: { zoneId: z.id, status: { notIn: ['CLOSED', 'AUTO_CLOSED', 'REJECTED_INVALID'] } },
        }),
      ]);
      result.push({
        zone: { code: z.code, name: z.name, label: z.label },
        openComplaintCount,
        workers: free.map((w) => ({
          userId: w.userId,
          name: w.user.name,
          tasksCompletedToday: w.tasksCompletedToday,
        })),
      });
    }

    res.json({ zones: result });
  }),
);

/**
 * GET /api/admin/multi-zone-workers - workers currently on loan to a zone
 * other than their own, so the admin can see the campus's cross-zone lending
 * at a glance without digging through individual complaints.
 */
router.get(
  '/multi-zone-workers',
  asyncHandler(async (_req, res) => {
    const complaints = await prisma.complaint.findMany({
      where: { isCrossZone: true, status: { in: ['ALLOTTED_TO_WORKER', 'IN_PROGRESS'] } },
      include: {
        zone: true,
        lendingZone: true,
        assignedWorker: true,
      },
      orderBy: { allottedWorkerAt: 'desc' },
    });

    res.json({
      workers: complaints.map((c) => ({
        complaintId: c.id,
        complaintRef: c.ref,
        category: c.category,
        status: c.status,
        worker: c.assignedWorker ? { id: c.assignedWorker.id, name: c.assignedWorker.name } : null,
        homeZone: c.lendingZone
          ? { code: c.lendingZone.code, name: c.lendingZone.name }
          : null,
        workingZone: { code: c.zone.code, name: c.zone.name },
        allottedAt: c.allottedWorkerAt,
      })),
    });
  }),
);

export { router as adminRouter };
