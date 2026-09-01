# Changelog

## 2026-09-02 — Admin power-tools: zone analytics, direct allotment, work instructions

Backend and mobile changes from a rebuild/extension session. All changes are
additive — no existing API behavior changed for callers that don't send the
new optional fields.

### Backend

- **`workInstructions` field** added to `Complaint` (migration
  `20260901191403_work_instructions`) — free text, any language, set by
  whoever allots the task.
- **Per-allotment duration** — both `POST /officer/complaints/:id/allot` and
  `POST /admin/complaints/:id/force-allot` now accept optional `instructions`
  and `durationHours` in the body. When `durationHours` is given, it
  overrides that task's deadline (`slaDueAt`); when omitted, the existing
  global `SLA_WORKER_COMPLETE_HOURS` default applies exactly as before.
- **Analytics** — `GET /analytics/overview`'s `byZone` breakdown now includes
  `workerCount` and `freeWorkerCount` per zone.
- **`GET /admin/free-workers`** now also reports each zone's
  `openComplaintCount`, so an admin can judge whether a zone actually has
  slack before lending one of its workers elsewhere.
- **`GET /admin/complaints`** accepts a comma-separated `status` filter
  (e.g. `?status=ALLOTTED_TO_OFFICER,HELP_REQUESTED`) to fetch multiple
  statuses in one call.
- **New `GET /admin/multi-zone-workers`** — lists every worker currently
  allotted to a zone other than their own.
- **Emergency broadcasts** now notify only the reporter's own community
  (residents or students), matching the same audience split as ordinary
  complaints — previously an emergency notified both communities regardless
  of who filed it.

### Mobile

- **New "Unallotted complaints" screen** — admin can allot any complaint
  that hasn't reached a worker yet directly to a worker on any zone,
  bypassing the zone officer (reuses the existing `force-allot` endpoint).
- **New "Multi-zone workers" screen** — tracks every worker currently on
  loan to a zone other than their own.
- **Zone filter chips** on the Workers and Officers lists, with live counts.
- **Analytics screen redesign** — every chart section now sits in the same
  card style as the hero stat (previously only some sections were boxed);
  added a "Workers per zone" chart and a "most complaint-prone zone"
  callout; fixed a bug where the exact-numbers zone table could render
  twice; replaced the loose day-range chips with one segmented pill control.
- **New `AllotmentDetailsSheet`** — optional instructions + duration form
  shown after picking a worker, in all three allot flows (officer, and both
  admin override paths). Skippable, so the common case stays as fast as
  before.
- **Live countdown on `ComplaintCard`** — shows the instructions text and a
  ticking "Xd Yh left" / "Overdue by Xh" wherever a deadline is set on an
  active complaint.
- **Worker duty toggle** now visually locks while a task is allotted,
  instead of only erroring after the tap.
- **Zones screen** — dropped the seed's placeholder descriptive names and
  the coverage-percent banner from the zone list; each drawn zone now shows
  its actual lat/lng bounding box instead.

### Compatibility note

The new migration is plain standard PostgreSQL (`ALTER TABLE ... ADD COLUMN
... TEXT`) — no provider-specific features. `scripts/startup.js` already
runs `prisma migrate deploy` on every boot, so a Railway deploy connected to
this repo picks up the migration automatically; no manual database step is
required against Railway's native Postgres.
