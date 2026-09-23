import { prisma } from '../lib/prisma.js';
import { ApiError } from '../middleware/error.js';
import { assertWithinTypeLimit, assertWithinDurationLimit } from '../middleware/upload.js';
import { putMedia, removeMedia } from '../lib/storage.js';
import { transition, notify, notifyMany } from './workflow.js';
import { complaintInclude, serializeComplaint, loadComplaintForResponse } from '../utils/serialize.js';

/**
 * Start a task: ALLOTTED_TO_WORKER/REOPENED -> IN_PROGRESS.
 *
 * `actor` is whoever is performing the action (the worker themselves, or a
 * supervisor acting on a phone-less worker's behalf) - `workerName` is
 * always the assigned worker's own name, since the resident-facing
 * notification must say who is actually doing the work regardless of who
 * pressed the button.
 */
export async function startTask({ complaint, actor, workerName }) {
  if (!['ALLOTTED_TO_WORKER', 'REOPENED'].includes(complaint.status)) {
    throw new ApiError(409, `You cannot start a task that is ${complaint.status}`);
  }

  await transition({
    complaintId: complaint.id,
    toStatus: 'IN_PROGRESS',
    actor,
    note: complaint.status === 'REOPENED' ? 'Worker restarted after rework' : 'Worker started',
  });
  const updated = await loadComplaintForResponse(prisma, complaint.id);

  await notify({
    userId: complaint.reporterId,
    complaintId: complaint.id,
    title: 'Work started',
    body: `${complaint.ref}: ${workerName} has started work.`,
  });

  return { complaint: serializeComplaint(updated), message: 'Task started.' };
}

/**
 * Mark a task done: IN_PROGRESS -> WORK_DONE, with at least one AFTER photo
 * as proof. The worker stays attached until the resident responds, so a
 * rejection can go straight back to the same person.
 */
export async function completeTask({ complaint, actor, files, mediaMetaRaw, note }) {
  files = files ?? [];

  if (complaint.status !== 'IN_PROGRESS') {
    throw new ApiError(409, 'Start the task before marking it done');
  }
  if (!files.length) {
    throw new ApiError(400, 'Attach at least one photo of the completed work');
  }

  let meta = [];
  if (mediaMetaRaw) {
    try {
      meta = JSON.parse(mediaMetaRaw);
      if (!Array.isArray(meta)) meta = [];
    } catch {
      throw new ApiError(400, 'mediaMeta must be a JSON array');
    }
  }

  const prepared = [];
  try {
    for (const [i, file] of files.entries()) {
      const type = assertWithinTypeLimit(file);
      const m = meta[i] ?? {};
      assertWithinDurationLimit(type, m.durationSec);

      prepared.push({
        complaintId: complaint.id,
        url: await putMedia(file),
        type,
        phase: 'AFTER',
        mimeType: file.mimetype,
        sizeBytes: file.size,
        durationSec: m.durationSec ?? null,
        capturedLat: m.lat ?? complaint.lat,
        capturedLng: m.lng ?? complaint.lng,
        capturedAt: m.capturedAt ? new Date(m.capturedAt) : new Date(),
        uploadedById: actor.id,
      });
    }
  } catch (err) {
    // Some proof photos may already be stored - remove them rather than leak.
    await Promise.all(prepared.map((p) => removeMedia(p.url)));
    throw err;
  }

  await prisma.media.createMany({ data: prepared });

  const updated = await transition({
    complaintId: complaint.id,
    toStatus: 'WORK_DONE',
    actor,
    note: note ? `Worker: ${note}` : 'Work completed, proof uploaded',
  });

  await notifyMany([
    {
      userId: complaint.reporterId,
      complaintId: complaint.id,
      title: 'Please confirm the work',
      body: `${complaint.ref} has been completed. Open the app to approve or send it back.`,
    },
    {
      userId: complaint.assignedOfficerId,
      complaintId: complaint.id,
      title: 'Work completed',
      body: `${complaint.ref} is done and awaiting the resident's confirmation.`,
    },
  ]);

  const full = await prisma.complaint.findUnique({
    where: { id: complaint.id },
    include: complaintInclude,
  });

  return {
    complaint: serializeComplaint({ ...full, ...updated, media: full.media }),
    message: 'Marked done. Waiting for the resident to confirm.',
  };
}
