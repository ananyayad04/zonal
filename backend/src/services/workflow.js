/**
 * Complaint state machine.
 *
 * Every status change in the system goes through `transition()`. That is what
 * guarantees three things the report leans on: an illegal jump is impossible,
 * every move lands in the audit trail, and the SLA clock for the *next* stage
 * is always set at the moment we enter it.
 */

import crypto from 'node:crypto';
import { prisma } from '../lib/prisma.js';
import { env, hoursFromNow } from '../config/env.js';
import { ApiError } from '../middleware/error.js';

/** Which statuses may legally follow which. */
export const ALLOWED_TRANSITIONS = {
  // Emergencies go straight to the zone officer, and hostel complaints go
  // straight to Admin/Warden/Supervisor - both skip admin verification.
  SUBMITTED: ['UNDER_REVIEW', 'ALLOTTED_TO_OFFICER', 'ALLOTTED_TO_HOSTEL_STAFF'],
  UNDER_REVIEW: ['ALLOTTED_TO_OFFICER', 'REJECTED_INVALID'],
  ALLOTTED_TO_OFFICER: ['ALLOTTED_TO_WORKER', 'HELP_REQUESTED', 'ESCALATED'],
  ALLOTTED_TO_HOSTEL_STAFF: ['ALLOTTED_TO_WORKER', 'ESCALATED'],
  HELP_REQUESTED: ['ALLOTTED_TO_WORKER', 'ALLOTTED_TO_OFFICER', 'ESCALATED'],
  ALLOTTED_TO_WORKER: ['IN_PROGRESS', 'ALLOTTED_TO_OFFICER', 'ESCALATED'],
  IN_PROGRESS: ['WORK_DONE', 'ESCALATED'],
  WORK_DONE: ['CLOSED', 'REOPENED', 'AUTO_CLOSED', 'ESCALATED'],
  REOPENED: ['IN_PROGRESS', 'ALLOTTED_TO_WORKER', 'ESCALATED'],
  ESCALATED: ['ALLOTTED_TO_WORKER', 'ALLOTTED_TO_OFFICER', 'CLOSED', 'REJECTED_INVALID'],
  // Terminal
  CLOSED: [],
  AUTO_CLOSED: [],
  REJECTED_INVALID: [],
};

export const TERMINAL_STATUSES = ['CLOSED', 'AUTO_CLOSED', 'REJECTED_INVALID'];

/** Stage deadline applied on entering each status. `null` = no clock running. */
function slaForStatus(status) {
  switch (status) {
    case 'ALLOTTED_TO_OFFICER':
    // Same "how long staff have to allot a worker" meaning as the officer
    // queue, so it reuses the same env var rather than adding a new one.
    case 'ALLOTTED_TO_HOSTEL_STAFF':
      return hoursFromNow(env.slaOfficerAllotHours);
    case 'HELP_REQUESTED':
      return hoursFromNow(env.helpRequestExpiryHours);
    case 'ALLOTTED_TO_WORKER':
    case 'IN_PROGRESS':
    case 'REOPENED':
      return hoursFromNow(env.slaWorkerCompleteHours);
    case 'WORK_DONE':
      return hoursFromNow(env.autoCloseHours); // resident's window to respond
    default:
      return null;
  }
}

/** Timestamps that should be stamped the first time we enter a status. */
function timestampsForStatus(status, now) {
  switch (status) {
    case 'ALLOTTED_TO_OFFICER':
    // Same meaning as the officer queue - "left the submit/verify stage" -
    // so it reuses the same column rather than adding a new one.
    case 'ALLOTTED_TO_HOSTEL_STAFF':
      return { allottedOfficerAt: now };
    case 'ALLOTTED_TO_WORKER':
      return { allottedWorkerAt: now };
    case 'IN_PROGRESS':
      return { startedAt: now };
    case 'WORK_DONE':
      return { doneAt: now };
    case 'CLOSED':
    case 'AUTO_CLOSED':
    case 'REJECTED_INVALID':
      return { closedAt: now };
    case 'ESCALATED':
      return { escalatedAt: now };
    default:
      return {};
  }
}

/**
 * Move a complaint to a new status.
 *
 * @param {object} opts
 * @param {string} opts.complaintId
 * @param {string} opts.toStatus
 * @param {object} [opts.actor]      user causing the change (omit for system)
 * @param {boolean} [opts.isSystem]  true for engine/cron driven moves
 * @param {string} [opts.note]       shown in the audit trail
 * @param {object} [opts.data]       extra Complaint fields to write
 * @param {object} [opts.tx]         run inside an existing transaction
 * @param {boolean} [opts.force]     skip the legality check (cron cleanups)
 */
export async function transition({
  complaintId,
  toStatus,
  actor = null,
  isSystem = false,
  note = null,
  data = {},
  tx = null,
  force = false,
}) {
  const db = tx ?? prisma;

  const complaint = await db.complaint.findUnique({ where: { id: complaintId } });
  if (!complaint) throw new ApiError(404, 'Complaint not found');

  const fromStatus = complaint.status;

  if (!force && !ALLOWED_TRANSITIONS[fromStatus]?.includes(toStatus)) {
    throw new ApiError(
      409,
      `Cannot move a complaint from ${fromStatus} to ${toStatus}`,
    );
  }

  const now = new Date();

  const updated = await db.complaint.update({
    where: { id: complaintId },
    data: {
      status: toStatus,
      slaDueAt: slaForStatus(toStatus),
      ...timestampsForStatus(toStatus, now),
      ...data,
    },
  });

  await db.statusLog.create({
    data: {
      complaintId,
      fromStatus,
      toStatus,
      actorId: actor?.id ?? null,
      isSystem: isSystem || !actor,
      note,
    },
  });

  return updated;
}

/** Queue an in-app notification. */
export async function notify({ userId, complaintId = null, title, body, tx = null }) {
  if (!userId) return null;
  const db = tx ?? prisma;
  return db.notification.create({ data: { userId, complaintId, title, body } });
}

export async function notifyMany(entries, tx = null) {
  const db = tx ?? prisma;
  const rows = entries.filter((e) => e.userId);
  if (!rows.length) return { count: 0 };
  return db.notification.createMany({
    data: rows.map((e) => ({
      userId: e.userId,
      complaintId: e.complaintId ?? null,
      title: e.title,
      body: e.body,
    })),
  });
}

/** Human-friendly complaint reference, e.g. SC48213. */
export async function generateRef() {
  for (let attempt = 0; attempt < 10; attempt++) {
    const ref = `SC${crypto.randomInt(10000, 99999)}`;
    const clash = await prisma.complaint.findUnique({ where: { ref } });
    if (!clash) return ref;
  }
  return `SC${Date.now().toString().slice(-6)}`;
}
