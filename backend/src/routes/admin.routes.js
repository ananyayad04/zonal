import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { env } from '../config/env.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole } from '../middleware/auth.js';
import { transition, notify, notifyMany, generateRef } from '../services/workflow.js';
import { logAudit } from '../services/audit.js';
import {
  routeToZoneOfficer,
  allotWorker,
  findFreeWorkers,
  findAllFreeWorkersCampusWide,
} from '../services/allocation.js';
import {
  complaintInclude,
  serializeComplaint,
  loadComplaintForResponse,
} from '../utils/serialize.js';

const router = Router();

router.use(authenticate);

/**
 * Worker Supervisor gets the same campus-wide reach over complaints and
 * allotment that Admin has - verification, monitoring, force-allot, free
 * workers. It does NOT get personnel verification (worker/officer/warden),
 * zone drawing, or hostel/warden/supervisor account management - those stay
 * Admin-only below.
 */
const staffOrAdmin = requireRole('ADMIN', 'WORKER_SUPERVISOR');

/** GET /api/admin/dashboard - the two queues the admin must clear, plus totals. */
router.get(
  '/dashboard',
  staffOrAdmin,
  asyncHandler(async (_req, res) => {
    const [
      pendingWorkers,
      pendingOfficers,
      pendingComplaints,
      pendingHostelAllotment,
      escalated,
      byStatus,
      zones,
    ] = await Promise.all([
      prisma.workerProfile.count({ where: { approvalStatus: 'PENDING' } }),
      prisma.officerProfile.count({ where: { approvalStatus: 'PENDING' } }),
      prisma.complaint.count({ where: { status: 'UNDER_REVIEW' } }),
      prisma.complaint.count({ where: { status: 'ALLOTTED_TO_HOSTEL_STAFF' } }),
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
      queues: {
        pendingWorkers,
        pendingOfficers,
        pendingComplaints,
        pendingHostelAllotment,
        escalated,
      },
      statusCounts: Object.fromEntries(byStatus.map((r) => [r.status, r._count._all])),
      zones: zoneStats,
    });
  }),
);

/**
 * GET /api/admin/attention
 *
 * Every complaint waiting on a human right now - verification, allotment
 * (zone or hostel), or escalated - merged into one list and sorted by
 * urgency. The dashboard's separate counts say how many of each kind there
 * are; this says which ONE to look at first: overdue before on-time, and
 * soonest-due before anything with slack left.
 */
router.get(
  '/attention',
  staffOrAdmin,
  asyncHandler(async (_req, res) => {
    const complaints = await prisma.complaint.findMany({
      where: {
        status: {
          in: ['UNDER_REVIEW', 'ALLOTTED_TO_OFFICER', 'HELP_REQUESTED', 'ALLOTTED_TO_HOSTEL_STAFF', 'ESCALATED'],
        },
      },
      include: complaintInclude,
      orderBy: { submittedAt: 'asc' },
    });

    const items = complaints
      .map((c) => ({
        ...serializeComplaint(c),
        actionType:
          c.status === 'UNDER_REVIEW'
            ? 'VERIFY'
            : c.status === 'ESCALATED'
              ? 'ESCALATED'
              : c.isHostelComplaint
                ? 'ALLOT_HOSTEL'
                : 'ALLOT_ZONE',
      }))
      .sort((a, b) => {
        // Overdue first, always - regardless of what else is going on.
        if (a.isOverdue !== b.isOverdue) return a.isOverdue ? -1 : 1;
        // Then soonest-due first; nothing-due items sort last.
        const ad = a.slaDueAt ? new Date(a.slaDueAt).getTime() : Infinity;
        const bd = b.slaDueAt ? new Date(b.slaDueAt).getTime() : Infinity;
        return ad - bd;
      });

    res.json({ items });
  }),
);

// ---------------------------------------------------------------------------
// Worker verification
// ---------------------------------------------------------------------------

/** GET /api/admin/workers?status=PENDING */
router.get(
  '/workers',
  requireRole('ADMIN'),
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
  requireRole('ADMIN'),
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

    await logAudit({
      actor: req.user,
      action: parsed.data.approve ? 'WORKER_VERIFIED' : 'WORKER_REJECTED',
      targetType: 'USER',
      targetId: profile.userId,
      targetLabel: profile.user.name,
      note: parsed.data.approve ? null : (parsed.data.note ?? null),
    });

    res.json({
      approvalStatus: updated.approvalStatus,
      message: parsed.data.approve
        ? `${profile.user.name} is now active in ${profile.zone.name}.`
        : `${profile.user.name} was rejected.`,
    });
  }),
);

// ---------------------------------------------------------------------------
// Officer verification (legacy)
//
// Zone officers are now fixed appointments created directly by the Admin
// (POST /admin/zones/officers) - no new applications land here. Kept only so
// any application already in the pipeline from before that change can still
// be reviewed; the endpoint is otherwise dormant.
// ---------------------------------------------------------------------------

/**
 * GET /api/admin/officers?status=PENDING
 *
 * PENDING/REJECTED still read the legacy OfficerProfile application table -
 * dormant now that officers are admin-created, but kept for anything already
 * in that pipeline from before the change.
 *
 * ACTIVE deliberately does NOT read OfficerProfile: an admin-created officer
 * (POST /admin/zones/officers) never gets a profile row at all, the same way
 * Warden and Worker Supervisor don't - they hold their zone directly via
 * Zone.officerId. "Active" here means exactly that: every OFFICER who
 * currently holds a zone, appointed either way.
 */
router.get(
  '/officers',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const status = req.query.status ?? 'PENDING';

    if (status === 'ACTIVE') {
      const officers = await prisma.user.findMany({
        where: { role: 'OFFICER', zoneOwned: { isNot: null } },
        include: {
          zoneOwned: { select: { code: true, name: true, label: true } },
          officerProfile: { select: { idProofUrl: true } },
        },
        orderBy: { name: 'asc' },
      });

      return res.json({
        officers: officers.map((o) => ({
          userId: o.id,
          name: o.name,
          email: o.email,
          phone: o.phone,
          registeredAt: o.createdAt,
          zone: { code: o.zoneOwned.code, name: o.zoneOwned.name, label: o.zoneOwned.label },
          zoneIsTaken: false,
          idProofUrl: o.officerProfile?.idProofUrl ?? null,
          approvalStatus: 'ACTIVE',
        })),
      });
    }

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
  requireRole('ADMIN'),
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

    await logAudit({
      actor: req.user,
      action: parsed.data.approve ? 'OFFICER_VERIFIED' : 'OFFICER_REJECTED',
      targetType: 'USER',
      targetId: profile.userId,
      targetLabel: profile.user.name,
      note: parsed.data.approve ? `Appointed to ${profile.zone.name}` : (parsed.data.note ?? null),
    });

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

/**
 * POST /api/admin/complaints - Worker Supervisor creates a work order
 * directly, with no citizen complaint behind it: which zone, what type of
 * work, a plain description of the area and what needs doing, and
 * optionally a worker to allot straight away in the same step.
 *
 * Worker-Supervisor-only, not Admin: this is proactive work the supervisor
 * is initiating themselves, distinct from the citizen-complaint queue above.
 */
router.post(
  '/complaints',
  requireRole('WORKER_SUPERVISOR'),
  asyncHandler(async (req, res) => {
    const schema = z.object({
      zoneCode: z.coerce.number().int().min(1).max(8),
      category: z.enum([
        'GARBAGE',
        'OVERFLOWING_BIN',
        'WASHROOM',
        'WATER_LOGGING',
        'DRAINAGE',
        'PEST',
        'OTHER',
      ]),
      /// Plain language: which area (e.g. "from Gate 2 to the canteen") and
      /// what needs doing. One simple field rather than separate structured
      /// location fields - a supervisor describing a stretch of ground does
      /// not need a GPS pin the way a citizen complaint does.
      description: z.string().trim().min(3, 'Describe the work').max(1000),
      workerUserId: z.string().min(1).optional(),
      instructions: z.string().trim().max(500).optional(),
      durationHours: z.number().positive().max(2160).optional(),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(
        400,
        'A zone, a type of work and a description are required',
        parsed.error.flatten().fieldErrors,
      );
    }

    const zone = await prisma.zone.findUnique({ where: { code: parsed.data.zoneCode } });
    if (!zone) throw new ApiError(404, `Zone ${parsed.data.zoneCode} not found`);

    const ref = await generateRef();

    const complaint = await prisma.complaint.create({
      data: {
        ref,
        category: parsed.data.category,
        description: parsed.data.description,
        priority: 'MEDIUM',
        // No GPS pin behind this - it is a zone-level work order, not a
        // citizen's exact location. Falls back to the zone's own centroid
        // once drawn, and to the campus centre before that.
        lat: zone.centroidLat ?? env.campusCenterLat,
        lng: zone.centroidLng ?? env.campusCenterLng,
        zoneId: zone.id,
        zoneResolvedBy: 'SUPERVISOR_ASSIGNED',
        reporterId: req.user.id,
        reporterRole: 'WORKER_SUPERVISOR',
        status: 'SUBMITTED',
      },
    });

    await prisma.statusLog.create({
      data: {
        complaintId: complaint.id,
        toStatus: 'SUBMITTED',
        actorId: req.user.id,
        note: `Work order created by ${req.user.name} for ${zone.name}`,
      },
    });

    const routed = await routeToZoneOfficer(complaint, { actor: req.user });

    // routeToZoneOfficer escalates instead of routing when the zone has no
    // officer - the message must say that plainly rather than claim a
    // hand-off that did not happen.
    let message =
      routed.status === 'ESCALATED'
        ? `${zone.name} has no officer assigned, so this has been escalated.`
        : `Work order created and routed to the ${zone.name} officer.`;

    if (parsed.data.workerUserId) {
      // The work order itself is already saved by this point - if the
      // chosen worker cannot be allotted (busy, no longer verified, ...)
      // that must not read as if the whole request failed. It is real and
      // waiting in the unallotted queue either way.
      try {
        await allotWorker({
          complaint: { ...routed, zoneName: zone.name },
          workerUserId: parsed.data.workerUserId,
          actor: req.user,
          instructions: parsed.data.instructions,
          durationHours: parsed.data.durationHours,
        });
        message = 'Work order created and allotted.';
      } catch (err) {
        message = `Work order created, but could not allot that worker: ${
          err.message ?? 'unknown error'
        }. It is waiting to be allotted.`;
      }
    }

    const full = await loadComplaintForResponse(prisma, complaint.id);
    res.status(201).json({ complaint: serializeComplaint(full), message });
  }),
);

/** GET /api/admin/complaints/pending - the verification queue. */
router.get(
  '/complaints/pending',
  staffOrAdmin,
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
  staffOrAdmin,
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
  staffOrAdmin,
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
  staffOrAdmin,
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
  staffOrAdmin,
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
  staffOrAdmin,
  asyncHandler(async (_req, res) => {
    res.json({ zones: await findAllFreeWorkersCampusWide() });
  }),
);

/**
 * GET /api/admin/multi-zone-workers - workers currently on loan to a zone
 * other than their own, so the admin can see the campus's cross-zone lending
 * at a glance without digging through individual complaints.
 */
router.get(
  '/multi-zone-workers',
  staffOrAdmin,
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

// ---------------------------------------------------------------------------
// Worker Supervisor accounts
//
// Unlike Worker/Officer, there is no self-registration or approval queue:
// the Admin creates the account directly and it is usable immediately.
// ---------------------------------------------------------------------------

/** GET /api/admin/supervisors - existing Worker Supervisor accounts. */
router.get(
  '/supervisors',
  requireRole('ADMIN'),
  asyncHandler(async (_req, res) => {
    const supervisors = await prisma.user.findMany({
      where: { role: 'WORKER_SUPERVISOR' },
      select: { id: true, name: true, email: true, phone: true, isActive: true, createdAt: true },
      orderBy: { name: 'asc' },
    });
    res.json({ supervisors });
  }),
);

/** POST /api/admin/supervisors  { name, email, phone?, password } */
router.post(
  '/supervisors',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const schema = z.object({
      name: z.string().min(2, 'Name is too short'),
      email: z.string().trim().toLowerCase().pipe(z.string().email()),
      phone: z.string().min(10).max(15).optional(),
      password: z.string().min(6, 'Password must be at least 6 characters'),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid details', parsed.error.flatten().fieldErrors);
    }
    const { name, email, phone, password } = parsed.data;

    const existing = await prisma.user.findFirst({
      where: { OR: [{ email: { equals: email, mode: 'insensitive' } }, ...(phone ? [{ phone }] : [])] },
    });
    if (existing) throw new ApiError(409, 'An account with that email or phone already exists');

    const passwordHash = await bcrypt.hash(password, 10);
    const supervisor = await prisma.user.create({
      data: { name, email, phone, passwordHash, role: 'WORKER_SUPERVISOR' },
    });

    await logAudit({
      actor: req.user,
      action: 'SUPERVISOR_CREATED',
      targetType: 'USER',
      targetId: supervisor.id,
      targetLabel: supervisor.name,
    });

    res.status(201).json({
      supervisor: { id: supervisor.id, name: supervisor.name, email: supervisor.email },
      message: `${supervisor.name} can now sign in as a Worker Supervisor.`,
    });
  }),
);

/**
 * GET /api/admin/audit-log
 * Who Admin verified, created, or appointed to run a zone or hostel, most
 * recent first. Admin-only - this is the accountability trail for the
 * personnel decisions the role itself is responsible for, not something
 * Worker Supervisor needs for its own day-to-day complaint work.
 */
router.get(
  '/audit-log',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const take = Math.min(Number(req.query.take ?? 100), 300);
    const entries = await prisma.auditLog.findMany({
      orderBy: { createdAt: 'desc' },
      take,
    });
    res.json({ entries });
  }),
);

export { router as adminRouter };
