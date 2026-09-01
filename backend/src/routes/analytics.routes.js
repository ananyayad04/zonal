import { Router } from 'express';
import { prisma } from '../lib/prisma.js';
import { asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole } from '../middleware/auth.js';
import { allInsights } from '../services/insights.js';

const router = Router();

router.use(authenticate, requireRole('ADMIN', 'OFFICER'));

const CLOSED_STATES = ['CLOSED', 'AUTO_CLOSED'];
const DEAD_STATES = ['CLOSED', 'AUTO_CLOSED', 'REJECTED_INVALID'];

const avg = (nums) => (nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : null);
const minutesBetween = (a, b) => (a && b ? (new Date(b) - new Date(a)) / 60000 : null);

/**
 * GET /api/analytics/overview
 *
 * The numbers the dashboard and the project report are built on. Everything
 * derives from the lifecycle timestamps written by the state machine, so no
 * figure here can drift out of step with the audit trail.
 */
router.get(
  '/overview',
  asyncHandler(async (req, res) => {
    const days = Math.min(Number(req.query.days ?? 30), 365);
    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000);

    const complaints = await prisma.complaint.findMany({
      where: { submittedAt: { gte: since } },
      select: {
        id: true,
        status: true,
        category: true,
        zoneId: true,
        isCrossZone: true,
        satisfaction: true,
        submittedAt: true,
        approvedAt: true,
        allottedWorkerAt: true,
        doneAt: true,
        closedAt: true,
        lat: true,
        lng: true,
      },
    });

    const zones = await prisma.zone.findMany({ orderBy: { code: 'asc' } });
    const zoneById = Object.fromEntries(zones.map((z) => [z.id, z]));

    const workerCounts = await prisma.workerProfile.groupBy({
      by: ['zoneId'],
      where: { approvalStatus: 'ACTIVE' },
      _count: { _all: true },
    });
    const workerCountByZone = Object.fromEntries(
      workerCounts.map((w) => [w.zoneId, w._count._all]),
    );
    const freeWorkerCounts = await prisma.workerProfile.groupBy({
      by: ['zoneId'],
      where: { approvalStatus: 'ACTIVE', dutyStatus: 'ON', availability: 'AVAILABLE' },
      _count: { _all: true },
    });
    const freeWorkerCountByZone = Object.fromEntries(
      freeWorkerCounts.map((w) => [w.zoneId, w._count._all]),
    );

    const total = complaints.length;
    const closed = complaints.filter((c) => CLOSED_STATES.includes(c.status));
    const open = complaints.filter((c) => !DEAD_STATES.includes(c.status));

    // Stage timings, in minutes.
    const resolutionTimes = closed
      .map((c) => minutesBetween(c.submittedAt, c.closedAt))
      .filter((n) => n != null);
    const verifyTimes = complaints
      .map((c) => minutesBetween(c.submittedAt, c.approvedAt))
      .filter((n) => n != null);
    const allotTimes = complaints
      .map((c) => minutesBetween(c.approvedAt, c.allottedWorkerAt))
      .filter((n) => n != null);
    const workTimes = complaints
      .map((c) => minutesBetween(c.allottedWorkerAt, c.doneAt))
      .filter((n) => n != null);

    // Per-zone breakdown, including the cross-zone borrow count - the number
    // that tells you which zone is actually understaffed.
    const byZone = zones.map((z) => {
      const inZone = complaints.filter((c) => c.zoneId === z.id);
      const closedInZone = inZone.filter((c) => CLOSED_STATES.includes(c.status));
      const zoneResolution = closedInZone
        .map((c) => minutesBetween(c.submittedAt, c.closedAt))
        .filter((n) => n != null);

      return {
        code: z.code,
        name: z.name,
        label: z.label,
        colorHex: z.colorHex,
        total: inZone.length,
        open: inZone.filter((c) => !DEAD_STATES.includes(c.status)).length,
        closed: closedInZone.length,
        crossZoneBorrowed: inZone.filter((c) => c.isCrossZone).length,
        avgResolutionMinutes: zoneResolution.length ? Math.round(avg(zoneResolution)) : null,
        resolutionRate: inZone.length
          ? Math.round((closedInZone.length / inZone.length) * 100)
          : null,
        workerCount: workerCountByZone[z.id] ?? 0,
        freeWorkerCount: freeWorkerCountByZone[z.id] ?? 0,
      };
    });

    const byCategory = Object.entries(
      complaints.reduce((acc, c) => {
        acc[c.category] = (acc[c.category] ?? 0) + 1;
        return acc;
      }, {}),
    )
      .map(([category, count]) => ({ category, count }))
      .sort((a, b) => b.count - a.count);

    const byStatus = complaints.reduce((acc, c) => {
      acc[c.status] = (acc[c.status] ?? 0) + 1;
      return acc;
    }, {});

    // Complaints per day, for the trend line.
    const trend = {};
    for (const c of complaints) {
      const day = new Date(c.submittedAt).toISOString().slice(0, 10);
      trend[day] = (trend[day] ?? 0) + 1;
    }

    const satisfied = complaints.filter((c) => c.satisfaction === 'SATISFIED').length;
    const autoClosed = complaints.filter((c) => c.status === 'AUTO_CLOSED').length;

    res.json({
      window: { days, since },
      totals: {
        total,
        open: open.length,
        closed: closed.length,
        escalated: complaints.filter((c) => c.status === 'ESCALATED').length,
        rejectedInvalid: complaints.filter((c) => c.status === 'REJECTED_INVALID').length,
        crossZone: complaints.filter((c) => c.isCrossZone).length,
      },
      rates: {
        resolutionRatePct: total ? Math.round((closed.length / total) * 100) : null,
        // Reported separately so an auto-close can never be passed off as a
        // resident actually approving the work.
        residentApprovedPct: closed.length ? Math.round((satisfied / closed.length) * 100) : null,
        autoClosedPct: closed.length ? Math.round((autoClosed / closed.length) * 100) : null,
        crossZonePct: total
          ? Math.round((complaints.filter((c) => c.isCrossZone).length / total) * 100)
          : null,
      },
      averageMinutes: {
        submitToVerify: verifyTimes.length ? Math.round(avg(verifyTimes)) : null,
        verifyToAllot: allotTimes.length ? Math.round(avg(allotTimes)) : null,
        allotToDone: workTimes.length ? Math.round(avg(workTimes)) : null,
        endToEndResolution: resolutionTimes.length ? Math.round(avg(resolutionTimes)) : null,
      },
      byZone,
      byCategory,
      byStatus,
      trend: Object.entries(trend)
        .map(([date, count]) => ({ date, count }))
        .sort((a, b) => a.date.localeCompare(b.date)),
    });
  }),
);

/**
 * GET /api/analytics/insights
 *
 * The things the system noticed on its own: places that are probably broken
 * rather than dirty, a zone that needs another pair of hands, and spots that
 * were signed off and went bad again.
 */
router.get(
  '/insights',
  asyncHandler(async (req, res) => {
    const days = Math.min(Number(req.query.days ?? 30), 365);
    res.json(await allInsights({ days }));
  }),
);

/**
 * GET /api/analytics/heatmap
 * Raw points for the campus heatmap - where the dirt actually is.
 */
router.get(
  '/heatmap',
  asyncHandler(async (req, res) => {
    const days = Math.min(Number(req.query.days ?? 90), 365);
    const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000);

    const points = await prisma.complaint.findMany({
      where: { submittedAt: { gte: since }, status: { not: 'REJECTED_INVALID' } },
      select: {
        lat: true,
        lng: true,
        category: true,
        status: true,
        submittedAt: true,
        zone: { select: { code: true, name: true, colorHex: true } },
      },
    });

    res.json({ points, count: points.length });
  }),
);

export { router as analyticsRouter };
