import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole, requireZoneOfficer } from '../middleware/auth.js';
import {
  findFreeWorkers,
  getZoneRoster,
  findZonesThatCanHelp,
  createHelpRequest,
  acceptHelpRequest,
  allotWorker,
  routeToZoneOfficer,
} from '../services/allocation.js';
import { transition, notify } from '../services/workflow.js';
import {
  complaintInclude,
  serializeComplaint,
  loadComplaintForResponse,
} from '../utils/serialize.js';

const router = Router();

router.use(authenticate, requireRole('OFFICER', 'ADMIN'), requireZoneOfficer);

/** The officer's own zone (admins acting on a zone pass ?zoneCode=N). */
async function resolveZone(req) {
  if (req.user.role === 'ADMIN') {
    const code = Number(req.query.zoneCode ?? req.body?.zoneCode);
    if (!code) throw new ApiError(400, 'Admins must specify a zoneCode');
    const zone = await prisma.zone.findUnique({ where: { code } });
    if (!zone) throw new ApiError(404, `Zone ${code} not found`);
    return zone;
  }
  return req.user.zoneOwned;
}

/**
 * GET /api/officer/dashboard
 * Live counts for the officer's zone plus the queue that needs their action.
 */
router.get(
  '/dashboard',
  asyncHandler(async (req, res) => {
    const zone = await resolveZone(req);

    const [byStatus, roster, freeWorkers, actionQueue, openHelpToMe] = await Promise.all([
      prisma.complaint.groupBy({
        by: ['status'],
        where: { zoneId: zone.id },
        _count: { _all: true },
      }),
      getZoneRoster(zone.id),
      findFreeWorkers(zone.id),
      // This officer's own queue, PLUS every open emergency on campus -
      // an emergency is everyone's problem until someone takes it.
      //
      // UNDER_REVIEW is included so the officer sees a complaint the moment it
      // is filed, rather than only after an admin gets round to it. They can
      // verify it themselves or start lining up a worker.
      prisma.complaint.findMany({
        where: {
          status: { in: ['UNDER_REVIEW', 'ALLOTTED_TO_OFFICER', 'HELP_REQUESTED'] },
          OR: [{ zoneId: zone.id }, { isEmergency: true }],
        },
        include: complaintInclude,
        orderBy: [{ isEmergency: 'desc' }, { submittedAt: 'asc' }],
      }),
      prisma.helpRequest.count({
        where: {
          status: 'OPEN',
          expiresAt: { gt: new Date() },
          targetZoneCodes: { has: zone.code },
        },
      }),
    ]);

    const counts = Object.fromEntries(byStatus.map((r) => [r.status, r._count._all]));

    res.json({
      zone: { id: zone.id, code: zone.code, name: zone.name, label: zone.label, colorHex: zone.colorHex },
      counts,
      totals: {
        needsMyAction: actionQueue.length,
        incomingHelpRequests: openHelpToMe,
        workersTotal: roster.length,
        workersFree: freeWorkers.length,
        workersBusy: roster.length - freeWorkers.length,
      },
      actionQueue: actionQueue.map(serializeComplaint),
      roster: roster.map((w) => ({
        userId: w.userId,
        name: w.user.name,
        phone: w.user.phone,
        dutyStatus: w.dutyStatus,
        availability: w.availability,
        activeTaskCount: w.activeTaskCount,
        tasksCompletedToday: w.tasksCompletedToday,
      })),
    });
  }),
);

/** GET /api/officer/complaints - everything in this officer's zone. */
router.get(
  '/complaints',
  asyncHandler(async (req, res) => {
    const zone = await resolveZone(req);
    const { status } = req.query;

    const complaints = await prisma.complaint.findMany({
      where: { zoneId: zone.id, ...(status ? { status } : {}) },
      include: complaintInclude,
      orderBy: { submittedAt: 'desc' },
    });

    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/**
 * GET /api/officer/complaints/:id/candidates
 *
 * What the officer sees before allotting: their own free workers, and - only
 * when they have none - which nearby zones could lend one.
 */
router.get(
  '/complaints/:id/candidates',
  asyncHandler(async (req, res) => {
    const complaint = await prisma.complaint.findUnique({
      where: { id: req.params.id },
      include: { zone: true },
    });
    if (!complaint) throw new ApiError(404, 'Complaint not found');

    // For an emergency, an officer from another zone is answering with THEIR
    // own workers, not the workers of the zone the complaint came from.
    const rosterZoneId =
      complaint.isEmergency && req.user.zoneOwned ? req.user.zoneOwned.id : complaint.zoneId;
    const ownFree = await findFreeWorkers(rosterZoneId);

    // The engine's pick: least-loaded free worker in the zone.
    const suggested = ownFree[0]
      ? {
          userId: ownFree[0].userId,
          name: ownFree[0].user.name,
          tasksCompletedToday: ownFree[0].tasksCompletedToday,
          reason: 'Free right now and has the fewest tasks today',
        }
      : null;

    const helpOptions = ownFree.length ? [] : await findZonesThatCanHelp(complaint.zone);

    res.json({
      complaintRef: complaint.ref,
      suggested,
      freeWorkers: ownFree.map((w) => ({
        userId: w.userId,
        name: w.user.name,
        phone: w.user.phone,
        tasksCompletedToday: w.tasksCompletedToday,
      })),
      canHelp: helpOptions.map((c) => ({
        zone: { code: c.zone.code, name: c.zone.name, label: c.zone.label },
        officer: c.officer,
        freeWorkerCount: c.freeWorkerCount,
      })),
      mustAskForHelp: ownFree.length === 0,
    });
  }),
);

/**
 * POST /api/officer/complaints/:id/review  { approve, reason? }
 *
 * The zone officer can verify a complaint in their own zone without waiting
 * for an admin. Same gate, two people who can open it - the admin was a single
 * bottleneck, and the officer is closer to the problem anyway.
 */
router.post(
  '/complaints/:id/review',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      approve: z.coerce.boolean(),
      reason: z.string().max(500).optional(),
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

    // An officer may only verify complaints in their own zone.
    const zone = await resolveZone(req);
    if (req.user.role === 'OFFICER' && complaint.zoneId !== zone.id) {
      throw new ApiError(403, 'This complaint is in another zone');
    }

    if (!parsed.data.approve) {
      await transition({
        complaintId: complaint.id,
        toStatus: 'REJECTED_INVALID',
        actor: req.user,
        note: parsed.data.reason ?? 'Rejected by zone officer',
        data: { rejectionReason: parsed.data.reason ?? 'Rejected by zone officer' },
      });

      await notify({
        userId: complaint.reporterId,
        complaintId: complaint.id,
        title: 'Complaint not accepted',
        body: `${complaint.ref}: ${parsed.data.reason ?? 'the zone officer could not accept this.'}`,
      });

      const rejected = await loadComplaintForResponse(prisma, complaint.id);
      return res.json({ complaint: serializeComplaint(rejected), message: 'Complaint rejected.' });
    }

    await prisma.complaint.update({
      where: { id: complaint.id },
      data: { approvedByAdminId: req.user.id, approvedAt: new Date() },
    });

    await routeToZoneOfficer(complaint, { actor: req.user });

    await notify({
      userId: complaint.reporterId,
      complaintId: complaint.id,
      title: 'Complaint verified',
      body: `${complaint.ref} has been verified by the ${complaint.zone.name} officer.`,
    });

    const full = await loadComplaintForResponse(prisma, complaint.id);
    res.json({
      complaint: serializeComplaint(full),
      message: 'Verified. You can now allot a worker.',
    });
  }),
);

/** POST /api/officer/complaints/:id/allot  { workerUserId } */
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

    const complaint = await prisma.complaint.findUnique({
      where: { id: req.params.id },
      include: { zone: true },
    });
    if (!complaint) throw new ApiError(404, 'Complaint not found');

    // Emergencies are open to any officer - whoever has someone free wins.
    if (
      !complaint.isEmergency &&
      req.user.role === 'OFFICER' &&
      complaint.assignedOfficerId !== req.user.id
    ) {
      throw new ApiError(403, 'This complaint belongs to another zone officer');
    }
    if (!['ALLOTTED_TO_OFFICER', 'HELP_REQUESTED', 'ESCALATED', 'REOPENED'].includes(complaint.status)) {
      throw new ApiError(409, `A complaint in ${complaint.status} cannot be allotted`);
    }

    // An officer may only send workers from their OWN roster.
    //
    // Borrowing across zones has a deliberate route - ask for help, and the
    // other officer lends someone. Without this check that whole handshake was
    // bypassable: a zone officer could reach into any other zone and take a
    // worker directly, with no request, no consent and no cross-zone flag on
    // the complaint. Admins are exempt; force-allot is their override.
    if (req.user.role === 'OFFICER') {
      const worker = await prisma.workerProfile.findUnique({
        where: { userId: parsed.data.workerUserId },
        include: { user: { select: { name: true } }, zone: { select: { name: true } } },
      });
      if (!worker) throw new ApiError(404, 'Worker not found');

      if (worker.zoneId !== req.user.zoneOwned?.id) {
        throw new ApiError(
          403,
          `${worker.user.name} works in ${worker.zone.name}, not your zone. ` +
            'Use "Ask for help" so their officer can lend them.',
        );
      }
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
 * POST /api/officer/complaints/:id/ask-help  { note? }
 * Raised when every worker in the officer's own zone is busy.
 */
router.post(
  '/complaints/:id/ask-help',
  asyncHandler(async (req, res) => {
    const complaint = await prisma.complaint.findUnique({
      where: { id: req.params.id },
      include: { zone: true },
    });
    if (!complaint) throw new ApiError(404, 'Complaint not found');

    if (req.user.role === 'OFFICER' && complaint.assignedOfficerId !== req.user.id) {
      throw new ApiError(403, 'This complaint belongs to another zone officer');
    }
    if (complaint.status !== 'ALLOTTED_TO_OFFICER') {
      throw new ApiError(409, 'Help can only be requested while the complaint is awaiting allotment');
    }

    // Guard against asking for help while your own workers are idle.
    const ownFree = await findFreeWorkers(complaint.zoneId);
    if (ownFree.length > 0) {
      throw new ApiError(
        409,
        `You still have ${ownFree.length} free worker(s) in ${complaint.zone.name}`,
      );
    }

    const result = await createHelpRequest({
      complaint,
      officer: req.user,
      originZone: complaint.zone,
      note: req.body?.note,
    });

    if (result.escalated) {
      return res.json({
        escalated: true,
        message: 'No worker is free anywhere on campus. This has been escalated to the admin.',
      });
    }

    res.json({
      escalated: false,
      helpRequest: {
        id: result.helpRequest.id,
        expiresAt: result.helpRequest.expiresAt,
        targetZoneCodes: result.helpRequest.targetZoneCodes,
      },
      askedZones: result.candidates.map((c) => ({
        code: c.zone.code,
        name: c.zone.name,
        officer: c.officer?.name,
        freeWorkerCount: c.freeWorkerCount,
      })),
      message: `Help requested from ${result.candidates.length} nearby zone(s).`,
    });
  }),
);

/**
 * GET /api/officer/help-requests
 * The inbox: open asks from other officers that THIS officer can answer,
 * bundled with their own free workers so they can lend in one tap.
 */
router.get(
  '/help-requests',
  asyncHandler(async (req, res) => {
    const zone = await resolveZone(req);

    const [incoming, mine, myFreeWorkers] = await Promise.all([
      prisma.helpRequest.findMany({
        where: {
          status: 'OPEN',
          expiresAt: { gt: new Date() },
          targetZoneCodes: { has: zone.code },
          NOT: { fromZoneId: zone.id },
        },
        include: {
          complaint: { include: complaintInclude },
          fromOfficer: { select: { id: true, name: true, phone: true } },
          fromZone: { select: { code: true, name: true, label: true } },
        },
        orderBy: { createdAt: 'asc' },
      }),
      prisma.helpRequest.findMany({
        where: { fromZoneId: zone.id },
        include: {
          complaint: { include: complaintInclude },
          acceptedByOfficer: { select: { id: true, name: true } },
        },
        orderBy: { createdAt: 'desc' },
        take: 20,
      }),
      findFreeWorkers(zone.id),
    ]);

    res.json({
      incoming: incoming.map((h) => ({
        id: h.id,
        fromOfficer: h.fromOfficer,
        fromZone: h.fromZone,
        note: h.note,
        createdAt: h.createdAt,
        expiresAt: h.expiresAt,
        complaint: serializeComplaint(h.complaint),
      })),
      sent: mine.map((h) => ({
        id: h.id,
        status: h.status,
        acceptedByOfficer: h.acceptedByOfficer,
        createdAt: h.createdAt,
        respondedAt: h.respondedAt,
        complaint: serializeComplaint(h.complaint),
      })),
      myFreeWorkers: myFreeWorkers.map((w) => ({
        userId: w.userId,
        name: w.user.name,
        tasksCompletedToday: w.tasksCompletedToday,
      })),
    });
  }),
);

/** POST /api/officer/help-requests/:id/accept  { workerUserId } */
router.post(
  '/help-requests/:id/accept',
  asyncHandler(async (req, res) => {
    const schema = z.object({ workerUserId: z.string().min(1) });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'workerUserId is required');

    const updated = await acceptHelpRequest({
      helpRequestId: req.params.id,
      workerUserId: parsed.data.workerUserId,
      actor: req.user,
    });

    res.json({
      complaint: serializeComplaint(updated),
      message: 'Your worker has been lent to that zone.',
    });
  }),
);

export { router as officerRouter };
