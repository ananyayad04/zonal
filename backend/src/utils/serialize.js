/** Shared shapes so every endpoint returns a complaint the same way. */

import { signMediaUrls } from '../lib/storage.js';

/**
 * Replace stored media keys with URLs the app can actually load.
 *
 * Done in one pass over the whole response rather than per complaint: a list
 * of twenty complaints would otherwise mean twenty round trips to sign twenty
 * URLs. Signed links expire, which is why only the bare key is ever persisted.
 *
 * @param {object|object[]} payload serialized complaint(s)
 */
export async function withMediaUrls(payload) {
  const list = Array.isArray(payload) ? payload : [payload];

  const keys = [];
  for (const c of list) {
    if (!c) continue;
    for (const m of [...(c.beforeMedia ?? []), ...(c.afterMedia ?? [])]) {
      if (m?.url) keys.push(m.url);
    }
  }

  if (keys.length === 0) return payload;

  const signed = await signMediaUrls(keys);

  for (const c of list) {
    if (!c) continue;
    for (const m of [...(c.beforeMedia ?? []), ...(c.afterMedia ?? [])]) {
      if (m?.url && signed.has(m.url)) m.url = signed.get(m.url);
    }
  }

  return payload;
}

export const complaintInclude = {
  zone: { select: { id: true, code: true, name: true, label: true, colorHex: true } },
  lendingZone: { select: { id: true, code: true, name: true } },
  reporter: { select: { id: true, name: true, phone: true, role: true } },
  assignedOfficer: { select: { id: true, name: true, phone: true } },
  assignedWorker: { select: { id: true, name: true, phone: true } },
  assignedWarden: { select: { id: true, name: true, phone: true } },
  media: true,
};

/**
 * Re-read a complaint with all of its relations.
 *
 * `transition()` returns a bare `update()` result, which carries the scalar
 * columns but none of the relations - serializing that directly yields
 * `zone: null` and `lendingZone: null`. Any route that returns a complaint
 * after a transition must load it through here first.
 */
export const loadComplaintForResponse = (db, id) =>
  db.complaint.findUnique({ where: { id }, include: complaintInclude });

export function serializeMedia(m) {
  return {
    id: m.id,
    url: m.url,
    type: m.type,
    phase: m.phase,
    durationSec: m.durationSec,
    location:
      m.capturedLat != null && m.capturedLng != null
        ? { lat: m.capturedLat, lng: m.capturedLng }
        : null,
    capturedAt: m.capturedAt,
  };
}

/**
 * @param c          the complaint, loaded with `complaintInclude`
 * @param opts.peer  true when this is going to someone who merely shares the
 *                   reporter's community, rather than to staff working the
 *                   complaint. Peers get the report; they do not get a phone
 *                   number for the person who filed it.
 */
export function serializeComplaint(c, opts = {}) {
  if (!c) return null;

  const media = c.media ?? [];

  return {
    id: c.id,
    ref: c.ref,
    category: c.category,
    description: c.description,
    status: c.status,
    priority: c.priority,
    isEmergency: c.isEmergency ?? false,
    isHostelComplaint: c.isHostelComplaint ?? false,

    location: {
      lat: c.lat,
      lng: c.lng,
      accuracyM: c.accuracyM,
      capturedAt: c.locationCapturedAt,
      /// Set when the resident corrected a poor GPS fix. The raw reading is
      /// kept so the correction is auditable rather than silent.
      adjusted: c.locationAdjusted ?? false,
      adjustedM: c.locationAdjustedM,
      raw: c.gpsLat != null ? { lat: c.gpsLat, lng: c.gpsLng, accuracyM: c.gpsAccuracyM } : null,
    },
    /// Where a worker should actually walk to. The zone says which part of
    /// campus; this says which building.
    landmark: c.landmarkName ?? c.landmark?.name ?? null,
    landmarkId: c.landmarkId,
    landmarkNote: c.landmarkNote,
    /// Set when this place was signed off only days ago and is dirty again.
    isRecurrence: c.recurrenceOfId != null,
    recurrenceDays: c.recurrenceDays,
    zone: c.zone,
    zoneOverridden: c.zoneOverridden,
    zoneResolvedBy: c.zoneResolvedBy,
    zoneDistanceM: c.zoneDistanceM,
    /// True when the GPS fix did not land cleanly inside one boundary. The
    /// admin screen flags these so a human decides before it reaches an officer.
    isBoundaryCase:
      c.zoneResolvedBy != null &&
      !['POLYGON', 'RESIDENT_OVERRIDE', 'ADMIN_OVERRIDE', 'SUPERVISOR_ASSIGNED'].includes(
        c.zoneResolvedBy,
      ),

    // Who filed it, and which community they filed into. Staff see the role
    // so they can tell a student report from a resident one; peers see it
    // because it is their own community either way.
    reporter: opts.peer
      ? { id: c.reporter?.id, name: c.reporter?.name, role: c.reporterRole }
      : c.reporter
        ? { ...c.reporter, role: c.reporter.role ?? c.reporterRole }
        : null,
    reporterRole: c.reporterRole,
    officer: c.assignedOfficer,
    worker: c.assignedWorker,
    warden: c.assignedWarden,

    isCrossZone: c.isCrossZone,
    lendingZone: c.lendingZone,

    beforeMedia: media.filter((m) => m.phase === 'BEFORE').map(serializeMedia),
    afterMedia: media.filter((m) => m.phase === 'AFTER').map(serializeMedia),

    satisfaction: c.satisfaction,
    /// What the reporter said when they signed the work off.
    feedbackNote: c.feedbackNote,
    unsatisfiedNote: c.unsatisfiedNote,
    reopenCount: c.reopenCount,
    rejectionReason: c.rejectionReason,
    escalationReason: c.escalationReason,

    timestamps: {
      submittedAt: c.submittedAt,
      approvedAt: c.approvedAt,
      allottedOfficerAt: c.allottedOfficerAt,
      officerActedAt: c.officerActedAt,
      allottedWorkerAt: c.allottedWorkerAt,
      startedAt: c.startedAt,
      doneAt: c.doneAt,
      closedAt: c.closedAt,
      escalatedAt: c.escalatedAt,
    },
    slaDueAt: c.slaDueAt,
    isOverdue: c.slaDueAt ? new Date(c.slaDueAt) < new Date() : false,
    workInstructions: c.workInstructions ?? null,

    // Minutes from submit to close - the headline analytics number.
    resolutionMinutes:
      c.closedAt && c.submittedAt
        ? Math.round((new Date(c.closedAt) - new Date(c.submittedAt)) / 60000)
        : null,
  };
}
