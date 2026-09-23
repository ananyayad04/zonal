/**
 * Allocation engine.
 *
 * Flow this implements:
 *   Admin approves  ->  engine auto-transfers to that ZONE'S OFFICER
 *   Officer allots a free worker in their own zone
 *   ...or, if every one of their workers is busy, the officer raises a help
 *      request and an officer of a nearby zone lends one of theirs.
 *
 * "Free" is defined in one place - `freeWorkerFilter` - so the officer's
 * screen, the help-request targeting and the allotment guard can never
 * disagree about who is available.
 */

import { prisma } from '../lib/prisma.js';
import { env, hoursFromNow } from '../config/env.js';
import { ApiError } from '../middleware/error.js';
import { loadComplaintForResponse } from '../utils/serialize.js';
import { transition, notify, notifyMany } from './workflow.js';

/**
 * A worker may be allotted work only if all four hold:
 *   verified by the admin, clocked on duty, not already holding a task,
 *   and their account is enabled.
 */
export const freeWorkerFilter = (zoneId) => ({
  zoneId,
  approvalStatus: 'ACTIVE',
  dutyStatus: 'ON',
  availability: 'AVAILABLE',
  activeTaskCount: { lt: env.maxTasksPerWorker },
  user: { isActive: true },
});

/**
 * Free workers in a zone, fairest candidate first.
 * Ordering by `tasksCompletedToday` spreads the day's load across the roster
 * instead of hammering whoever happens to sort first.
 */
export async function findFreeWorkers(zoneId, tx = null) {
  const db = tx ?? prisma;
  return db.workerProfile.findMany({
    where: freeWorkerFilter(zoneId),
    include: { user: { select: { id: true, name: true, phone: true } }, zone: true },
    orderBy: [{ tasksCompletedToday: 'asc' }, { createdAt: 'asc' }],
  });
}

/**
 * Every free worker on campus, grouped by zone. Shared by the Admin's
 * campus-wide screen and the hostel-complaint allotment screen, so there is
 * exactly one place that answers "who is free right now, anywhere".
 */
export async function findAllFreeWorkersCampusWide() {
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
  return result;
}

/**
 * Every worker in a zone with their live state - powers the officer roster.
 * Passing no `zoneId` returns every ACTIVE worker campus-wide, for the
 * Worker Supervisor's roster, which isn't scoped to one zone the way an
 * officer is.
 */
export async function getZoneRoster(zoneId = null, tx = null) {
  const db = tx ?? prisma;
  return db.workerProfile.findMany({
    where: { ...(zoneId ? { zoneId } : {}), approvalStatus: 'ACTIVE' },
    include: {
      user: { select: { id: true, name: true, phone: true, isActive: true } },
      zone: { select: { id: true, code: true, name: true, label: true, colorHex: true } },
    },
    orderBy: [{ availability: 'asc' }, { tasksCompletedToday: 'asc' }],
  });
}

/**
 * Step after Admin approval: hand the complaint to the officer who owns the
 * zone it was reported in. Fully automatic - no human picks the officer.
 */
export async function routeToZoneOfficer(complaint, { actor = null, tx = null } = {}) {
  const db = tx ?? prisma;

  const zone = await db.zone.findUnique({
    where: { id: complaint.zoneId },
    include: { officer: true },
  });

  if (!zone?.officerId) {
    // No officer posted to this zone - park it with the Admin rather than
    // letting the complaint fall down a hole.
    return transition({
      complaintId: complaint.id,
      toStatus: 'ESCALATED',
      isSystem: true,
      note: `No zone officer assigned to ${zone?.name ?? 'this zone'}`,
      data: { escalationReason: 'NO_ZONE_OFFICER' },
      tx: db,
      force: true,
    });
  }

  const updated = await transition({
    complaintId: complaint.id,
    toStatus: 'ALLOTTED_TO_OFFICER',
    actor,
    isSystem: true,
    note: `Auto-routed to ${zone.name} officer`,
    data: { assignedOfficerId: zone.officerId },
    tx: db,
  });

  const freeCount = await db.workerProfile.count({ where: freeWorkerFilter(zone.id) });

  await notify({
    userId: zone.officerId,
    complaintId: complaint.id,
    title: `New complaint in ${zone.name}`,
    body:
      freeCount > 0
        ? `${complaint.ref} needs a worker. ${freeCount} free right now.`
        : `${complaint.ref} needs a worker, but none of your workers are free.`,
    tx: db,
  });

  return updated;
}

/**
 * Emergency route: skip the admin gate and tell everyone at once.
 *
 * A normal complaint waits for an admin to verify it before any officer sees
 * it. An emergency cannot afford that wait, so it goes straight to the zone's
 * own officer AND is announced to every other officer and every on-duty worker
 * on campus. Any officer can then allot any of their workers to it - the usual
 * "this belongs to another zone" guard is lifted for emergencies.
 */
export async function broadcastEmergency(complaint, { actor = null } = {}) {
  const zone = await prisma.zone.findUnique({
    where: { id: complaint.zoneId },
    include: { officer: true },
  });

  const updated = await transition({
    complaintId: complaint.id,
    toStatus: 'ALLOTTED_TO_OFFICER',
    actor,
    isSystem: true,
    note: `EMERGENCY in ${zone?.name ?? 'campus'} - broadcast to all officers and on-duty workers`,
    data: {
      assignedOfficerId: zone?.officerId ?? null,
      priority: 'HIGH',
      approvedAt: new Date(),
    },
  });

  const [officers, onDutyWorkers, admins, residents] = await Promise.all([
    prisma.user.findMany({ where: { role: 'OFFICER', isActive: true }, select: { id: true } }),
    prisma.workerProfile.findMany({
      where: { approvalStatus: 'ACTIVE', dutyStatus: 'ON', user: { isActive: true } },
      select: { userId: true },
    }),
    prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } }),
    // The reporter's own community gets it too, as a safety warning rather
    // than a work order - flooding, sewage or broken glass is something
    // people nearby need to know about so they can avoid it, not just
    // something for staff to clean up.
    //
    // Scoped to the reporter's own community (mirrors the same audience
    // split as ordinary complaints) rather than broadcasting to the other
    // community as well. The person who reported it is excluded; they
    // already know.
    prisma.user.findMany({
      where: {
        role: complaint.reporterRole,
        isActive: true,
        NOT: { id: complaint.reporterId },
      },
      select: { id: true },
    }),
  ]);

  const where = `${zone?.name ?? 'campus'}${zone?.label ? ` (${zone.label})` : ''}`;
  const what = (complaint.category ?? 'issue').toLowerCase().replace(/_/g, ' ');

  await notifyMany([
    ...officers.map((o) => ({
      userId: o.id,
      complaintId: complaint.id,
      title: `EMERGENCY - ${where}`,
      body: `${complaint.ref} needs someone now. Any officer can send a worker.`,
    })),
    ...onDutyWorkers.map((w) => ({
      userId: w.userId,
      complaintId: complaint.id,
      title: `EMERGENCY - ${where}`,
      body: `${complaint.ref} reported. Your officer may send you.`,
    })),
    ...admins.map((a) => ({
      userId: a.id,
      complaintId: complaint.id,
      title: `EMERGENCY filed - ${where}`,
      body: `${complaint.ref} skipped verification and went straight out. Reject it if it is not genuine.`,
    })),
    ...residents.map((r) => ({
      userId: r.id,
      complaintId: complaint.id,
      title: `Emergency in ${where}`,
      body: `A ${what} has been reported. Avoid the area until it is cleared.`,
    })),
  ]);

  return {
    complaint: updated,
    notified: {
      officers: officers.length,
      workers: onDutyWorkers.length,
      admins: admins.length,
      residents: residents.length,
      total: officers.length + onDutyWorkers.length + admins.length + residents.length,
    },
  };
}

/**
 * Hostel route: skip the officer entirely and tell Admin, the hostel's
 * Warden, and every Worker Supervisor at once.
 *
 * A normal complaint waits for an admin (or the zone officer) to verify it
 * before anyone is allotted. A hostel complaint does not go through that
 * gate or through a zone officer at all - the hostel's own staff own it from
 * the moment it is filed, mirroring how an emergency skips the same gate to
 * reach a zone officer faster.
 */
export async function broadcastHostelComplaint(complaint, { actor = null } = {}) {
  const landmark = await prisma.landmark.findUnique({
    where: { id: complaint.landmarkId },
    include: { warden: true },
  });

  if (!landmark?.wardenId) {
    // No warden posted to this hostel - park it with the Admin rather than
    // letting the complaint fall down a hole, same as an unstaffed zone.
    return transition({
      complaintId: complaint.id,
      toStatus: 'ESCALATED',
      isSystem: true,
      note: `No warden assigned to ${landmark?.name ?? 'this hostel'}`,
      data: { escalationReason: 'NO_WARDEN_ASSIGNED' },
      force: true,
    });
  }

  const updated = await transition({
    complaintId: complaint.id,
    toStatus: 'ALLOTTED_TO_HOSTEL_STAFF',
    actor,
    isSystem: true,
    note: `Hostel complaint - forwarded to ${landmark.name}'s warden, Admin and every Worker Supervisor`,
    data: { assignedWardenId: landmark.wardenId },
  });

  const [supervisors, admins] = await Promise.all([
    prisma.user.findMany({ where: { role: 'WORKER_SUPERVISOR', isActive: true }, select: { id: true } }),
    prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } }),
  ]);

  await notifyMany([
    {
      userId: landmark.wardenId,
      complaintId: complaint.id,
      title: `New hostel complaint - ${landmark.name}`,
      body: `${complaint.ref} needs a worker.`,
    },
    ...supervisors.map((s) => ({
      userId: s.id,
      complaintId: complaint.id,
      title: `New hostel complaint - ${landmark.name}`,
      body: `${complaint.ref} is awaiting allotment.`,
    })),
    ...admins.map((a) => ({
      userId: a.id,
      complaintId: complaint.id,
      title: `New hostel complaint - ${landmark.name}`,
      body: `${complaint.ref} skipped the officer queue and went straight to the warden.`,
    })),
  ]);

  return updated;
}

/**
 * Officer allots a specific worker.
 *
 * `lendingZoneId` is set when the worker belongs to a different zone, which
 * happens when another officer answers a help request. The complaint itself
 * stays owned by the ORIGIN zone's officer - accountability stays where the
 * problem is.
 */
export async function allotWorker({
  complaint,
  workerUserId,
  actor,
  isCrossZone = false,
  instructions,
  durationHours,
}) {
  return prisma.$transaction(async (tx) => {
    const profile = await tx.workerProfile.findUnique({
      where: { userId: workerUserId },
      include: { user: true, zone: true },
    });

    if (!profile) throw new ApiError(404, 'Worker not found');
    if (profile.approvalStatus !== 'ACTIVE') {
      throw new ApiError(409, 'That worker has not been verified by the admin yet');
    }
    if (profile.dutyStatus !== 'ON') {
      throw new ApiError(409, `${profile.user.name} is off duty`);
    }
    if (profile.activeTaskCount >= env.maxTasksPerWorker) {
      throw new ApiError(409, `${profile.user.name} is already on another task`);
    }

    // Hand the task off cleanly: if somebody else was already on this
    // complaint, release them first.
    //
    // Without this, re-allotting leaks a worker. A complaint sent back for
    // rework keeps its original worker, so allotting a replacement left the
    // first one BUSY with no task - permanently invisible to the allocation
    // engine, and impossible to spot from any screen.
    if (complaint.assignedWorkerId && complaint.assignedWorkerId !== workerUserId) {
      const previous = await tx.workerProfile.findUnique({
        where: { userId: complaint.assignedWorkerId },
      });
      if (previous) {
        const nextActive = Math.max(0, previous.activeTaskCount - 1);
        await tx.workerProfile.update({
          where: { id: previous.id },
          data: {
            activeTaskCount: nextActive,
            availability: nextActive < env.maxTasksPerWorker ? 'AVAILABLE' : 'BUSY',
          },
        });
        await notify({
          userId: complaint.assignedWorkerId,
          complaintId: complaint.id,
          title: 'Task reassigned',
          body: `${complaint.ref} has been given to someone else. You are free again.`,
          tx,
        });
      }
    }

    const crossZone = isCrossZone || profile.zoneId !== complaint.zoneId;

    await tx.workerProfile.update({
      where: { id: profile.id },
      data: {
        activeTaskCount: { increment: 1 },
        availability:
          profile.activeTaskCount + 1 >= env.maxTasksPerWorker ? 'BUSY' : 'AVAILABLE',
      },
    });

    await transition({
      complaintId: complaint.id,
      toStatus: 'ALLOTTED_TO_WORKER',
      actor,
      note: crossZone
        ? `Allotted to ${profile.user.name} (borrowed from ${profile.zone.name})`
        : `Allotted to ${profile.user.name}`,
      data: {
        assignedWorkerId: workerUserId,
        officerActedAt: new Date(),
        isCrossZone: crossZone,
        lendingZoneId: crossZone ? profile.zoneId : null,
        workInstructions: instructions ?? null,
        // Omitting slaDueAt when no duration was given lets transition()'s
        // own default (the global SLA_WORKER_COMPLETE_HOURS) apply, same as
        // before this option existed.
        ...(durationHours ? { slaDueAt: hoursFromNow(durationHours) } : {}),
      },
      tx,
    });

    // Close any help request that was open on this complaint.
    await tx.helpRequest.updateMany({
      where: { complaintId: complaint.id, status: 'OPEN' },
      data: {
        status: 'ACCEPTED',
        acceptedByOfficerId: actor.id,
        acceptedWorkerId: workerUserId,
        respondedAt: new Date(),
      },
    });

    await notify({
      userId: workerUserId,
      complaintId: complaint.id,
      title: 'New task assigned',
      body: `${complaint.ref} in ${complaint.zoneName ?? 'your area'}. Open the app to start.`,
      tx,
    });

    await notify({
      userId: complaint.reporterId,
      complaintId: complaint.id,
      title: 'Your complaint has been assigned',
      body: `${complaint.ref} is now with ${profile.user.name}.`,
      tx,
    });

    // Relations included, so callers can serialize the zone and lending zone.
    return loadComplaintForResponse(tx, complaint.id);
  });
}

/**
 * Release a worker once their task ends. Called on completion, on
 * reassignment and when a complaint is escalated away from them.
 */
export async function releaseWorker(workerUserId, { completed = false, tx = null } = {}) {
  if (!workerUserId) return null;
  const db = tx ?? prisma;

  const profile = await db.workerProfile.findUnique({ where: { userId: workerUserId } });
  if (!profile) return null;

  const nextActive = Math.max(0, profile.activeTaskCount - 1);

  return db.workerProfile.update({
    where: { id: profile.id },
    data: {
      activeTaskCount: nextActive,
      availability: nextActive < env.maxTasksPerWorker ? 'AVAILABLE' : 'BUSY',
      ...(completed
        ? {
            tasksCompletedToday: { increment: 1 },
            tasksCompletedTotal: { increment: 1 },
          }
        : {}),
    },
  });
}

// ---------------------------------------------------------------------------
// Officer -> Officer help requests
// ---------------------------------------------------------------------------

/**
 * Which nearby zones can actually help right now.
 *
 * Two rules make this useful rather than noise: we walk zones nearest-first
 * (so Zone 2 asks Zone 1 or 3, never Zone 6 across campus), and we only
 * include zones that have at least one free worker at this moment - nobody
 * gets asked for help they cannot give.
 */
export async function findZonesThatCanHelp(originZone, tx = null) {
  const db = tx ?? prisma;

  const orderedCodes = originZone.neighbourCodes?.length
    ? originZone.neighbourCodes
    : (await db.zone.findMany({ where: { NOT: { id: originZone.id } } })).map((z) => z.code);

  const candidates = [];
  for (const code of orderedCodes) {
    const zone = await db.zone.findUnique({
      where: { code },
      include: { officer: { select: { id: true, name: true } } },
    });
    if (!zone || !zone.officerId) continue;

    const freeWorkers = await findFreeWorkers(zone.id, db);
    if (!freeWorkers.length) continue;

    candidates.push({
      zone,
      officer: zone.officer,
      freeWorkerCount: freeWorkers.length,
      freeWorkers: freeWorkers.map((w) => ({
        userId: w.userId,
        name: w.user.name,
        tasksCompletedToday: w.tasksCompletedToday,
      })),
    });
  }
  return candidates;
}

/** Officer raises "all my workers are busy, can anyone lend one?". */
export async function createHelpRequest({ complaint, officer, originZone, note }) {
  const existing = await prisma.helpRequest.findFirst({
    where: { complaintId: complaint.id, status: 'OPEN' },
  });
  if (existing) throw new ApiError(409, 'A help request is already open for this complaint');

  const candidates = await findZonesThatCanHelp(originZone);

  if (!candidates.length) {
    // Nobody on the whole campus is free. Surface it to the Admin instead of
    // leaving the complaint stuck on the officer's screen.
    await transition({
      complaintId: complaint.id,
      toStatus: 'ESCALATED',
      actor: officer,
      note: 'No free worker in any zone',
      data: { escalationReason: 'NO_FREE_WORKER_CAMPUS_WIDE' },
    });

    const admins = await prisma.user.findMany({ where: { role: 'ADMIN' } });
    await notifyMany(
      admins.map((a) => ({
        userId: a.id,
        complaintId: complaint.id,
        title: 'No free workers campus-wide',
        body: `${complaint.ref} could not be allotted - every worker is busy or off duty.`,
      })),
    );

    return { escalated: true, helpRequest: null, candidates: [] };
  }

  const helpRequest = await prisma.helpRequest.create({
    data: {
      complaintId: complaint.id,
      fromOfficerId: officer.id,
      fromZoneId: originZone.id,
      targetZoneCodes: candidates.map((c) => c.zone.code),
      note: note ?? null,
      expiresAt: hoursFromNow(env.helpRequestExpiryHours),
    },
  });

  await transition({
    complaintId: complaint.id,
    toStatus: 'HELP_REQUESTED',
    actor: officer,
    note: `Help requested from zones: ${candidates.map((c) => c.zone.name).join(', ')}`,
  });

  await notifyMany(
    candidates.map((c) => ({
      userId: c.officer.id,
      complaintId: complaint.id,
      title: `${originZone.name} needs a worker`,
      body: `${officer.name} is asking for help with ${complaint.ref}. You have ${c.freeWorkerCount} free worker(s).`,
    })),
  );

  return { escalated: false, helpRequest, candidates };
}

/** A different officer answers, lending one of their own workers. */
export async function acceptHelpRequest({ helpRequestId, workerUserId, actor }) {
  const helpRequest = await prisma.helpRequest.findUnique({
    where: { id: helpRequestId },
    include: { complaint: { include: { zone: true } }, fromOfficer: true, fromZone: true },
  });

  if (!helpRequest) throw new ApiError(404, 'Help request not found');
  if (helpRequest.status !== 'OPEN') {
    throw new ApiError(409, `This request was already ${helpRequest.status.toLowerCase()}`);
  }
  if (new Date() > helpRequest.expiresAt) {
    throw new ApiError(409, 'This help request has expired');
  }

  const lender = await prisma.workerProfile.findUnique({ where: { userId: workerUserId } });
  if (!lender) throw new ApiError(404, 'Worker not found');

  // An officer may only lend a worker from their OWN zone (admins may lend any).
  if (actor.role !== 'ADMIN' && lender.zoneId !== actor.zoneOwned?.id) {
    throw new ApiError(403, 'You can only lend workers from your own zone');
  }

  const complaint = {
    ...helpRequest.complaint,
    zoneName: helpRequest.complaint.zone?.name,
  };

  const updated = await allotWorker({
    complaint,
    workerUserId,
    actor,
    isCrossZone: true,
  });

  await notify({
    userId: helpRequest.fromOfficerId,
    complaintId: complaint.id,
    title: 'Help request accepted',
    body: `${actor.name} lent you a worker for ${complaint.ref}.`,
  });

  return updated;
}
