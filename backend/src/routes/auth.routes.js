import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate, signToken } from '../middleware/auth.js';
import { uploadMedia } from '../middleware/upload.js';
import { putMedia } from '../lib/storage.js';

const router = Router();

/** Shape returned to the client for the logged-in user. */
function publicUser(user) {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    phone: user.phone,
    role: user.role,
    // Worker-only
    worker: user.workerProfile
      ? {
          zoneId: user.workerProfile.zoneId,
          zone: user.workerProfile.zone
            ? {
                id: user.workerProfile.zone.id,
                code: user.workerProfile.zone.code,
                name: user.workerProfile.zone.name,
                label: user.workerProfile.zone.label,
              }
            : null,
          approvalStatus: user.workerProfile.approvalStatus,
          rejectionNote: user.workerProfile.rejectionNote,
          dutyStatus: user.workerProfile.dutyStatus,
          availability: user.workerProfile.availability,
          activeTaskCount: user.workerProfile.activeTaskCount,
          tasksCompletedToday: user.workerProfile.tasksCompletedToday,
          tasksCompletedTotal: user.workerProfile.tasksCompletedTotal,
        }
      : null,
    // Officer-only: the application, which exists from signup and is how the
    // app knows to show a "waiting for verification" screen rather than an
    // empty dashboard.
    officer: user.officerProfile
      ? {
          zoneId: user.officerProfile.zoneId,
          zone: user.officerProfile.zone
            ? {
                id: user.officerProfile.zone.id,
                code: user.officerProfile.zone.code,
                name: user.officerProfile.zone.name,
                label: user.officerProfile.zone.label,
              }
            : null,
          approvalStatus: user.officerProfile.approvalStatus,
          rejectionNote: user.officerProfile.rejectionNote,
        }
      : null,
    // The zone actually held. Null until an admin approves the application.
    zone: user.zoneOwned
      ? {
          id: user.zoneOwned.id,
          code: user.zoneOwned.code,
          name: user.zoneOwned.name,
          label: user.zoneOwned.label,
          colorHex: user.zoneOwned.colorHex,
        }
      : null,
  };
}

/**
 * Email as typed is not email as stored.
 *
 * Postgres compares strings case-sensitively, so an account created as
 * `Admin@mmmut.ac.in` could never be logged into by typing
 * `admin@mmmut.ac.in`, and a value pasted with a trailing space matches
 * nothing at all. Both come out as "Incorrect email or password", which sends
 * people looking for a wrong password that was never wrong.
 */
const emailField = z
  .string()
  .trim()
  .toLowerCase()
  .pipe(z.string().email());

const registerSchema = z.object({
  name: z.string().min(2, 'Name is too short'),
  email: emailField,
  phone: z.string().min(10).max(15).optional(),
  password: z.string().min(6, 'Password must be at least 6 characters'),
  role: z.enum(['RESIDENT', 'STUDENT', 'WORKER', 'OFFICER']).default('RESIDENT'),
  // Workers pick the zone they will serve; officers the zone they want to run
  zoneCode: z.coerce.number().int().min(1).max(8).optional(),
});

/** Roles that self-register but cannot act until an admin verifies them. */
const VERIFIED_ROLES = new Set(['WORKER', 'OFFICER']);

/**
 * POST /api/auth/register
 *
 * Residents and Students are usable immediately - they differ only in which
 * community feed their complaints appear in, which is no reason to make
 * someone wait. Workers and Officers are created PENDING
 * and can do nothing until the Admin verifies them - that gate lives in
 * `requireApprovedWorker` for workers, and in `requireApprovedOfficer` for
 * officers.
 *
 * An officer's zone choice is an application, not an appointment. Ownership
 * (Zone.officerId) is granted by the admin on approval, so several people may
 * apply for the same zone and the admin picks one.
 *
 * Admins are never self-registered.
 */
router.post(
  '/register',
  uploadMedia.single('idProof'),
  asyncHandler(async (req, res) => {
    const parsed = registerSchema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, 'Invalid registration details', parsed.error.flatten().fieldErrors);
    }
    const { name, email, phone, password, role, zoneCode } = parsed.data;

    const existing = await prisma.user.findFirst({
      where: {
        OR: [
          { email: { equals: email, mode: 'insensitive' } },
          ...(phone ? [{ phone }] : []),
        ],
      },
    });
    if (existing) throw new ApiError(409, 'An account with that email or phone already exists');

    const needsZone = VERIFIED_ROLES.has(role);
    if (needsZone && !zoneCode) {
      throw new ApiError(
        400,
        role === 'WORKER'
          ? 'Workers must select the zone they will work in'
          : 'Officers must select the zone they want to run',
      );
    }

    const zone = needsZone ? await prisma.zone.findUnique({ where: { code: zoneCode } }) : null;
    if (needsZone && !zone) throw new ApiError(404, `Zone ${zoneCode} does not exist`);

    // Applying for a zone that already has an officer would waste the
    // applicant's time: the admin could never approve it without first
    // removing the incumbent. Say so now rather than after a day of waiting.
    if (role === 'OFFICER' && zone.officerId) {
      throw new ApiError(
        409,
        `${zone.name} already has an officer. Choose a zone that is still open.`,
      );
    }

    const passwordHash = await bcrypt.hash(password, 10);

    const user = await prisma.user.create({
      data: {
        name,
        email,
        phone,
        passwordHash,
        role,
        ...(needsZone
          ? {
              [role === 'WORKER' ? 'workerProfile' : 'officerProfile']: {
                create: {
                  zoneId: zone.id,
                  idProofUrl: req.file ? await putMedia(req.file) : null,
                  approvalStatus: 'PENDING',
                },
              },
            }
          : {}),
      },
      include: {
        workerProfile: { include: { zone: true } },
        officerProfile: { include: { zone: true } },
        zoneOwned: true,
      },
    });

    // Let the admins know there is someone to verify.
    if (needsZone) {
      const admins = await prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } });
      if (admins.length) {
        const what = role === 'WORKER' ? 'worker' : 'zone officer';
        await prisma.notification.createMany({
          data: admins.map((a) => ({
            userId: a.id,
            title: `New ${what} awaiting verification`,
            body: `${name} applied for ${zone.name} (${zone.label}).`,
          })),
        });
      }
    }

    res.status(201).json({
      token: signToken(user),
      user: publicUser(user),
      message:
        role === 'WORKER'
          ? 'Registered. An admin must verify your account before you can receive tasks.'
          : role === 'OFFICER'
            ? `Applied to run ${zone.name}. An admin must approve you before the zone is yours.`
            : 'Registered successfully.',
    });
  }),
);

/** POST /api/auth/login */
router.post(
  '/login',
  asyncHandler(async (req, res) => {
    const schema = z.object({
      email: emailField,
      password: z.string().min(1),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Email and password are required');

    // Case-insensitive match rather than an exact one. Normalising the input
    // is not enough on its own: accounts created before that normalisation
    // existed may be stored with capitals, and their owners would be locked
    // out permanently.
    const user = await prisma.user.findFirst({
      where: { email: { equals: parsed.data.email, mode: 'insensitive' } },
      include: {
        workerProfile: { include: { zone: true } },
        officerProfile: { include: { zone: true } },
        zoneOwned: true,
      },
    });

    // Same message either way, so the endpoint cannot be used to discover
    // which email addresses exist.
    if (!user) throw new ApiError(401, 'Incorrect email or password');

    const ok = await bcrypt.compare(parsed.data.password, user.passwordHash);
    if (!ok) throw new ApiError(401, 'Incorrect email or password');
    if (!user.isActive) throw new ApiError(403, 'Your account has been disabled');

    res.json({ token: signToken(user), user: publicUser(user) });
  }),
);

/** GET /api/auth/me - used on app launch to restore the session. */
router.get(
  '/me',
  authenticate,
  asyncHandler(async (req, res) => {
    const unread = await prisma.notification.count({
      where: { userId: req.user.id, readAt: null },
    });
    res.json({ user: publicUser(req.user), unreadNotifications: unread });
  }),
);

export { router as authRouter, publicUser };

