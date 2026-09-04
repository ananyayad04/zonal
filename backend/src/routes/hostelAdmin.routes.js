import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, requireRole } from '../middleware/auth.js';
import { notify } from '../services/workflow.js';
import { logAudit } from '../services/audit.js';

const router = Router();

router.use(authenticate, requireRole('ADMIN'));

const HOSTEL_CATEGORIES = ['BOYS_HOSTEL', 'GIRLS_HOSTEL'];

/** GET /api/admin/hostels - every hostel-category landmark with its warden. */
router.get(
  '/',
  asyncHandler(async (_req, res) => {
    const hostels = await prisma.landmark.findMany({
      where: { category: { in: HOSTEL_CATEGORIES } },
      include: { warden: { select: { id: true, name: true, email: true, phone: true } } },
      orderBy: [{ category: 'asc' }, { sortOrder: 'asc' }, { name: 'asc' }],
    });

    res.json({
      hostels: hostels.map((h) => ({
        id: h.id,
        name: h.name,
        category: h.category,
        warden: h.warden,
      })),
    });
  }),
);

/**
 * PUT /api/admin/hostels/:landmarkId  { wardenId: string | null }
 * Assign, reassign or clear the warden for one hostel.
 *
 * Mirrors the zone/officer reassignment guard in zoneAdmin.routes.js: an
 * outgoing warden holding open hostel complaints cannot just be swapped out
 * from under them.
 */
router.put(
  '/:landmarkId',
  asyncHandler(async (req, res) => {
    const schema = z.object({ wardenId: z.string().min(1).nullable() });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'wardenId is required (or null to clear it)');

    const landmark = await prisma.landmark.findUnique({ where: { id: req.params.landmarkId } });
    if (!landmark) throw new ApiError(404, 'Hostel not found');
    if (!HOSTEL_CATEGORIES.includes(landmark.category)) {
      throw new ApiError(400, `${landmark.name} is not a hostel`);
    }

    const previousWardenId = landmark.wardenId;

    if (parsed.data.wardenId) {
      const warden = await prisma.user.findUnique({
        where: { id: parsed.data.wardenId },
        include: { hostelOwned: true },
      });
      if (!warden || warden.role !== 'WARDEN') {
        throw new ApiError(400, 'That user is not a warden');
      }
      if (warden.hostelOwned && warden.hostelOwned.id !== landmark.id) {
        throw new ApiError(
          409,
          `${warden.name} already runs ${warden.hostelOwned.name}. Free them from that hostel first.`,
        );
      }
    }

    if (previousWardenId && previousWardenId !== parsed.data.wardenId) {
      const openCount = await prisma.complaint.count({
        where: { assignedWardenId: previousWardenId, status: 'ALLOTTED_TO_HOSTEL_STAFF' },
      });
      if (openCount > 0) {
        throw new ApiError(
          409,
          `The current warden still has ${openCount} complaint(s) waiting to be allotted. ` +
            'Clear those before reassigning the hostel.',
        );
      }
    }

    const updated = await prisma.landmark.update({
      where: { id: landmark.id },
      data: { wardenId: parsed.data.wardenId },
      include: { warden: { select: { id: true, name: true, email: true } } },
    });

    if (updated.wardenId) {
      await notify({
        userId: updated.wardenId,
        title: `You now run ${updated.name}`,
        body: 'Hostel complaints filed there come to you.',
      });
    }

    await logAudit({
      actor: req.user,
      action: 'WARDEN_REASSIGNED',
      targetType: 'HOSTEL',
      targetId: updated.id,
      targetLabel: updated.name,
      note: updated.warden ? `Now run by ${updated.warden.name}` : 'Warden cleared',
    });

    res.json({
      hostel: { id: updated.id, name: updated.name, category: updated.category, warden: updated.warden },
      message: updated.warden ? `${updated.warden.name} now runs ${updated.name}.` : `${updated.name} has no warden.`,
    });
  }),
);

// ---------------------------------------------------------------------------
// Warden accounts
//
// Like Worker Supervisor, there is no self-registration: the Admin creates
// the account and assigns it to a hostel in the same step, so a warden is
// never left unassigned.
// ---------------------------------------------------------------------------

/** GET /api/admin/hostels/wardens - existing Warden accounts. */
router.get(
  '/wardens',
  asyncHandler(async (_req, res) => {
    const wardens = await prisma.user.findMany({
      where: { role: 'WARDEN' },
      include: { hostelOwned: { select: { id: true, name: true, category: true } } },
      orderBy: { name: 'asc' },
    });

    res.json({
      wardens: wardens.map((w) => ({
        id: w.id,
        name: w.name,
        email: w.email,
        phone: w.phone,
        isActive: w.isActive,
        hostel: w.hostelOwned,
      })),
    });
  }),
);

/** POST /api/admin/hostels/wardens  { name, email, phone?, password, landmarkId } */
router.post(
  '/wardens',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      name: z.string().min(2, 'Name is too short'),
      email: z.string().trim().toLowerCase().pipe(z.string().email()),
      phone: z.string().min(10).max(15).optional(),
      password: z.string().min(6, 'Password must be at least 6 characters'),
      landmarkId: z.string().min(1, 'Choose which hostel this warden runs'),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid details', parsed.error.flatten().fieldErrors);
    }
    const { name, email, phone, password, landmarkId } = parsed.data;

    const landmark = await prisma.landmark.findUnique({ where: { id: landmarkId } });
    if (!landmark) throw new ApiError(404, 'Hostel not found');
    if (!HOSTEL_CATEGORIES.includes(landmark.category)) {
      throw new ApiError(400, `${landmark.name} is not a hostel`);
    }
    if (landmark.wardenId) {
      throw new ApiError(409, `${landmark.name} already has a warden. Reassign it first.`);
    }

    const existing = await prisma.user.findFirst({
      where: { OR: [{ email: { equals: email, mode: 'insensitive' } }, ...(phone ? [{ phone }] : [])] },
    });
    if (existing) throw new ApiError(409, 'An account with that email or phone already exists');

    const passwordHash = await bcrypt.hash(password, 10);

    const warden = await prisma.$transaction(async (tx) => {
      const user = await tx.user.create({
        data: { name, email, phone, passwordHash, role: 'WARDEN' },
      });
      await tx.landmark.update({ where: { id: landmark.id }, data: { wardenId: user.id } });
      return user;
    });

    await logAudit({
      actor: req.user,
      action: 'WARDEN_CREATED',
      targetType: 'USER',
      targetId: warden.id,
      targetLabel: warden.name,
      note: `Appointed to ${landmark.name}`,
    });

    res.status(201).json({
      warden: { id: warden.id, name: warden.name, email: warden.email },
      message: `${warden.name} now runs ${landmark.name}.`,
    });
  }),
);

export { router as hostelAdminRouter };
