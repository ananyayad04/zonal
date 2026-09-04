/**
 * Insights.
 *
 * Everything else in this system answers a question somebody asked. These
 * three volunteer something nobody asked for:
 *
 *   hotspots   - this place keeps generating complaints, and they are nearly
 *                all the same kind, so it is probably broken rather than dirty
 *   staffing   - this zone keeps borrowing workers while that one sits idle
 *   recurrence - this exact spot was signed off days ago and is dirty again
 *
 * All three run off data already being collected. No new capture, no extra
 * work for anyone using the app.
 */

import { prisma } from '../lib/prisma.js';
import { env } from '../config/env.js';

const DEAD = ['REJECTED_INVALID'];
const CLOSED = ['CLOSED', 'AUTO_CLOSED'];

const daysAgo = (n) => new Date(Date.now() - n * 24 * 60 * 60 * 1000);

/**
 * Was this place cleaned recently and is already dirty again?
 *
 * Called when a complaint is filed. Matches on landmark AND category: a bin
 * overflowing again is a recurrence, a broken tap at the same building is a
 * different problem that happens to share an address.
 */
export async function findRecurrence({ landmarkId, category, reporterId }, tx = null) {
  if (!landmarkId) return null;
  const db = tx ?? prisma;

  const previous = await db.complaint.findFirst({
    where: {
      landmarkId,
      category,
      status: { in: CLOSED },
      closedAt: { gte: daysAgo(env.recurrenceWindowDays) },
      // Someone re-reporting their own complaint minutes after it closed is
      // usually a disagreement about the work, not a recurrence.
      NOT: { reporterId },
    },
    orderBy: { closedAt: 'desc' },
    select: { id: true, ref: true, closedAt: true },
  });

  if (!previous) return null;

  const days = Math.max(
    0,
    Math.round((Date.now() - new Date(previous.closedAt).getTime()) / 86_400_000),
  );

  return { id: previous.id, ref: previous.ref, days };
}

/**
 * Places that keep generating the same kind of complaint.
 *
 * The count alone is not the insight - a busy library will always top a raw
 * league table. What makes it actionable is CONCENTRATION: when most
 * complaints at one place are the same category, the place itself is the
 * problem.
 */
export async function hotspots({ days = env.insightWindowDays, minCount } = {}) {
  const threshold = minCount ?? env.insightHotspotMinComplaints;

  const complaints = await prisma.complaint.findMany({
    where: {
      submittedAt: { gte: daysAgo(days) },
      status: { notIn: DEAD },
      landmarkId: { not: null },
    },
    select: {
      landmarkId: true,
      landmarkName: true,
      landmarkNote: true,
      category: true,
      submittedAt: true,
      closedAt: true,
      submittedAt: true,
      zone: { select: { code: true, name: true } },
    },
  });

  const byPlace = new Map();
  for (const c of complaints) {
    const entry = byPlace.get(c.landmarkId) ?? {
      landmarkId: c.landmarkId,
      landmark: c.landmarkName,
      zone: c.zone,
      total: 0,
      categories: new Map(),
      notes: new Map(),
      lastAt: null,
    };

    entry.total++;
    entry.categories.set(c.category, (entry.categories.get(c.category) ?? 0) + 1);
    if (c.landmarkNote) {
      const note = c.landmarkNote.trim().toLowerCase();
      entry.notes.set(note, (entry.notes.get(note) ?? 0) + 1);
    }
    if (!entry.lastAt || c.submittedAt > entry.lastAt) entry.lastAt = c.submittedAt;

    byPlace.set(c.landmarkId, entry);
  }

  const results = [];
  for (const e of byPlace.values()) {
    if (e.total < threshold) continue;

    const [topCategory, topCount] = [...e.categories.entries()].sort((a, b) => b[1] - a[1])[0];
    const concentration = Math.round((topCount / e.total) * 100);

    // The most-repeated free-text note, when several people described the same
    // spot. That is usually the precise location of the real fault.
    const repeatedNote = [...e.notes.entries()]
      .filter(([, n]) => n >= 2)
      .sort((a, b) => b[1] - a[1])[0];

    results.push({
      landmarkId: e.landmarkId,
      landmark: e.landmark,
      zone: e.zone,
      total: e.total,
      topCategory,
      topCategoryCount: topCount,
      concentrationPct: concentration,
      repeatedNote: repeatedNote ? repeatedNote[0] : null,
      repeatedNoteCount: repeatedNote ? repeatedNote[1] : 0,
      lastAt: e.lastAt,
      // Concentrated repeats point at a fault; scattered ones are just traffic.
      likelyStructural: concentration >= 60 && topCount >= threshold,
      verdict:
        concentration >= 60 && topCount >= threshold
          ? `${topCount} of ${e.total} are the same problem. This looks like something broken, not something dirty.`
          : `${e.total} complaints across ${e.categories.size} different problems. High traffic rather than a fault.`,
    });
  }

  return results.sort((a, b) => b.total - a.total);
}

/**
 * Which zone is short-staffed, and which one has the slack to cover it.
 *
 * Two numbers per zone: how much work landed there per worker, and how often
 * it had to borrow. A zone that is both busy AND borrowing is genuinely short.
 * A zone that is quiet AND lending has capacity to give.
 */
export async function staffing({ days = env.insightWindowDays } = {}) {
  const since = daysAgo(days);

  const [zones, complaints, workers] = await Promise.all([
    prisma.zone.findMany({ orderBy: { code: 'asc' } }),
    prisma.complaint.findMany({
      where: { submittedAt: { gte: since }, status: { notIn: DEAD } },
      select: { zoneId: true, isCrossZone: true, lendingZoneId: true },
    }),
    prisma.workerProfile.findMany({
      where: { approvalStatus: 'ACTIVE' },
      select: { zoneId: true, tasksCompletedTotal: true },
    }),
  ]);

  const rows = zones.map((z) => {
    const mine = complaints.filter((c) => c.zoneId === z.id);
    const staff = workers.filter((w) => w.zoneId === z.id);

    const borrowed = mine.filter((c) => c.isCrossZone).length;
    const lent = complaints.filter((c) => c.lendingZoneId === z.id).length;

    return {
      code: z.code,
      name: z.name,
      label: z.label,
      complaints: mine.length,
      workers: staff.length,
      loadPerWorker: staff.length ? +(mine.length / staff.length).toFixed(1) : null,
      borrowed,
      lent,
    };
  });

  const staffed = rows.filter((r) => r.workers > 0 && r.loadPerWorker != null);

  // Not enough signal to say anything responsible.
  if (staffed.length < 2 || complaints.length < env.insightMinComplaintsForStaffing) {
    return {
      rows,
      recommendation: null,
      note:
        `Not enough activity yet to judge staffing — ${complaints.length} complaints in ` +
        `${days} days. The suggestion appears once there is a pattern to read.`,
    };
  }

  const busiest = [...staffed].sort(
    (a, b) => b.loadPerWorker - a.loadPerWorker || b.borrowed - a.borrowed,
  )[0];
  const quietest = [...staffed].sort(
    (a, b) => a.loadPerWorker - b.loadPerWorker || b.lent - a.lent,
  )[0];

  if (busiest.code === quietest.code) {
    return { rows, recommendation: null, note: 'Workload is even across the staffed zones.' };
  }

  // Moving a worker must not simply invert the problem.
  const wouldBecome = quietest.workers > 1 ? quietest.complaints / (quietest.workers - 1) : Infinity;
  const busiestAfter = busiest.complaints / (busiest.workers + 1);
  const worthwhile =
    quietest.workers > 1 &&
    busiest.loadPerWorker > quietest.loadPerWorker * 2 &&
    wouldBecome < busiest.loadPerWorker;

  return {
    rows,
    recommendation: worthwhile
      ? {
          fromZone: quietest.code,
          fromName: quietest.name,
          toZone: busiest.code,
          toName: busiest.name,
          reason:
            `${busiest.name} handled ${busiest.complaints} complaints with ${busiest.workers} ` +
            `worker(s) — ${busiest.loadPerWorker} each` +
            (busiest.borrowed ? `, and borrowed help ${busiest.borrowed} time(s)` : '') +
            `. ${quietest.name} handled ${quietest.complaints} with ${quietest.workers} ` +
            `— ${quietest.loadPerWorker} each` +
            (quietest.lent ? `, and lent workers out ${quietest.lent} time(s)` : '') +
            '.',
          effect:
            `After the move ${busiest.name} would carry about ${busiestAfter.toFixed(1)} ` +
            `complaints per worker instead of ${busiest.loadPerWorker}` +
            (wouldBecome > 0
              ? `, and ${quietest.name} about ${wouldBecome.toFixed(1)} instead of ${quietest.loadPerWorker}.`
              : `. ${quietest.name} had no complaints of its own in this period, so it can spare one.`),
        }
      : null,
    note: worthwhile
      ? null
      : quietest.workers <= 1
        ? `${quietest.name} is the quietest zone but only has one worker — moving them would leave it unstaffed.`
        : 'No move would improve things enough to be worth the disruption.',
  };
}

/** Complaints filed at a place that had just been signed off. */
export async function recurrences({ days = env.insightWindowDays } = {}) {
  const rows = await prisma.complaint.findMany({
    where: {
      submittedAt: { gte: daysAgo(days) },
      recurrenceOfId: { not: null },
      status: { notIn: DEAD },
    },
    select: {
      id: true,
      ref: true,
      category: true,
      landmarkName: true,
      landmarkNote: true,
      recurrenceDays: true,
      submittedAt: true,
      status: true,
      zone: { select: { code: true, name: true } },
    },
    orderBy: { submittedAt: 'desc' },
    take: 50,
  });

  return rows;
}

/**
 * Which hostels have nobody running them, and each hostel's own complaint
 * load. Mirrors the zone/officer gap (a complaint with no zone officer
 * escalates the same way NO_ZONE_OFFICER does) but surfaces it proactively
 * here rather than waiting for a complaint to hit the gap.
 */
export async function hostelInsights({ days = env.insightWindowDays } = {}) {
  const since = daysAgo(days);

  const [hostels, complaints] = await Promise.all([
    prisma.landmark.findMany({
      where: { category: { in: ['BOYS_HOSTEL', 'GIRLS_HOSTEL'] } },
      include: { warden: { select: { id: true, name: true } } },
      orderBy: [{ category: 'asc' }, { sortOrder: 'asc' }, { name: 'asc' }],
    }),
    prisma.complaint.findMany({
      where: { isHostelComplaint: true, submittedAt: { gte: since } },
      select: { landmarkId: true, status: true, submittedAt: true, closedAt: true },
    }),
  ]);

  const rows = hostels.map((h) => {
    const mine = complaints.filter((c) => c.landmarkId === h.id);
    const closed = mine.filter((c) => CLOSED.includes(c.status));
    const resolution = closed
      .map((c) =>
        c.closedAt ? (new Date(c.closedAt) - new Date(c.submittedAt)) / 60000 : null,
      )
      .filter((n) => n != null);

    return {
      id: h.id,
      name: h.name,
      category: h.category,
      warden: h.warden,
      total: mine.length,
      open: mine.filter((c) => !CLOSED.includes(c.status) && !DEAD.includes(c.status)).length,
      closed: closed.length,
      avgResolutionMinutes: resolution.length
        ? Math.round(resolution.reduce((a, b) => a + b, 0) / resolution.length)
        : null,
    };
  });

  const unassignedHostels = rows.filter((r) => !r.warden);

  return {
    rows,
    unassignedHostels,
    note: unassignedHostels.length
      ? `${unassignedHostels.length} hostel(s) have no warden assigned - ` +
        `complaint(s) from ${unassignedHostels.length === 1 ? 'it' : 'them'} escalate ` +
        'straight to the admin.'
      : null,
  };
}

export async function allInsights(opts = {}) {
  const [hot, staff, recur, hostel] = await Promise.all([
    hotspots(opts),
    staffing(opts),
    recurrences(opts),
    hostelInsights(opts),
  ]);

  return {
    windowDays: opts.days ?? env.insightWindowDays,
    hotspots: hot,
    staffing: staff,
    recurrences: recur,
    hostels: hostel,
    headline: hot.find((h) => h.likelyStructural) ?? null,
  };
}
