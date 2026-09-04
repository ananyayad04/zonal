/**
 * Background jobs.
 *
 * These exist so that no complaint can ever sit still forever. Every waiting
 * state in the machine has a clock, and this is what makes the clocks fire:
 *
 *   - a resident who never answers          -> AUTO_CLOSED after 72h
 *   - an officer who never allots           -> ESCALATED to the admin
 *   - a help request nobody answers         -> ESCALATED to the admin
 *   - a worker who never finishes           -> ESCALATED to the admin
 */

import cron from 'node-cron';
import { prisma } from '../lib/prisma.js';
import { env } from '../config/env.js';
import { transition, notifyMany } from '../services/workflow.js';
import { releaseWorker } from '../services/allocation.js';

const adminIds = async () =>
  (await prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } })).map((a) => a.id);

/**
 * Complaints the reporter never signed off.
 *
 * Disabled by default (AUTO_CLOSE_HOURS=0). Nothing closes a complaint except
 * the person who filed it: the work is done when they say it is done, and a
 * timer that decides on their behalf turns an unresolved problem into a
 * resolved-looking statistic. Anything waiting stays in WORK_DONE, and stays
 * visible to the officer, until they answer.
 *
 * The job is kept rather than deleted so a deployment that genuinely needs a
 * backstop can set the variable and get one, deliberately.
 */
export async function autoCloseStaleWorkDone() {
  if (!env.autoCloseHours || env.autoCloseHours <= 0) return 0;

  const cutoff = new Date(Date.now() - env.autoCloseHours * 60 * 60 * 1000);

  const stale = await prisma.complaint.findMany({
    where: { status: 'WORK_DONE', satisfaction: 'PENDING', doneAt: { lt: cutoff } },
    select: { id: true, ref: true, assignedWorkerId: true, reporterId: true },
  });

  for (const c of stale) {
    await releaseWorker(c.assignedWorkerId, { completed: true });

    await transition({
      complaintId: c.id,
      toStatus: 'AUTO_CLOSED',
      isSystem: true,
      note: `Reporter did not respond within ${env.autoCloseHours}h`,
      // Recorded as AUTO, never as SATISFIED, so the approval rate stays honest.
      data: { satisfaction: 'AUTO' },
    });

    await notifyMany([
      {
        userId: c.reporterId,
        complaintId: c.id,
        title: 'Complaint closed automatically',
        body: `${c.ref} was closed as you did not confirm within ${env.autoCloseHours} hours.`,
      },
    ]);
  }

  return stale.length;
}

/** Officers sitting on a complaint past the allotment window. */
export async function escalateStaleOfficerQueue() {
  const overdue = await prisma.complaint.findMany({
    where: { status: 'ALLOTTED_TO_OFFICER', slaDueAt: { lt: new Date() } },
    select: { id: true, ref: true, assignedOfficerId: true, zone: { select: { name: true } } },
  });

  if (!overdue.length) return 0;
  const admins = await adminIds();

  for (const c of overdue) {
    await transition({
      complaintId: c.id,
      toStatus: 'ESCALATED',
      isSystem: true,
      note: 'Zone officer did not allot a worker within the SLA',
      data: { escalationReason: 'OFFICER_SLA_BREACH' },
    });

    await notifyMany([
      ...admins.map((id) => ({
        userId: id,
        complaintId: c.id,
        title: 'Officer SLA breached',
        body: `${c.ref} in ${c.zone.name} was not allotted in time.`,
      })),
      {
        userId: c.assignedOfficerId,
        complaintId: c.id,
        title: 'Complaint escalated',
        body: `${c.ref} passed its allotment deadline and is now with the admin.`,
      },
    ]);
  }

  return overdue.length;
}

/** Hostel complaints nobody allotted a worker to in time. */
export async function escalateStaleHostelQueue() {
  const overdue = await prisma.complaint.findMany({
    where: { status: 'ALLOTTED_TO_HOSTEL_STAFF', slaDueAt: { lt: new Date() } },
    select: { id: true, ref: true, assignedWardenId: true },
  });

  if (!overdue.length) return 0;
  const admins = await adminIds();
  const supervisors = (
    await prisma.user.findMany({ where: { role: 'WORKER_SUPERVISOR' }, select: { id: true } })
  ).map((s) => s.id);

  for (const c of overdue) {
    await transition({
      complaintId: c.id,
      toStatus: 'ESCALATED',
      isSystem: true,
      note: 'No one allotted a worker within the SLA',
      data: { escalationReason: 'HOSTEL_STAFF_SLA_BREACH' },
    });

    await notifyMany([
      ...admins.map((id) => ({
        userId: id,
        complaintId: c.id,
        title: 'Hostel complaint SLA breached',
        body: `${c.ref} was not allotted in time.`,
      })),
      ...supervisors.map((id) => ({
        userId: id,
        complaintId: c.id,
        title: 'Hostel complaint escalated',
        body: `${c.ref} passed its allotment deadline and is now with the admin.`,
      })),
      {
        userId: c.assignedWardenId,
        complaintId: c.id,
        title: 'Complaint escalated',
        body: `${c.ref} passed its allotment deadline and is now with the admin.`,
      },
    ]);
  }

  return overdue.length;
}

/** Help requests no other officer answered. */
export async function expireStaleHelpRequests() {
  const expired = await prisma.helpRequest.findMany({
    where: { status: 'OPEN', expiresAt: { lt: new Date() } },
    include: { complaint: { select: { id: true, ref: true, status: true } }, fromOfficer: true },
  });

  if (!expired.length) return 0;
  const admins = await adminIds();

  for (const h of expired) {
    await prisma.helpRequest.update({
      where: { id: h.id },
      data: { status: 'EXPIRED', respondedAt: new Date() },
    });

    // Only escalate if the complaint is still stuck waiting on this request.
    if (h.complaint.status !== 'HELP_REQUESTED') continue;

    await transition({
      complaintId: h.complaint.id,
      toStatus: 'ESCALATED',
      isSystem: true,
      note: 'No other zone officer answered the help request',
      data: { escalationReason: 'HELP_REQUEST_EXPIRED' },
    });

    await notifyMany([
      ...admins.map((id) => ({
        userId: id,
        complaintId: h.complaint.id,
        title: 'Help request went unanswered',
        body: `${h.complaint.ref} still has no worker. No officer responded.`,
      })),
      {
        userId: h.fromOfficerId,
        complaintId: h.complaint.id,
        title: 'Help request expired',
        body: `Nobody answered your request for ${h.complaint.ref}. The admin has been notified.`,
      },
    ]);
  }

  return expired.length;
}

/** Workers who blew the completion deadline. */
export async function escalateStaleWorkerTasks() {
  const overdue = await prisma.complaint.findMany({
    where: {
      status: { in: ['ALLOTTED_TO_WORKER', 'IN_PROGRESS', 'REOPENED'] },
      slaDueAt: { lt: new Date() },
    },
    select: { id: true, ref: true, assignedWorkerId: true, assignedOfficerId: true },
  });

  if (!overdue.length) return 0;
  const admins = await adminIds();

  for (const c of overdue) {
    await releaseWorker(c.assignedWorkerId, { completed: false });

    await transition({
      complaintId: c.id,
      toStatus: 'ESCALATED',
      isSystem: true,
      note: 'Worker did not complete within the SLA',
      data: { escalationReason: 'WORKER_SLA_BREACH', assignedWorkerId: null },
    });

    await notifyMany([
      ...admins.map((id) => ({
        userId: id,
        complaintId: c.id,
        title: 'Worker SLA breached',
        body: `${c.ref} was not completed in time and has been unassigned.`,
      })),
      {
        userId: c.assignedOfficerId,
        complaintId: c.id,
        title: 'Task overdue',
        body: `${c.ref} passed its deadline and has been escalated.`,
      },
    ]);
  }

  return overdue.length;
}

/** Reset the fairness counter so tomorrow's load spreads evenly again. */
export async function resetDailyCounters() {
  const result = await prisma.workerProfile.updateMany({ data: { tasksCompletedToday: 0 } });
  return result.count;
}

/** Run every time-based rule once. Exported so it can be triggered manually. */
export async function runAllChecks() {
  const [autoClosed, officerEscalations, hostelEscalations, expiredHelp, workerEscalations] =
    await Promise.all([
      autoCloseStaleWorkDone(),
      escalateStaleOfficerQueue(),
      escalateStaleHostelQueue(),
      expireStaleHelpRequests(),
      escalateStaleWorkerTasks(),
    ]);

  const summary = { autoClosed, officerEscalations, hostelEscalations, expiredHelp, workerEscalations };
  const touched = Object.values(summary).reduce((a, b) => a + b, 0);
  if (touched > 0) console.log('[jobs]', summary);
  return summary;
}

export function startScheduler() {
  // Every minute - the demo needs escalations to happen while you watch.
  cron.schedule('* * * * *', () => {
    runAllChecks().catch((err) => console.error('[jobs] failed:', err));
  });

  // Midnight - reset the per-day fairness counters.
  cron.schedule('0 0 * * *', () => {
    resetDailyCounters()
      .then((n) => console.log(`[jobs] daily counters reset for ${n} workers`))
      .catch((err) => console.error('[jobs] reset failed:', err));
  });

  console.log('Scheduler started (SLA checks every minute)');
}
