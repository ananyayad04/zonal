import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole } from '../middleware/auth.js';
import {
  polygonAreaM2,
  polygonCentroid,
  polygonSelfIntersects,
  polygonsOverlap,
  haversineMeters,
  coverageReport,
  voronoiCells,
} from '../utils/geo.js';
import { notify } from '../services/workflow.js';
import { logAudit } from '../services/audit.js';

const router = Router();

router.use(authenticate, requireRole('ADMIN'));

/** A ring of [lat, lng] pairs. */
const polygonSchema = z
  .array(z.tuple([z.number().min(-90).max(90), z.number().min(-180).max(180)]))
  .min(3, 'A zone boundary needs at least 3 points');

/**
 * Recompute every zone's neighbour ordering.
 *
 * MUST run after any boundary change. `neighbourCodes` decides which zones an
 * officer asks for help, nearest first - move a boundary without recomputing
 * and Zone 2 starts asking Zone 6 across campus while Zone 1 sits idle. This
 * is the one thing that breaks silently.
 */
async function recomputeNeighbours(tx = prisma) {
  const zones = await tx.zone.findMany({ orderBy: { code: 'asc' } });

  for (const self of zones) {
    const placed = self.centroidLat != null && self.centroidLng != null;

    const ordered = zones
      .filter((z) => z.code !== self.code)
      .map((z) => ({
        code: z.code,
        // Zones nobody has drawn yet have no position; they sort last so the
        // ordering stays usable while a campus is only half set up.
        d:
          placed && z.centroidLat != null && z.centroidLng != null
            ? haversineMeters(self.centroidLat, self.centroidLng, z.centroidLat, z.centroidLng)
            : Infinity,
      }))
      .sort((a, b) => a.d - b.d)
      .map((z) => z.code);

    await tx.zone.update({ where: { id: self.id }, data: { neighbourCodes: ordered } });
  }

  return zones.length;
}

/** Shared validation so the preview and the save agree. */
function validatePolygon(polygon, otherZones) {
  const errors = [];
  const warnings = [];

  if (!Array.isArray(polygon) || polygon.length < 3) {
    errors.push('A zone boundary needs at least 3 points.');
    return { errors, warnings, areaM2: 0, overlapsWith: [] };
  }

  if (polygonSelfIntersects(polygon)) {
    errors.push(
      'The boundary crosses itself. Untangle it - a figure-of-eight shape ' +
        'makes "inside the zone" ambiguous.',
    );
  }

  const areaM2 = polygonAreaM2(polygon);
  if (areaM2 < 100) {
    errors.push('That area is too small to be a real zone.');
  }

  const overlapsWith = otherZones
    .filter((z) => Array.isArray(z.polygon) && z.polygon.length >= 3)
    .filter((z) => polygonsOverlap(polygon, z.polygon))
    .map((z) => ({ code: z.code, name: z.name }));

  if (overlapsWith.length) {
    // A warning, not an error: the resolution ladder handles overlaps
    // deterministically (smallest wins), so this is recoverable.
    warnings.push(
      `This overlaps ${overlapsWith.map((z) => z.name).join(', ')}. ` +
        'Complaints in the shared area go to the smaller zone.',
    );
  }

  return { errors, warnings, areaM2, overlapsWith };
}

/** GET /api/admin/zones - the zone list with everything the admin needs. */
router.get(
  '/',
  asyncHandler(async (_req, res) => {
    const zones = await prisma.zone.findMany({
      orderBy: { code: 'asc' },
      include: {
        officer: { select: { id: true, name: true, email: true, phone: true } },
        _count: { select: { workers: true, complaints: true } },
      },
    });

    res.json({
      zones: zones.map((z) => {
        const hasBoundary = Array.isArray(z.polygon) && z.polygon.length >= 3;
        return {
          id: z.id,
          code: z.code,
          name: z.name,
          label: z.label,
          colorHex: z.colorHex,
          polygon: z.polygon,
          hasBoundary,
          pointCount: hasBoundary ? z.polygon.length : 0,
          areaM2: hasBoundary ? Math.round(polygonAreaM2(z.polygon)) : 0,
          centroid: { lat: z.centroidLat, lng: z.centroidLng },
          neighbourCodes: z.neighbourCodes,
          // The admin's marks, so the setup screen reopens where they left it.
          anchor: z.anchorLat != null
              ? { lat: z.anchorLat, lng: z.anchorLng, radiusM: z.anchorRadiusM }
              : null,
          officer: z.officer,
          workerCount: z._count.workers,
          complaintCount: z._count.complaints,
        };
      }),
    });
  }),
);

/**
 * POST /api/admin/zones/validate  { code, polygon }
 * Check a boundary before committing it, so the editor can warn while drawing.
 */
router.post(
  '/validate',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      code: z.coerce.number().int().min(1).max(8),
      polygon: polygonSchema,
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid boundary', parsed.error.flatten().fieldErrors);
    }

    const others = await prisma.zone.findMany({ where: { NOT: { code: parsed.data.code } } });
    const result = validatePolygon(parsed.data.polygon, others);

    res.json({
      valid: result.errors.length === 0,
      errors: result.errors,
      warnings: result.warnings,
      areaM2: Math.round(result.areaM2),
      overlapsWith: result.overlapsWith,
    });
  }),
);

/**
 * PUT /api/admin/zones/:code
 * Update a zone's identity, boundary and officer.
 *
 * Note what does NOT happen: existing complaints keep the zone they were filed
 * in. Re-drawing a boundary must not rewrite history, or last month's
 * analytics change every time somebody nudges a line.
 */
router.put(
  '/:code',
  asyncHandler(async (req, res) => {
    const code = Number(req.params.code);
    if (!Number.isInteger(code) || code < 1 || code > 8) {
      throw new ApiError(400, 'Zone code must be 1-8');
    }

    const schema = z.object({
      name: z.string().min(2).max(40).optional(),
      label: z.string().min(2).max(80).optional(),
      colorHex: z
        .string()
        .regex(/^#[0-9A-Fa-f]{6}$/, 'Colour must look like #1A2B3C')
        .optional(),
      polygon: polygonSchema.optional(),
      officerId: z.string().nullable().optional(),
    });

    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid zone details', parsed.error.flatten().fieldErrors);
    }

    const zone = await prisma.zone.findUnique({ where: { code } });
    if (!zone) throw new ApiError(404, `Zone ${code} not found`);

    const data = {};
    let warnings = [];

    if (parsed.data.name) data.name = parsed.data.name;
    if (parsed.data.label) data.label = parsed.data.label;
    if (parsed.data.colorHex) data.colorHex = parsed.data.colorHex;

    // --- boundary --------------------------------------------------------
    if (parsed.data.polygon) {
      const others = await prisma.zone.findMany({ where: { NOT: { code } } });
      const result = validatePolygon(parsed.data.polygon, others);

      if (result.errors.length) {
        throw new ApiError(400, result.errors[0], { errors: result.errors });
      }
      warnings = result.warnings;

      const centroid = polygonCentroid(parsed.data.polygon);
      data.polygon = parsed.data.polygon;
      data.centroidLat = centroid[0];
      data.centroidLng = centroid[1];
    }

    // --- officer ---------------------------------------------------------
    if (parsed.data.officerId !== undefined) {
      const previousOfficerId = zone.officerId;

      if (parsed.data.officerId) {
        const officer = await prisma.user.findUnique({
          where: { id: parsed.data.officerId },
          include: { zoneOwned: true },
        });
        if (!officer || officer.role !== 'OFFICER') {
          throw new ApiError(400, 'That user is not a zone officer');
        }
        if (officer.zoneOwned && officer.zoneOwned.code !== code) {
          throw new ApiError(
            409,
            `${officer.name} already runs ${officer.zoneOwned.name}. ` +
              'Free them from that zone first.',
          );
        }
      }

      // Refuse to orphan work: an officer holding live complaints cannot just
      // be swapped out from under them.
      if (previousOfficerId && previousOfficerId !== parsed.data.officerId) {
        const openCount = await prisma.complaint.count({
          where: {
            assignedOfficerId: previousOfficerId,
            status: { in: ['ALLOTTED_TO_OFFICER', 'HELP_REQUESTED'] },
          },
        });
        if (openCount > 0) {
          throw new ApiError(
            409,
            `The current officer still has ${openCount} complaint(s) waiting to be ` +
              'allotted. Clear those before reassigning the zone.',
          );
        }
      }

      data.officerId = parsed.data.officerId ?? null;
    }

    const updated = await prisma.zone.update({ where: { code }, data });

    // Any boundary move changes who is nearest to whom.
    if (parsed.data.polygon) await recomputeNeighbours();

    if (data.officerId) {
      await notify({
        userId: data.officerId,
        title: `You now run ${updated.name}`,
        body: `${updated.name} — ${updated.label}. Complaints filed there come to you.`,
      });
    }

    if (parsed.data.officerId !== undefined) {
      const newOfficer = data.officerId
        ? await prisma.user.findUnique({ where: { id: data.officerId }, select: { name: true } })
        : null;
      await logAudit({
        actor: req.user,
        action: 'OFFICER_REASSIGNED',
        targetType: 'ZONE',
        targetId: updated.id,
        targetLabel: updated.name,
        note: newOfficer ? `Now run by ${newOfficer.name}` : 'Officer cleared',
      });
    }

    const fresh = await prisma.zone.findUnique({
      where: { code },
      include: { officer: { select: { id: true, name: true, email: true } } },
    });

    res.json({
      zone: {
        id: fresh.id,
        code: fresh.code,
        name: fresh.name,
        label: fresh.label,
        colorHex: fresh.colorHex,
        polygon: fresh.polygon,
        centroid: { lat: fresh.centroidLat, lng: fresh.centroidLng },
        neighbourCodes: fresh.neighbourCodes,
        officer: fresh.officer,
        areaM2: Math.round(polygonAreaM2(fresh.polygon ?? [])),
      },
      warnings,
      message: parsed.data.polygon
        ? `${fresh.name} boundary saved. Neighbour ordering recomputed.`
        : `${fresh.name} updated.`,
    });
  }),
);

/**
 * POST /api/admin/zones/anchors
 *
 * The practical way to set up a campus. The admin marks one point inside each
 * zone - by tapping the map, or by standing there and using their own GPS -
 * and the boundaries are computed from those points: every location belongs to
 * whichever anchor is nearest.
 *
 * This is what makes the "which zone is this?" problem go away. A partition
 * built this way has no gaps and no overlaps by construction, which free-hand
 * drawing on a phone cannot promise.
 *
 * Body: { anchors: [{ code, lat, lng }, ...], marginM? }
 */
router.post(
  '/anchors',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      anchors: z
        .array(
          z.object({
            code: z.coerce.number().int().min(1).max(8),
            lat: z.number().min(-90).max(90),
            lng: z.number().min(-180).max(180),
            /// How far this zone reaches from its centre. Optional - omit it
            /// on every zone and you get a plain nearest-centre split.
            radiusM: z.coerce.number().min(10).max(5000).optional(),
          }),
        )
        .min(2, 'Mark at least two zones before computing boundaries'),
      /// How far past the outermost anchors the campus extends.
      marginM: z.coerce.number().min(50).max(5000).optional(),
    });

    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid anchors', parsed.error.flatten().fieldErrors);
    }

    const { anchors, marginM } = parsed.data;

    const codes = anchors.map((a) => a.code);
    if (new Set(codes).size !== codes.length) {
      throw new ApiError(400, 'Each zone can only have one anchor');
    }

    const cells = voronoiCells(anchors, { marginM: marginM ?? 400 });

    // A zone can be squeezed to nothing if its radius is tiny next to its
    // neighbours. Refuse the whole save rather than leaving a zone with no
    // territory that silently never receives a complaint.
    const squeezed = cells.filter((c) => c.empty || !c.containsAnchor);
    if (squeezed.length) {
      const names = await prisma.zone.findMany({
        where: { code: { in: squeezed.map((c) => c.code) } },
        select: { code: true, name: true },
      });
      throw new ApiError(
        400,
        `${names.map((n) => n.name).join(', ')} would be squeezed out by ` +
          'neighbouring zones. Increase its size, or reduce the ones around it.',
        { squeezedCodes: squeezed.map((c) => c.code) },
      );
    }

    const updated = [];
    for (const cell of cells) {
      const anchor = anchors.find((a) => a.code === cell.code);
      const centroid = polygonCentroid(cell.polygon);
      const zone = await prisma.zone.update({
        where: { code: cell.code },
        data: {
          polygon: cell.polygon,
          centroidLat: centroid[0],
          centroidLng: centroid[1],
          anchorLat: anchor.lat,
          anchorLng: anchor.lng,
          anchorRadiusM: anchor.radiusM ?? null,
        },
      });
      updated.push({
        code: zone.code,
        name: zone.name,
        areaM2: Math.round(polygonAreaM2(cell.polygon)),
        pointCount: cell.polygon.length,
      });
    }

    // Boundaries moved, so who is nearest to whom has changed.
    await recomputeNeighbours();

    const fresh = await prisma.zone.findMany({ orderBy: { code: 'asc' } });
    const coverage = coverageReport(fresh, { steps: 40 });

    const untouched = fresh
      .filter((z) => !codes.includes(z.code))
      .map((z) => ({ code: z.code, name: z.name }));

    res.json({
      updated,
      untouched,
      coveragePct: coverage.coveragePct,
      message:
        `Boundaries computed for ${updated.length} zone(s) from their anchor points.` +
        (untouched.length
          ? ` ${untouched.map((z) => z.name).join(', ')} left unchanged — mark them to include them.`
          : ''),
    });
  }),
);

/**
 * GET /api/admin/zones/coverage
 * Samples a grid across campus and reports what is not covered by any zone.
 * Turns an invisible data problem - a gap nobody owns - into something the
 * admin can see before it swallows a complaint.
 */
router.get(
  '/coverage',
  asyncHandler(async (req, res) => {
    const steps = Math.min(Math.max(Number(req.query.steps ?? 40), 10), 80);
    const zones = await prisma.zone.findMany({ orderBy: { code: 'asc' } });
    const report = coverageReport(zones, { steps });

    const undrawn = zones
      .filter((z) => !Array.isArray(z.polygon) || z.polygon.length < 3)
      .map((z) => ({ code: z.code, name: z.name }));

    res.json({
      ...report,
      undrawn,
      overlapPairs: report.overlaps.map(([a, b]) => {
        const za = zones.find((z) => z.code === a);
        const zb = zones.find((z) => z.code === b);
        return { codes: [a, b], names: [za?.name, zb?.name] };
      }),
      summary:
        report.coveragePct === 100 && report.overlaps.length === 0
          ? 'Every part of campus belongs to exactly one zone.'
          : [
              report.coveragePct < 100
                ? `${100 - report.coveragePct}% of the campus area is not inside any zone. ` +
                  'Complaints there go to the zone with the nearest boundary.'
                : null,
              report.overlaps.length
                ? `${report.overlaps.length} pair(s) of zones overlap. ` +
                  'Complaints in the shared area go to the smaller zone.'
                : null,
            ]
              .filter(Boolean)
              .join(' '),
    });
  }),
);

/** GET /api/admin/zones/officers - for the officer picker. */
router.get(
  '/officers',
  asyncHandler(async (_req, res) => {
    const officers = await prisma.user.findMany({
      where: { role: 'OFFICER', isActive: true },
      include: { zoneOwned: { select: { code: true, name: true } } },
      orderBy: { name: 'asc' },
    });

    res.json({
      officers: officers.map((o) => ({
        id: o.id,
        name: o.name,
        email: o.email,
        phone: o.phone,
        currentZone: o.zoneOwned,
        available: o.zoneOwned == null,
      })),
    });
  }),
);

/**
 * POST /api/admin/zones/officers  { name, email, phone?, password, zoneCode }
 *
 * Zone officers are fixed faculty appointments, not self-registered: the
 * Admin creates the account and assigns the zone in one step, the same way
 * Worker Supervisor and Warden accounts are created. Skips the
 * PENDING/application dance entirely - the officer can open their queue the
 * moment this returns.
 */
router.post(
  '/officers',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      name: z.string().min(2, 'Name is too short'),
      email: z.string().trim().toLowerCase().pipe(z.string().email()),
      phone: z.string().min(10).max(15).optional(),
      password: z.string().min(6, 'Password must be at least 6 characters'),
      zoneCode: z.coerce.number().int().min(1).max(8),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid details', parsed.error.flatten().fieldErrors);
    }
    const { name, email, phone, password, zoneCode } = parsed.data;

    const zone = await prisma.zone.findUnique({ where: { code: zoneCode } });
    if (!zone) throw new ApiError(404, `Zone ${zoneCode} not found`);
    if (zone.officerId) {
      throw new ApiError(409, `${zone.name} already has an officer. Reassign it first.`);
    }

    const existing = await prisma.user.findFirst({
      where: { OR: [{ email: { equals: email, mode: 'insensitive' } }, ...(phone ? [{ phone }] : [])] },
    });
    if (existing) throw new ApiError(409, 'An account with that email or phone already exists');

    const passwordHash = await bcrypt.hash(password, 10);

    const officer = await prisma.$transaction(async (tx) => {
      const user = await tx.user.create({
        data: { name, email, phone, passwordHash, role: 'OFFICER' },
      });
      await tx.zone.update({ where: { id: zone.id }, data: { officerId: user.id } });
      return user;
    });

    await logAudit({
      actor: req.user,
      action: 'OFFICER_CREATED',
      targetType: 'USER',
      targetId: officer.id,
      targetLabel: officer.name,
      note: `Appointed to ${zone.name}`,
    });

    res.status(201).json({
      officer: { id: officer.id, name: officer.name, email: officer.email },
      message: `${officer.name} now runs ${zone.name}.`,
    });
  }),
);

/**
 * POST /api/admin/zones/recompute-neighbours
 * Manual trigger, useful after bulk edits or a data import.
 */
router.post(
  '/recompute-neighbours',
  asyncHandler(async (_req, res) => {
    const count = await recomputeNeighbours();
    res.json({ recomputed: count, message: `Neighbour ordering rebuilt for ${count} zones.` });
  }),
);

export { router as zoneAdminRouter, recomputeNeighbours };
