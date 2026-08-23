import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma.js';
import { env } from '../config/env.js';
import { ApiError, asyncHandler } from '../middleware/error.js';
import { authenticate } from '../middleware/auth.js';
import {
  uploadMedia,
  mediaTypeFor,
  assertWithinTypeLimit,
  assertWithinDurationLimit,
} from '../middleware/upload.js';
import { putMedia, removeMedia } from '../lib/storage.js';
import { detectZone, haversineMeters } from '../utils/geo.js';
import { transition, notify, notifyMany, generateRef } from '../services/workflow.js';
import { releaseWorker, broadcastEmergency } from '../services/allocation.js';
import { findRecurrence } from '../services/insights.js';
import {
  complaintInclude,
  serializeComplaint,
  loadComplaintForResponse,
} from '../utils/serialize.js';

const router = Router();

const createSchema = z.object({
  category: z.enum([
    'GARBAGE',
    'OVERFLOWING_BIN',
    'WASHROOM',
    'WATER_LOGGING',
    'DRAINAGE',
    'PEST',
    'OTHER',
  ]),
  description: z.string().max(1000).optional(),
  /// The confirmed pin.
  lat: z.coerce.number().min(-90).max(90),
  lng: z.coerce.number().min(-180).max(180),
  accuracyM: z.coerce.number().nonnegative().optional(),
  /// The raw device fix, when the pin was corrected off it.
  gpsLat: z.coerce.number().min(-90).max(90).optional(),
  gpsLng: z.coerce.number().min(-180).max(180).optional(),
  gpsAccuracyM: z.coerce.number().nonnegative().optional(),
  /// When the fix was taken, ISO-8601.
  locationCapturedAt: z.string().optional(),
  priority: z.enum(['LOW', 'MEDIUM', 'HIGH']).optional(),
  /// Emergency reports skip admin verification and are broadcast campus-wide.
  isEmergency: z
    .union([z.boolean(), z.enum(['true', 'false'])])
    .transform((v) => v === true || v === 'true')
    .optional(),
  /// Set only when the resident corrected the auto-detected zone.
  zoneCode: z.coerce.number().int().min(1).max(8).optional(),
  /// COMPULSORY. GPS gives the zone; this gives the address. A worker sent to
  /// "Zone 3" still has to hunt - "CSE Department" they can walk straight to.
  landmarkId: z.string().min(1, 'Choose the nearest place or landmark'),
  /// Optional detail: "second floor washroom", "behind the canteen".
  landmarkNote: z.string().max(200).optional(),
  /// JSON array, one entry per uploaded file, in the same order:
  /// [{ "durationSec": 12, "lat": 26.8, "lng": 80.9, "capturedAt": "..." }]
  mediaMeta: z.string().optional(),
});

/**
 * Uploads are held in memory until the storage layer accepts them, so a
 * request that fails validation leaves nothing behind and needs no cleanup.
 *
 * What DOES need cleaning up is anything already handed to storage before a
 * later step failed - those objects are real and would otherwise be orphaned.
 */
const cleanUpFiles = () => {};

const discardStored = async (prepared = []) => {
  await Promise.all(prepared.map((p) => removeMedia(p.url)));
};

/**
 * POST /api/complaints
 *
 * The compulsory-geotag rule is enforced here: no valid lat/lng, no complaint.
 * At least one attachment is also required - a complaint with no evidence is
 * not actionable by a worker who has to go and find the spot.
 */
router.post(
  '/',
  authenticate,
  uploadMedia.array('media', 5),
  asyncHandler(async (req, res) => {
    const files = req.files ?? [];

    const parsed = createSchema.safeParse(req.body);
    if (!parsed.success) {
      cleanUpFiles(files);
      throw new ApiError(
        400,
        'A category and a valid GPS location are required',
        parsed.error.flatten().fieldErrors,
      );
    }

    if (!files.length) {
      throw new ApiError(400, 'Attach at least one photo, video or audio recording');
    }

    const {
      category,
      description,
      lat,
      lng,
      accuracyM,
      priority,
      zoneCode,
      mediaMeta,
      landmarkId,
      landmarkNote,
      gpsLat,
      gpsLng,
      gpsAccuracyM,
      locationCapturedAt,
      isEmergency = false,
    } = parsed.data;

    // How far the pin was moved off the raw GPS reading, if at all.
    const hasRawFix = Number.isFinite(gpsLat) && Number.isFinite(gpsLng);
    const adjustedM = hasRawFix ? haversineMeters(gpsLat, gpsLng, lat, lng) : 0;
    const locationAdjusted = hasRawFix && adjustedM > 5;

    // A nudge to correct a poor indoor fix is fine. Dragging the pin across
    // campus is not - that would make the geotag meaningless.
    if (locationAdjusted && adjustedM > env.maxPinAdjustMeters) {
      cleanUpFiles(files);
      throw new ApiError(
        400,
        `The pin is ${Math.round(adjustedM)}m from where your phone says you are. ` +
          `Move it back within ${env.maxPinAdjustMeters}m, or refresh your location.`,
      );
    }

    const landmark = await prisma.landmark.findUnique({ where: { id: landmarkId } });
    if (!landmark || !landmark.isActive) {
      cleanUpFiles(files);
      throw new ApiError(400, 'Choose a valid place or landmark');
    }

    let meta = [];
    if (mediaMeta) {
      try {
        meta = JSON.parse(mediaMeta);
        if (!Array.isArray(meta)) meta = [];
      } catch {
        cleanUpFiles(files);
        throw new ApiError(400, 'mediaMeta must be a JSON array');
      }
    }

    // Validate every file before writing anything to the database.
    const prepared = [];
    try {
      for (const [i, file] of files.entries()) {
        const type = assertWithinTypeLimit(file);
        const m = meta[i] ?? {};
        assertWithinDurationLimit(type, m.durationSec);

        prepared.push({
          url: await putMedia(file),
          type,
          phase: 'BEFORE',
          mimeType: file.mimetype,
          sizeBytes: file.size,
          durationSec: m.durationSec ?? null,
          // Fall back to the complaint's fix when the file carries no EXIF GPS.
          capturedLat: m.lat ?? lat,
          capturedLng: m.lng ?? lng,
          capturedAt: m.capturedAt ? new Date(m.capturedAt) : new Date(),
          uploadedById: req.user.id,
        });
      }
    } catch (err) {
      // Some files may already be in storage - remove them rather than leak.
      await discardStored(prepared);
      throw err;
    }

    // Resolve the zone: the resident's override wins, otherwise point-in-polygon.
    const zones = await prisma.zone.findMany({ orderBy: { code: 'asc' } });
    if (!zones.length) {
      await discardStored(prepared);
      throw new ApiError(500, 'No zones configured - run the seed');
    }

    let detected;
    try {
      detected = detectZone(lat, lng, zones);
    } catch (err) {
      await discardStored(prepared);
      if (err.code === 'NO_ZONES_CONFIGURED') {
        throw new ApiError(
          503,
          'The campus zones have not been set up yet. Ask the admin to draw the ' +
            'zone boundaries before complaints can be filed.',
        );
      }
      throw err;
    }
    const overrideZone = zoneCode ? zones.find((z) => z.code === zoneCode) : null;
    const zone = overrideZone ?? detected.zone;
    const zoneOverridden = Boolean(overrideZone && overrideZone.id !== detected.zone.id);

    // Record HOW the zone was decided. Anything other than a clean polygon hit
    // is a boundary case, and the admin's verification screen surfaces it so a
    // human can correct the zone before it reaches an officer.
    const zoneResolvedBy = zoneOverridden ? 'RESIDENT_OVERRIDE' : detected.resolvedBy;
    const zoneDistanceM = zoneOverridden ? null : Math.round(detected.distanceM);

    // Was this exact place signed off only days ago?
    const recurrence = await findRecurrence({
      landmarkId: landmark.id,
      category,
      reporterId: req.user.id,
    });

    const ref = await generateRef();

    const complaint = await prisma.complaint.create({
      data: {
        ref,
        category,
        description,
        lat,
        lng,
        accuracyM,
        gpsLat: hasRawFix ? gpsLat : lat,
        gpsLng: hasRawFix ? gpsLng : lng,
        gpsAccuracyM: gpsAccuracyM ?? accuracyM,
        locationCapturedAt: locationCapturedAt
          ? new Date(locationCapturedAt)
          : new Date(),
        locationAdjusted,
        locationAdjustedM: locationAdjusted ? Math.round(adjustedM) : null,
        priority: isEmergency ? 'HIGH' : (priority ?? 'MEDIUM'),
        isEmergency,
        zoneId: zone.id,
        zoneOverridden,
        zoneResolvedBy,
        zoneDistanceM,
        landmarkId: landmark.id,
        // Snapshot the name so renaming a landmark later cannot rewrite what
        // past complaints said.
        landmarkName: landmark.name,
        landmarkNote: landmarkNote ?? null,
        recurrenceOfId: recurrence?.id ?? null,
        recurrenceDays: recurrence?.days ?? null,
        reporterId: req.user.id,
        // Snapshotted, like the landmark name and the zone: whoever could see
        // this on the day it was filed is who can see it forever, even if the
        // reporter's role changes later.
        reporterRole: req.user.role,
        status: 'SUBMITTED',
        media: { create: prepared },
      },
      include: complaintInclude,
    });

    await prisma.statusLog.create({
      data: {
        complaintId: complaint.id,
        toStatus: 'SUBMITTED',
        actorId: req.user.id,
        note:
          `Filed in ${zone.name}` +
          (zoneOverridden
            ? ' (zone corrected by the resident)'
            : detected.resolvedBy === 'POLYGON'
              ? ''
              : ` (${detected.resolvedBy.toLowerCase().replace(/_/g, ' ')}, ` +
                `${Math.round(detected.distanceM)}m from the boundary)`),
      },
    });

    // Emergencies bypass the admin gate and go out to everyone at once.
    if (isEmergency) {
      const { notified } = await broadcastEmergency(complaint, { actor: req.user });
      const full = await loadComplaintForResponse(prisma, complaint.id);

      return res.status(201).json({
        complaint: serializeComplaint(full),
        message:
          `Emergency reported. ${notified.total} people alerted â€” ` +
          `${notified.officers} officers, ${notified.workers} on-duty workers, ` +
          `${notified.residents} residents.`,
      });
    }

    // Straight into the Admin's verification queue.
    const underReview = await transition({
      complaintId: complaint.id,
      toStatus: 'UNDER_REVIEW',
      isSystem: true,
      note: 'Awaiting admin verification',
    });

    // Both the admin AND the zone's own officer are told straight away.
    // Waiting for admin approval before the officer even knows a complaint
    // exists costs time for no benefit - the officer can be lining up a worker
    // while verification happens. Either of them can verify it.
    const admins = await prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } });
    const zoneWithOfficer = await prisma.zone.findUnique({
      where: { id: zone.id },
      select: { officerId: true },
    });

    await notifyMany([
      ...admins.map((a) => ({
        userId: a.id,
        complaintId: complaint.id,
        title: 'New complaint to verify',
        body: `${ref} - ${category} at ${landmark.name} (${zone.name}).`,
      })),
      // notifyMany drops entries with no userId, so an unstaffed zone is safe.
      {
        userId: zoneWithOfficer?.officerId,
        complaintId: complaint.id,
        title: `New complaint in ${zone.name}`,
        body: `${ref} at ${landmark.name}. Awaiting verification â€” you can verify it yourself.`,
      },
    ]);

    res.status(201).json({
      complaint: serializeComplaint({ ...complaint, ...underReview }),
      message: 'Complaint submitted. It will be verified by the admin shortly.',
    });
  }),
);

/** GET /api/complaints/mine - the resident's own history. */
router.get(
  '/mine',
  authenticate,
  asyncHandler(async (req, res) => {
    const { status } = req.query;

    const complaints = await prisma.complaint.findMany({
      where: {
        reporterId: req.user.id,
        ...(status ? { status } : {}),
      },
      include: complaintInclude,
      orderBy: { submittedAt: 'desc' },
    });

    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/**
 * Statuses a complaint reaches only after it has been let through.
 *
 * SUBMITTED and UNDER_REVIEW are deliberately absent: nothing appears in a
 * community feed before an admin has confirmed it is genuine, or the feed
 * becomes the place spam lands. REJECTED_INVALID never appears at all.
 */
const APPROVED_STATUSES = [
  'ALLOTTED_TO_OFFICER',
  'HELP_REQUESTED',
  'ALLOTTED_TO_WORKER',
  'IN_PROGRESS',
  'WORK_DONE',
  'REOPENED',
  'ESCALATED',
  'CLOSED',
  'AUTO_CLOSED',
];

/** Roles that read a community feed rather than a work queue. */
const REPORTER_ROLES = ['RESIDENT', 'STUDENT'];

/**
 * GET /api/complaints/community
 *
 * Every approved complaint filed by the caller's own community, theirs
 * included. Residents see resident reports; students see student reports;
 * neither ever sees the other's.
 *
 * The filter is on the complaint's snapshotted reporterRole, not on a join to
 * the reporter's current role, so moving somebody between roles cannot
 * retroactively expose what they filed to a different audience.
 */
router.get(
  '/community',
  authenticate,
  asyncHandler(async (req, res) => {
    if (!REPORTER_ROLES.includes(req.user.role)) {
      throw new ApiError(
        403,
        'The community feed is for residents and students. Staff see complaints through their own queues.',
      );
    }

    const complaints = await prisma.complaint.findMany({
      where: {
        reporterRole: req.user.role,
        status: { in: APPROVED_STATUSES },
      },
      include: complaintInclude,
      orderBy: { submittedAt: 'desc' },
      take: 100,
    });

    res.json({
      audience: req.user.role,
      complaints: complaints.map((c) =>
        // Peers get the report without the reporter's phone number.
        serializeComplaint(c, { peer: c.reporterId !== req.user.id }),
      ),
    });
  }),
);

/**
 * GET /api/complaints/awaiting-confirmation
 * Drives the satisfaction popup - anything the worker has finished that this
 * resident has not yet responded to.
 */
router.get(
  '/awaiting-confirmation',
  authenticate,
  asyncHandler(async (req, res) => {
    const complaints = await prisma.complaint.findMany({
      where: { reporterId: req.user.id, status: 'WORK_DONE', satisfaction: 'PENDING' },
      include: complaintInclude,
      orderBy: { doneAt: 'asc' },
    });
    res.json({ complaints: complaints.map(serializeComplaint) });
  }),
);

/** GET /api/complaints/:id - full detail plus the audit trail. */
router.get(
  '/:id',
  authenticate,
  asyncHandler(async (req, res) => {
    const complaint = await prisma.complaint.findUnique({
      where: { id: req.params.id },
      include: {
        ...complaintInclude,
        statusLogs: {
          include: { actor: { select: { id: true, name: true, role: true } } },
          orderBy: { at: 'asc' },
        },
        helpRequests: {
          include: {
            fromOfficer: { select: { id: true, name: true } },
            acceptedByOfficer: { select: { id: true, name: true } },
            fromZone: { select: { code: true, name: true } },
          },
          orderBy: { createdAt: 'desc' },
        },
      },
    });

    if (!complaint) throw new ApiError(404, 'Complaint not found');

    const { role, id: userId } = req.user;
    const isOwn = complaint.reporterId === userId;

    // Anyone whose community filed it may read it, once it has been approved -
    // otherwise every card in the community feed would open onto a 403. The
    // check mirrors that feed exactly: same audience, same statuses.
    const isPeer =
      REPORTER_ROLES.includes(role) &&
      complaint.reporterRole === role &&
      APPROVED_STATUSES.includes(complaint.status);

    const permitted =
      role === 'ADMIN' ||
      role === 'OFFICER' ||
      isOwn ||
      isPeer ||
      complaint.assignedWorkerId === userId;
    if (!permitted) throw new ApiError(403, 'You do not have access to this complaint');

    res.json({
      // A peer reading a neighbour's complaint gets the report, not their
      // phone number.
      complaint: serializeComplaint(complaint, { peer: !isOwn && isPeer }),
      timeline: complaint.statusLogs.map((l) => ({
        from: l.fromStatus,
        to: l.toStatus,
        actor: l.actor ? { name: l.actor.name, role: l.actor.role } : null,
        isSystem: l.isSystem,
        note: l.note,
        at: l.at,
      })),
      helpRequests: complaint.helpRequests.map((h) => ({
        id: h.id,
        status: h.status,
        fromOfficer: h.fromOfficer,
        fromZone: h.fromZone,
        targetZoneCodes: h.targetZoneCodes,
        acceptedByOfficer: h.acceptedByOfficer,
        note: h.note,
        createdAt: h.createdAt,
        expiresAt: h.expiresAt,
        respondedAt: h.respondedAt,
      })),
    });
  }),
);

/**
 * POST /api/complaints/:id/satisfaction
 *
 * The tick-OK button. Only the person who filed it may answer.
 *   satisfied: true  -> CLOSED
 *   satisfied: false -> back to the same worker once; a second rejection
 *                       escalates to the Admin instead of ping-ponging.
 */
router.post(
  '/:id/satisfaction',
  authenticate,
  asyncHandler(async (req, res) => {
    // Who you are is settled before what you sent. Validating the body first
    // would answer a stranger's malformed request with advice on how to fix
    // it, when the right answer is that this complaint is not theirs to close.
    const complaint = await prisma.complaint.findUnique({ where: { id: req.params.id } });
    if (!complaint) throw new ApiError(404, 'Complaint not found');

    if (complaint.reporterId !== req.user.id) {
      throw new ApiError(403, 'Only the person who filed this complaint can confirm it');
    }
    if (complaint.status !== 'WORK_DONE') {
      throw new ApiError(409, 'This complaint is not waiting for your confirmation');
    }

    const schema = z.object({
      satisfied: z.coerce.boolean(),
      // Required either way. Signing off is the only moment anyone hears from
      // the person the work was actually for, and "closed, no comment" tells
      // the officer nothing about whether the fix will hold.
      note: z
        .string({ required_error: 'Say a few words about the work' })
        .trim()
        .min(3, 'Say a few words about the work')
        .max(500),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(
        400,
        parsed.error.flatten().fieldErrors.note?.[0] ??
          '`satisfied` must be true or false',
      );
    }

    const { satisfied, note } = parsed.data;

    if (satisfied) {
      await releaseWorker(complaint.assignedWorkerId, { completed: true });

      await transition({
        complaintId: complaint.id,
        toStatus: 'CLOSED',
        actor: req.user,
        note: `Reporter approved the work: ${note}`,
        data: { satisfaction: 'SATISFIED', feedbackNote: note },
      });

      await notifyMany([
        {
          userId: complaint.assignedWorkerId,
          complaintId: complaint.id,
          title: 'Work approved',
          body: `${complaint.ref} was approved. "${note}"`,
        },
        {
          userId: complaint.assignedOfficerId,
          complaintId: complaint.id,
          title: 'Complaint closed',
          body: `${complaint.ref} has been closed.`,
        },
      ]);

      const closed = await loadComplaintForResponse(prisma, complaint.id);
      return res.json({ complaint: serializeComplaint(closed), message: 'Complaint closed.' });
    }

    // Not satisfied.
    const nextReopenCount = complaint.reopenCount + 1;
    const exhausted = nextReopenCount > env.maxReopenCount;

    if (exhausted) {
      await releaseWorker(complaint.assignedWorkerId, { completed: false });

      await transition({
        complaintId: complaint.id,
        toStatus: 'ESCALATED',
        actor: req.user,
        note: `Rejected ${nextReopenCount} times - escalated to admin`,
        data: {
          satisfaction: 'UNSATISFIED',
          unsatisfiedNote: note ?? null,
          reopenCount: nextReopenCount,
          escalationReason: 'REJECTED_TWICE',
          assignedWorkerId: null,
        },
      });

      const admins = await prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } });
      await notifyMany([
        ...admins.map((a) => ({
          userId: a.id,
          complaintId: complaint.id,
          title: 'Complaint escalated',
          body: `${complaint.ref} was rejected by the resident more than once.`,
        })),
        {
          userId: complaint.assignedOfficerId,
          complaintId: complaint.id,
          title: 'Complaint escalated to admin',
          body: `${complaint.ref} was rejected again and is now with the admin.`,
        },
      ]);

      const escalated = await loadComplaintForResponse(prisma, complaint.id);
      return res.json({
        complaint: serializeComplaint(escalated),
        message: 'This has been escalated to the campus admin.',
      });
    }

    // First rejection - straight back to the same worker.
    await transition({
      complaintId: complaint.id,
      toStatus: 'REOPENED',
      actor: req.user,
      note: note ? `Resident not satisfied: ${note}` : 'Resident not satisfied',
      data: {
        satisfaction: 'UNSATISFIED',
        unsatisfiedNote: note ?? null,
        reopenCount: nextReopenCount,
      },
    });

    await notifyMany([
      {
        userId: complaint.assignedWorkerId,
        complaintId: complaint.id,
        title: 'Work sent back',
        body: `${complaint.ref}: ${note ?? 'the resident was not satisfied'}. Please redo it.`,
      },
      {
        userId: complaint.assignedOfficerId,
        complaintId: complaint.id,
        title: 'Complaint reopened',
        body: `${complaint.ref} was sent back by the resident.`,
      },
    ]);

    const reopened = await loadComplaintForResponse(prisma, complaint.id);
    res.json({
      complaint: serializeComplaint(reopened),
      message: 'Sent back to the worker.',
    });
  }),
);

export { router as complaintRouter };

