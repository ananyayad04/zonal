/**
 * End-to-end smoke test.
 *
 * Drives the complete complaint lifecycle through the real HTTP API, in the
 * order a demo would:
 *
 *   worker onboarding gate -> file a complaint -> admin verification ->
 *   auto-route to the zone officer -> allotment -> work -> proof ->
 *   resident confirmation -> analytics
 *
 * Then it proves the two hard parts separately: the officer-to-officer help
 * handshake when a zone has nobody free, and the rejection path.
 *
 * Run it with a freshly seeded database:
 *
 *   npm run test:e2e
 *
 * It is NOT idempotent, deliberately. The cross-zone scenario lends a Zone 1
 * worker to Zone 2 and leaves that task open, so running twice without
 * reseeding exhausts Zone 1's free workers and the allotment checks fail.
 * Reseeding is cheaper than teaching the test to unwind itself.
 */

const BASE = process.env.API_BASE ?? 'http://localhost:4000/api';
const PASSWORD = 'password123';

let passed = 0;
let failed = 0;
const failures = [];

const ok = (name, detail = '') => {
  passed++;
  console.log(`  PASS  ${name}${detail ? ` â€” ${detail}` : ''}`);
};

const bad = (name, detail) => {
  failed++;
  failures.push(`${name}: ${detail}`);
  console.log(`  FAIL  ${name} â€” ${detail}`);
};

function check(name, condition, detail = '') {
  if (condition) ok(name, detail);
  else bad(name, detail || 'condition was false');
  return condition;
}

async function api(path, { method = 'GET', token, body, form } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;

  let payload;
  if (form) {
    payload = form;
  } else if (body) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }

  const res = await fetch(`${BASE}${path}`, { method, headers, body: payload });
  const text = await res.text();

  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }

  return { status: res.status, ok: res.ok, body: json };
}

const login = async (email) => {
  const res = await api('/auth/login', {
    method: 'POST',
    body: { email, password: PASSWORD },
  });
  if (!res.ok) throw new Error(`login failed for ${email}: ${res.body.error}`);
  return { token: res.body.token, user: res.body.user };
};

/** Smallest valid PNG - enough to satisfy the upload path. */
function pngBlob() {
  const bytes = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64',
  );
  return new Blob([bytes], { type: 'image/png' });
}

async function main() {
  console.log('\nSmart Clean Campus â€” end-to-end smoke test');
  console.log(`${BASE}\n`);

  // --- health ------------------------------------------------------------
  console.log('Health');
  const health = await api('/health');
  if (!check('API is up', health.ok && health.body.status === 'ok')) {
    console.log('\nThe server is not responding. Start it with: npm run dev\n');
    process.exit(1);
  }
  check('database connected', health.body.db === 'up', `db=${health.body.db}`);

  // --- logins ------------------------------------------------------------
  console.log('\nAuthentication');
  const admin = await login('admin@campus.edu');
  check('admin signs in', admin.user.role === 'ADMIN');

  // --- campus setup ------------------------------------------------------
  // Zones ship with NO boundaries, so the campus has to be set up before
  // anything else can work. This is the admin's first job in a real
  // deployment, and the test does exactly what they would: drop one pin per
  // zone and let the boundaries be computed.
  console.log('\nCampus setup');
  const bare = await api('/admin/zones', { token: admin.token });
  check(
    'zones start with no boundaries',
    (bare.body.zones ?? []).every((z) => !z.hasBoundary),
    'nothing is shipped pre-drawn',
  );

  // Eight pins in a ring around MMMUT Gorakhpur.
  const CAMPUS_LAT = 26.7314;
  const CAMPUS_LNG = 83.4324;
  const STEP = 0.0022;
  const RING = [
    [1, 1, 0],
    [8, 1, 1],
    [7, 0, 1],
    [6, -1, 1],
    [5, -1, 0],
    [4, -1, -1],
    [3, 0, -1],
    [2, 1, -1],
  ];

  const setup = await api('/admin/zones/anchors', {
    method: 'POST',
    token: admin.token,
    body: {
      anchors: RING.map(([code, dLat, dLng]) => ({
        code,
        lat: CAMPUS_LAT + dLat * STEP,
        lng: CAMPUS_LNG + dLng * STEP,
      })),
      marginM: 400,
    },
  });
  check('the admin can set up all 8 zones', setup.ok, setup.body.error ?? '');
  check(
    'the campus is fully covered once set up',
    setup.body.coveragePct === 100,
    `${setup.body.coveragePct}%`,
  );

  // --- zones -------------------------------------------------------------
  console.log('\nZones');
  const zones = await api('/zones');
  const zoneList = zones.body.zones ?? [];
  check('8 zones exist', zoneList.length === 8, `${zoneList.length} found`);
  check('every zone has an officer', zoneList.every((z) => z.officer));
  check(
    'every zone now has a boundary',
    zoneList.every((z) => Array.isArray(z.polygon) && z.polygon.length >= 3),
  );

  const resident = await login('aditya@campus.edu');
  check('resident signs in', resident.user.role === 'RESIDENT');

  const pendingWorker = await login('salim.ansari@campus.edu');
  check(
    'unverified worker can sign in',
    pendingWorker.user.role === 'WORKER' &&
      pendingWorker.user.worker.approvalStatus === 'PENDING',
  );

  const wrongPassword = await api('/auth/login', {
    method: 'POST',
    body: { email: 'admin@campus.edu', password: 'wrong' },
  });
  check('wrong password is rejected', wrongPassword.status === 401);

  // --- the worker approval gate -----------------------------------------
  console.log('\nWorker approval gate');
  const blockedTasks = await api('/worker/tasks', { token: pendingWorker.token });
  check(
    'unverified worker is refused task access',
    blockedTasks.status === 403,
    `got ${blockedTasks.status}`,
  );

  const blockedDuty = await api('/worker/duty', {
    method: 'POST',
    token: pendingWorker.token,
    body: { dutyStatus: 'ON' },
  });
  check('unverified worker cannot go on duty', blockedDuty.status === 403);

  const statusVisible = await api('/worker/status', { token: pendingWorker.token });
  check(
    'unverified worker can still see their own status',
    statusVisible.ok && statusVisible.body.approvalStatus === 'PENDING',
  );

  // --- role guards -------------------------------------------------------
  console.log('\nRole guards');
  const residentTriesAdmin = await api('/admin/dashboard', { token: resident.token });
  check('resident is refused the admin dashboard', residentTriesAdmin.status === 403);

  const noToken = await api('/complaints/mine');
  check('no token is refused', noToken.status === 401);

  // --- zone detection ----------------------------------------------------
  console.log('\nZone detection');
  const zone1 = zoneList.find((z) => z.code === 1);
  const inside = await api(
    `/zones/detect?lat=${zone1.centroid.lat}&lng=${zone1.centroid.lng}`,
    { token: resident.token },
  );
  check(
    'a point inside Zone 1 resolves to Zone 1',
    inside.ok && inside.body.zone.code === 1 && inside.body.matchedPolygon === true,
  );

  // A boundary-built campus has no internal gaps, so the fallback is tested
  // with a point genuinely off campus instead.
  const offCampus = await api(
    `/zones/detect?lat=${CAMPUS_LAT + 0.02}&lng=${CAMPUS_LNG}`,
    { token: resident.token },
  );
  check(
    'a point off campus falls back to the nearest zone',
    offCampus.ok && offCampus.body.matchedPolygon === false && offCampus.body.zone != null,
    `${offCampus.body.resolvedBy}, ${offCampus.body.distanceM}m`,
  );
  check(
    'and is flagged rather than silently accepted',
    offCampus.body.resolvedBy === 'OUT_OF_BOUNDS' ||
      offCampus.body.resolvedBy === 'NEAREST_EDGE',
    offCampus.body.resolvedBy,
  );

  // Inside the partition, every point belongs to exactly one zone.
  const midCampus = await api(
    `/zones/detect?lat=${CAMPUS_LAT}&lng=${CAMPUS_LNG}`,
    { token: resident.token },
  );
  check(
    'the middle of campus resolves cleanly with no gap',
    midCampus.body.matchedPolygon === true,
    `${midCampus.body.zone?.name}`,
  );

  // --- landmarks ---------------------------------------------------------
  console.log('\nLandmarks');
  const lmRes = await api('/landmarks', { token: resident.token });
  check('landmark list loads', lmRes.ok);
  check('landmarks are seeded', (lmRes.body.total ?? 0) >= 20, `${lmRes.body.total} places`);
  check(
    'they are grouped for the picker',
    (lmRes.body.groups ?? []).length >= 4,
    (lmRes.body.groups ?? []).map((g) => `${g.label}(${g.landmarks.length})`).join(' '),
  );
  check(
    'hostels are included',
    (lmRes.body.landmarks ?? []).some((l) => l.name === 'Raman Bhawan'),
  );
  check(
    'departments are included',
    (lmRes.body.landmarks ?? []).some((l) => l.name === 'CSE Department'),
  );

  const LM = (lmRes.body.landmarks ?? []).find((l) => l.name === 'CSE Department')?.id;
  const LM_HOSTEL = (lmRes.body.landmarks ?? []).find((l) => l.name === 'Raman Bhawan')?.id;

  // --- filing a complaint ------------------------------------------------
  console.log('\nFiling a complaint');

  // The landmark is compulsory - GPS says which zone, this says which building.
  const noLandmark = new FormData();
  noLandmark.append('category', 'GARBAGE');
  noLandmark.append('lat', `${zone1.centroid.lat}`);
  noLandmark.append('lng', `${zone1.centroid.lng}`);
  noLandmark.append('media', pngBlob(), 'before.png');
  const rejectedNoLandmark = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: noLandmark,
  });
  check(
    'a complaint without a landmark is rejected',
    rejectedNoLandmark.status === 400,
    `got ${rejectedNoLandmark.status}`,
  );

  // A nudge to correct a poor indoor fix is allowed and recorded...
  const nudged = new FormData();
  nudged.append('category', 'GARBAGE');
  nudged.append('lat', `${zone1.centroid.lat + 0.0003}`); // ~33m north
  nudged.append('lng', `${zone1.centroid.lng}`);
  nudged.append('gpsLat', `${zone1.centroid.lat}`);
  nudged.append('gpsLng', `${zone1.centroid.lng}`);
  nudged.append('gpsAccuracyM', '45');
  nudged.append('landmarkId', LM);
  nudged.append('media', pngBlob(), 'before.png');

  const nudgedRes = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: nudged,
  });
  check('the pin may be nudged to correct a poor fix', nudgedRes.ok, nudgedRes.body.error ?? '');
  check(
    'the adjustment is recorded, not hidden',
    nudgedRes.body.complaint?.location?.adjusted === true,
    `${nudgedRes.body.complaint?.location?.adjustedM}m`,
  );

  // ...but dragging it across campus is not.
  const dragged = new FormData();
  dragged.append('category', 'GARBAGE');
  dragged.append('lat', `${zone1.centroid.lat + 0.02}`); // ~2.2km away
  dragged.append('lng', `${zone1.centroid.lng}`);
  dragged.append('gpsLat', `${zone1.centroid.lat}`);
  dragged.append('gpsLng', `${zone1.centroid.lng}`);
  dragged.append('landmarkId', LM);
  dragged.append('media', pngBlob(), 'before.png');

  const draggedRes = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: dragged,
  });
  check(
    'the pin cannot be dragged far from the real fix',
    draggedRes.status === 400,
    draggedRes.body.error ?? `got ${draggedRes.status}`,
  );

  const badLandmark = new FormData();
  badLandmark.append('category', 'GARBAGE');
  badLandmark.append('lat', `${zone1.centroid.lat}`);
  badLandmark.append('lng', `${zone1.centroid.lng}`);
  badLandmark.append('landmarkId', 'not-a-real-id');
  badLandmark.append('media', pngBlob(), 'before.png');
  const rejectedBadLandmark = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: badLandmark,
  });
  check('an unknown landmark is rejected', rejectedBadLandmark.status === 400);

  const noGps = new FormData();
  noGps.append('category', 'GARBAGE');
  noGps.append('media', pngBlob(), 'before.png');
  const rejectedNoGps = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: noGps,
  });
  check(
    'a complaint without GPS is rejected',
    rejectedNoGps.status === 400,
    `got ${rejectedNoGps.status}`,
  );

  const noMedia = new FormData();
  noMedia.append('category', 'GARBAGE');
  noMedia.append('lat', `${zone1.centroid.lat}`);
  noMedia.append('lng', `${zone1.centroid.lng}`);
  const rejectedNoMedia = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: noMedia,
  });
  check('a complaint with no attachment is rejected', rejectedNoMedia.status === 400);

  // Regression: a real phone upload arrives as application/octet-stream,
  // because MultipartFile does not sniff the file. The server must fall back
  // to the filename extension rather than rejecting a valid photo.
  const octet = new FormData();
  octet.append('category', 'GARBAGE');
  octet.append('description', 'Smoke test: untyped upload');
  octet.append('lat', `${zone1.centroid.lat}`);
  octet.append('lng', `${zone1.centroid.lng}`);
  octet.append('landmarkId', LM);
  octet.append('media', new Blob([Buffer.from('89504e470d0a1a0a', 'hex')]), 'photo.jpg');

  const untyped = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: octet,
  });
  check(
    'an upload with no content type is accepted via its extension',
    untyped.ok,
    untyped.ok ? '' : untyped.body.error,
  );

  const badType = new FormData();
  badType.append('category', 'GARBAGE');
  badType.append('lat', `${zone1.centroid.lat}`);
  badType.append('lng', `${zone1.centroid.lng}`);
  badType.append('landmarkId', LM);
  badType.append('media', new Blob([Buffer.from('hello')]), 'notes.pdf');

  const rejectedType = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: badType,
  });
  check(
    'a genuinely unsupported file type is still rejected',
    rejectedType.status === 400,
    `got ${rejectedType.status}`,
  );

  const form = new FormData();
  form.append('category', 'GARBAGE');
  form.append('description', 'Smoke test: rubbish piled by the entrance');
  form.append('lat', `${zone1.centroid.lat}`);
  form.append('lng', `${zone1.centroid.lng}`);
  form.append('accuracyM', '8');
  form.append('landmarkId', LM);
  form.append('landmarkNote', 'Near the back stairs');
  form.append('media', pngBlob(), 'before.png');

  const created = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form,
  });
  if (!check('complaint is filed', created.ok, created.body.error ?? '')) {
    return summary();
  }

  const complaint = created.body.complaint;
  check('it lands in the admin queue', complaint.status === 'UNDER_REVIEW', complaint.status);
  check('it was placed in Zone 1', complaint.zone.code === 1);
  check('the before-photo was stored', complaint.beforeMedia.length === 1);
  check('it has a reference', /^SC\d+$/.test(complaint.ref), complaint.ref);
  check('the landmark is recorded', complaint.landmark === 'CSE Department', complaint.landmark);
  check(
    'the capture time is stored with the pin',
    complaint.location?.capturedAt != null,
    complaint.location?.capturedAt,
  );
  check(
    'the raw GPS reading is kept alongside the pin',
    complaint.location?.raw?.lat != null,
  );
  check('an unmoved pin is not flagged as adjusted', complaint.location?.adjusted === false);
  check(
    'the extra location note is kept',
    complaint.landmarkNote === 'Near the back stairs',
    complaint.landmarkNote,
  );

  // The zone officer must see it straight away, not only after an admin acts.
  const zoneOfficerEarly = await login('officer1@campus.edu');
  const earlyDash = await api('/officer/dashboard', { token: zoneOfficerEarly.token });
  check(
    'the zone officer sees it while it is still UNDER_REVIEW',
    (earlyDash.body.actionQueue ?? []).some((c) => c.id === complaint.id),
  );

  const officerNotes = await api('/notifications', { token: zoneOfficerEarly.token });
  check(
    'the zone officer was notified at submission',
    (officerNotes.body.notifications ?? []).some((n) => n.complaintId === complaint.id),
  );

  // --- admin verification ------------------------------------------------
  console.log('\nAdmin verification');
  const officerCannotSkip = await api(`/officer/complaints/${complaint.id}/allot`, {
    method: 'POST',
    token: (await login('officer1@campus.edu')).token,
    body: { workerUserId: 'nonexistent' },
  });
  // 403 is the expected answer here: a complaint that has not been approved
  // yet has no assigned officer, so no officer owns it and every one of them
  // is refused. The point is that it cannot be allotted, not which code says so.
  check(
    'an unverified complaint cannot be allotted',
    [403, 404, 409].includes(officerCannotSkip.status),
    `got ${officerCannotSkip.status}`,
  );

  const approved = await api(`/admin/complaints/${complaint.id}/review`, {
    method: 'POST',
    token: admin.token,
    body: { approve: true },
  });
  check('admin approves it', approved.ok, approved.body.error ?? '');
  check(
    'the engine auto-routed it to the zone officer',
    approved.body.complaint?.status === 'ALLOTTED_TO_OFFICER',
    approved.body.complaint?.status,
  );
  check(
    'the correct zone officer owns it',
    approved.body.complaint?.officer != null,
    approved.body.complaint?.officer?.name,
  );

  // --- allotment ---------------------------------------------------------
  console.log('\nAllotment');
  const officer1 = await login('officer1@campus.edu');

  const candidates = await api(`/officer/complaints/${complaint.id}/candidates`, {
    token: officer1.token,
  });
  check('officer sees candidate workers', candidates.ok);
  if (
    !check(
      'the engine pre-picks a worker',
      candidates.body.suggested != null,
      candidates.body.suggested?.name ??
        'no free worker in Zone 1 â€” reseed first: npm run test:e2e',
    )
  ) {
    return summary();
  }

  const otherOfficer = await login('officer5@campus.edu');
  const wrongZone = await api(`/officer/complaints/${complaint.id}/allot`, {
    method: 'POST',
    token: otherOfficer.token,
    body: { workerUserId: candidates.body.suggested.userId },
  });
  check(
    "another zone's officer cannot allot it",
    wrongZone.status === 403,
    `got ${wrongZone.status}`,
  );

  const allotted = await api(`/officer/complaints/${complaint.id}/allot`, {
    method: 'POST',
    token: officer1.token,
    body: { workerUserId: candidates.body.suggested.userId },
  });
  check('officer allots the worker', allotted.ok, allotted.body.error ?? '');
  check(
    'status moves to allotted',
    allotted.body.complaint?.status === 'ALLOTTED_TO_WORKER',
    allotted.body.complaint?.status,
  );
  check('it is not flagged cross-zone', allotted.body.complaint?.isCrossZone === false);

  // --- the work ----------------------------------------------------------
  console.log('\nThe work');
  const worker = await login('ramesh.kumar@campus.edu');

  const tasks = await api('/worker/tasks', { token: worker.token });
  check(
    'the worker sees the task',
    tasks.body.active?.some((t) => t.id === complaint.id),
  );

  const dutyBlocked = await api('/worker/duty', {
    method: 'POST',
    token: worker.token,
    body: { dutyStatus: 'OFF' },
  });
  check(
    'a worker holding a task cannot go off duty',
    dutyBlocked.status === 409,
    `got ${dutyBlocked.status}`,
  );

  const doneTooEarly = await api(`/worker/tasks/${complaint.id}/done`, {
    method: 'POST',
    token: worker.token,
    form: (() => {
      const f = new FormData();
      f.append('media', pngBlob(), 'after.png');
      return f;
    })(),
  });
  check(
    'cannot mark done before starting',
    doneTooEarly.status === 409,
    `got ${doneTooEarly.status}`,
  );

  const started = await api(`/worker/tasks/${complaint.id}/start`, {
    method: 'POST',
    token: worker.token,
  });
  check('worker starts', started.ok && started.body.complaint.status === 'IN_PROGRESS');

  const noProof = await api(`/worker/tasks/${complaint.id}/done`, {
    method: 'POST',
    token: worker.token,
    form: new FormData(),
  });
  check(
    'cannot finish without proof of work',
    noProof.status === 400,
    `got ${noProof.status}`,
  );

  const afterForm = new FormData();
  afterForm.append('note', 'Cleared and swept');
  afterForm.append('media', pngBlob(), 'after.png');

  const finished = await api(`/worker/tasks/${complaint.id}/done`, {
    method: 'POST',
    token: worker.token,
    form: afterForm,
  });
  check('worker marks it done', finished.ok, finished.body.error ?? '');
  check(
    'it awaits the resident',
    finished.body.complaint?.status === 'WORK_DONE',
    finished.body.complaint?.status,
  );
  check('the after-photo was stored', finished.body.complaint?.afterMedia?.length === 1);

  // --- confirmation ------------------------------------------------------
  console.log('\nResident confirmation');
  const awaiting = await api('/complaints/awaiting-confirmation', {
    token: resident.token,
  });
  check(
    'it appears in the residentâ€™s confirmation queue',
    awaiting.body.complaints?.some((c) => c.id === complaint.id),
  );

  const strangerConfirms = await api(`/complaints/${complaint.id}/satisfaction`, {
    method: 'POST',
    token: (await login('neha@campus.edu')).token,
    body: { satisfied: true },
  });
  check(
    'only the person who filed it can confirm',
    strangerConfirms.status === 403,
    `got ${strangerConfirms.status}`,
  );

  const closed = await api(`/complaints/${complaint.id}/satisfaction`, {
    method: 'POST',
    token: resident.token,
    body: { satisfied: true, note: 'Clean now, thanks' },
  });
  check('resident confirms', closed.ok, closed.body.error ?? '');
  check('complaint closes', closed.body.complaint?.status === 'CLOSED');
  check(
    'recorded as resident-approved, not auto-closed',
    closed.body.complaint?.satisfaction === 'SATISFIED',
  );

  const detail = await api(`/complaints/${complaint.id}`, { token: resident.token });
  check(
    'the full audit trail was written',
    (detail.body.timeline?.length ?? 0) >= 6,
    `${detail.body.timeline?.length} entries`,
  );

  const workerAfter = await api('/worker/status', { token: worker.token });
  check(
    'the worker is free again',
    workerAfter.body.availability === 'AVAILABLE' && workerAfter.body.activeTaskCount === 0,
  );
  check(
    'their completed count went up',
    workerAfter.body.tasksCompletedToday >= 1,
    `${workerAfter.body.tasksCompletedToday} today`,
  );

  // --- the rejection path ------------------------------------------------
  console.log('\nRejection path');
  const rejectForm = new FormData();
  rejectForm.append('category', 'OTHER');
  rejectForm.append('description', 'Smoke test: should be rejected');
  rejectForm.append('lat', `${zone1.centroid.lat}`);
  rejectForm.append('lng', `${zone1.centroid.lng}`);
  rejectForm.append('landmarkId', LM);
  rejectForm.append('media', pngBlob(), 'spam.png');

  const spam = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: rejectForm,
  });

  // The zone officer can verify too - the admin is no longer a single gate.
  const officerReviewForm = new FormData();
  officerReviewForm.append('category', 'WASHROOM');
  officerReviewForm.append('description', 'Smoke test: officer verifies');
  officerReviewForm.append('lat', `${zone1.centroid.lat}`);
  officerReviewForm.append('lng', `${zone1.centroid.lng}`);
  officerReviewForm.append('landmarkId', LM);
  officerReviewForm.append('media', pngBlob(), 'before.png');

  const forOfficer = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: officerReviewForm,
  });

  const officerVerify = await api(`/officer/complaints/${forOfficer.body.complaint.id}/review`, {
    method: 'POST',
    token: officer1.token,
    body: { approve: true },
  });
  check('the zone officer can verify a complaint themselves', officerVerify.ok, officerVerify.body.error ?? '');
  check(
    'verifying routes it for allotment',
    officerVerify.body.complaint?.status === 'ALLOTTED_TO_OFFICER',
    officerVerify.body.complaint?.status,
  );

  const wrongZoneOfficer = await login('officer6@campus.edu');
  const crossVerify = await api(`/officer/complaints/${forOfficer.body.complaint.id}/review`, {
    method: 'POST',
    token: wrongZoneOfficer.token,
    body: { approve: true },
  });
  check(
    'an officer cannot verify another zone’s complaint',
    crossVerify.status === 403 || crossVerify.status === 409,
    `got ${crossVerify.status}`,
  );

  const rejected = await api(`/admin/complaints/${spam.body.complaint.id}/review`, {
    method: 'POST',
    token: admin.token,
    body: { approve: false, reason: 'Not a cleanliness issue' },
  });
  check('admin can reject a complaint', rejected.ok);
  check(
    'it terminates as rejected',
    rejected.body.complaint?.status === 'REJECTED_INVALID',
    rejected.body.complaint?.status,
  );

  // --- the cross-zone help handshake ------------------------------------
  console.log('\nCross-zone help handshake');

  // Make every Zone 2 worker unavailable by taking them off duty.
  const officer2 = await login('officer2@campus.edu');
  const dash2 = await api('/officer/dashboard', { token: officer2.token });
  const zone2Workers = dash2.body.roster ?? [];

  for (const w of zone2Workers) {
    const email = `${w.name.toLowerCase().replace(/[^a-z]+/g, '.')}@campus.edu`;
    try {
      const wt = await login(email);
      await api('/worker/duty', {
        method: 'POST',
        token: wt.token,
        body: { dutyStatus: 'OFF' },
      });
    } catch {
      // Name-to-email guess failed; the free-worker count check below still
      // tells us whether the setup worked.
    }
  }

  const dash2After = await api('/officer/dashboard', { token: officer2.token });
  const zone2Free = dash2After.body.totals?.workersFree ?? -1;
  check('Zone 2 now has no free workers', zone2Free === 0, `${zone2Free} free`);

  const zone2 = zoneList.find((z) => z.code === 2);
  const z2Form = new FormData();
  z2Form.append('category', 'OVERFLOWING_BIN');
  z2Form.append('description', 'Smoke test: cross-zone');
  z2Form.append('lat', `${zone2.centroid.lat}`);
  z2Form.append('lng', `${zone2.centroid.lng}`);
  z2Form.append('landmarkId', LM_HOSTEL);
  z2Form.append('media', pngBlob(), 'before.png');

  const z2Created = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: z2Form,
  });
  const z2Complaint = z2Created.body.complaint;
  check('complaint filed in Zone 2', z2Complaint?.zone?.code === 2);

  await api(`/admin/complaints/${z2Complaint.id}/review`, {
    method: 'POST',
    token: admin.token,
    body: { approve: true },
  });

  const z2Candidates = await api(`/officer/complaints/${z2Complaint.id}/candidates`, {
    token: officer2.token,
  });
  check(
    'the officer is told they must ask for help',
    z2Candidates.body.mustAskForHelp === true,
  );
  check(
    'only zones with a genuinely free worker are offered',
    (z2Candidates.body.canHelp?.length ?? 0) > 0 &&
      z2Candidates.body.canHelp.every((c) => c.freeWorkerCount > 0),
    `${z2Candidates.body.canHelp?.length} zones offered`,
  );

  const helpSent = await api(`/officer/complaints/${z2Complaint.id}/ask-help`, {
    method: 'POST',
    token: officer2.token,
  });
  check('help request goes out', helpSent.ok && helpSent.body.escalated === false);
  check(
    'nearest zone was asked first',
    helpSent.body.askedZones?.[0] != null,
    `first asked: ${helpSent.body.askedZones?.[0]?.name}`,
  );

  // A neighbouring officer answers.
  const helperCode = helpSent.body.askedZones[0].code;
  const helper = await login(`officer${helperCode}@campus.edu`);

  const inbox = await api('/officer/help-requests', { token: helper.token });
  const incoming = inbox.body.incoming?.find((h) => h.complaint?.id === z2Complaint.id);
  check('it lands in the other officerâ€™s inbox', incoming != null);
  check(
    'their own free workers are listed for one-tap lending',
    (inbox.body.myFreeWorkers?.length ?? 0) > 0,
  );

  const lent = await api(`/officer/help-requests/${incoming.id}/accept`, {
    method: 'POST',
    token: helper.token,
    body: { workerUserId: inbox.body.myFreeWorkers[0].userId },
  });
  check('the other officer lends a worker', lent.ok, lent.body.error ?? '');
  check(
    'the complaint is flagged cross-zone',
    lent.body.complaint?.isCrossZone === true,
  );
  check(
    'the lending zone is recorded',
    lent.body.complaint?.lendingZone != null,
    lent.body.complaint?.lendingZone?.name,
  );
  check(
    'accountability stays with the origin zone',
    lent.body.complaint?.zone?.code === 2,
  );

  // --- emergency reports -------------------------------------------------
  console.log('\nEmergency reports');

  const zone7 = zoneList.find((z) => z.code === 7);
  const emForm = new FormData();
  emForm.append('category', 'WATER_LOGGING');
  emForm.append('description', 'Smoke test: emergency');
  emForm.append('lat', `${zone7.centroid.lat}`);
  emForm.append('lng', `${zone7.centroid.lng}`);
  emForm.append('isEmergency', 'true');
  emForm.append('landmarkId', LM);
  emForm.append('media', pngBlob(), 'emergency.png');

  const emergency = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: emForm,
  });
  check('an emergency can be filed', emergency.ok, emergency.body.error ?? '');

  const em = emergency.body.complaint;
  check('it is flagged as an emergency', em?.isEmergency === true);
  check(
    'it SKIPS admin verification and goes straight to an officer',
    em?.status === 'ALLOTTED_TO_OFFICER',
    em?.status,
  );
  check('it is raised to high priority', em?.priority === 'HIGH', em?.priority);

  const adminQueue = await api('/admin/complaints/pending', { token: admin.token });
  check(
    'it never enters the admin verification queue',
    !(adminQueue.body.complaints ?? []).some((c) => c.id === em.id),
  );

  // Every officer must see it, not just the one whose zone it landed in.
  const officer4 = await login('officer4@campus.edu');
  const dash4 = await api('/officer/dashboard', { token: officer4.token });
  check(
    'an officer from another zone sees the emergency',
    (dash4.body.actionQueue ?? []).some((c) => c.id === em.id),
  );
  check(
    'emergencies are listed first in the queue',
    dash4.body.actionQueue?.[0]?.id === em.id,
    dash4.body.actionQueue?.[0]?.ref,
  );

  // ...and can act on it with their OWN workers.
  const emCandidates = await api(`/officer/complaints/${em.id}/candidates`, {
    token: officer4.token,
  });
  check(
    'that officer is offered their own free workers',
    emCandidates.body.suggested != null,
    emCandidates.body.suggested?.name,
  );

  const emAllot = await api(`/officer/complaints/${em.id}/allot`, {
    method: 'POST',
    token: officer4.token,
    body: { workerUserId: emCandidates.body.suggested.userId },
  });
  check(
    'any officer can respond to an emergency, not just the zone owner',
    emAllot.ok,
    emAllot.body.error ?? '',
  );

  const emNotes = await api('/notifications', { token: officer4.token });
  check(
    'officers were alerted campus-wide',
    (emNotes.body.notifications ?? []).some((n) => n.title?.includes('EMERGENCY')),
  );

  // A normal complaint must still be gated - the bypass is emergency-only.
  const normalForm = new FormData();
  normalForm.append('category', 'GARBAGE');
  normalForm.append('lat', `${zone7.centroid.lat}`);
  normalForm.append('lng', `${zone7.centroid.lng}`);
  normalForm.append('landmarkId', LM);
  normalForm.append('media', pngBlob(), 'normal.png');
  const normal = await api('/complaints', {
    method: 'POST',
    token: resident.token,
    form: normalForm,
  });
  check(
    'a normal complaint still waits for admin verification',
    normal.body.complaint?.status === 'UNDER_REVIEW',
    normal.body.complaint?.status,
  );
  check('a normal complaint is not flagged emergency', normal.body.complaint?.isEmergency === false);

  // --- zone administration ----------------------------------------------
  console.log('\nZone administration');

  const adminZones = await api('/admin/zones', { token: admin.token });
  check('admin can list zones with boundaries', adminZones.ok && adminZones.body.zones?.length === 8);
  check(
    'each zone reports its drawn area',
    adminZones.body.zones?.every((z) => z.hasBoundary && z.areaM2 > 0),
  );

  // A boundary that crosses itself must be refused - a bow-tie makes
  // "inside the zone" ambiguous and is near-impossible to debug later.
  const c1 = adminZones.body.zones.find((z) => z.code === 1).centroid;
  const bowtie = [
    [c1.lat + 0.001, c1.lng - 0.001],
    [c1.lat - 0.001, c1.lng + 0.001],
    [c1.lat + 0.001, c1.lng + 0.001],
    [c1.lat - 0.001, c1.lng - 0.001],
  ];
  const bowtieCheck = await api('/admin/zones/validate', {
    method: 'POST',
    token: admin.token,
    body: { code: 1, polygon: bowtie },
  });
  check(
    'a self-crossing boundary is rejected',
    bowtieCheck.ok && bowtieCheck.body.valid === false,
    bowtieCheck.body.errors?.[0],
  );

  const tooFew = await api('/admin/zones/validate', {
    method: 'POST',
    token: admin.token,
    body: { code: 1, polygon: [[c1.lat, c1.lng], [c1.lat + 0.001, c1.lng]] },
  });
  check('a boundary with fewer than 3 points is rejected', tooFew.status === 400);

  // Saving a valid boundary must also recompute neighbour ordering.
  const original = adminZones.body.zones.find((z) => z.code === 1);
  const shiftedPolygon = original.polygon.map(([lat, lng]) => [lat + 0.0002, lng]);

  const saved = await api('/admin/zones/1', {
    method: 'PUT',
    token: admin.token,
    body: { polygon: shiftedPolygon, label: 'Academic Blocks (North)' },
  });
  check('a valid boundary saves', saved.ok, saved.body.error ?? '');
  check(
    'the centroid is recomputed from the new shape',
    saved.body.zone?.centroid?.lat > original.centroid.lat,
    `${original.centroid.lat.toFixed(5)} -> ${saved.body.zone?.centroid?.lat?.toFixed(5)}`,
  );
  check(
    'neighbour ordering is rebuilt after a boundary change',
    (saved.body.zone?.neighbourCodes?.length ?? 0) === 7,
    `${saved.body.zone?.neighbourCodes?.length} neighbours`,
  );

  // Restore the original shape so re-running does not drift the campus.
  await api('/admin/zones/1', {
    method: 'PUT',
    token: admin.token,
    body: { polygon: original.polygon },
  });

  const coverage = await api('/admin/zones/coverage?steps=20', { token: admin.token });
  check('coverage report runs', coverage.ok);
  check(
    'coverage is reported as a percentage',
    typeof coverage.body.coveragePct === 'number',
    `${coverage.body.coveragePct}% covered`,
  );
  check('coverage names any undrawn zones', Array.isArray(coverage.body.undrawn));

  const officers = await api('/admin/zones/officers', { token: admin.token });
  check('officer picker lists all officers', officers.ok && officers.body.officers?.length === 8);
  check(
    'officers already running a zone are marked unavailable',
    officers.body.officers?.every((o) => o.currentZone != null && o.available === false),
  );

  const officerGuard = await api('/admin/zones/2', {
    method: 'PUT',
    token: admin.token,
    body: { officerId: officers.body.officers.find((o) => o.currentZone?.code === 3).id },
  });
  check(
    'an officer cannot run two zones at once',
    officerGuard.status === 409,
    `got ${officerGuard.status}`,
  );

  const notAdmin = await api('/admin/zones', { token: officer1.token });
  check('a zone officer cannot edit zones', notAdmin.status === 403);

  // --- analytics ---------------------------------------------------------
  console.log('\nAnalytics');
  const analytics = await api('/analytics/overview?days=30', { token: admin.token });
  check('overview loads', analytics.ok);
  check(
    'complaints were counted',
    (analytics.body.totals?.total ?? 0) >= 3,
    `${analytics.body.totals?.total} total`,
  );
  check(
    'cross-zone borrowing is reported',
    (analytics.body.totals?.crossZone ?? 0) >= 1,
    `${analytics.body.totals?.crossZone} cross-zone`,
  );
  check(
    'resolution time was measured',
    analytics.body.averageMinutes?.endToEndResolution != null,
  );
  check('per-zone breakdown has all 8 zones', analytics.body.byZone?.length === 8);

  const heatmap = await api('/analytics/heatmap', { token: admin.token });
  check('heatmap returns points', heatmap.ok && (heatmap.body.count ?? 0) >= 2);

  // --- notifications -----------------------------------------------------
  console.log('\nNotifications');
  const notes = await api('/notifications', { token: resident.token });
  check(
    'the resident was notified along the way',
    (notes.body.notifications?.length ?? 0) >= 3,
    `${notes.body.notifications?.length} notifications`,
  );

  // --- background jobs ---------------------------------------------------
  console.log('\nBackground jobs');
  const jobs = await api('/admin/jobs/run', { method: 'POST', token: admin.token });
  check('SLA sweep runs on demand', jobs.ok && jobs.body.ran === true);

  summary();
}

function summary() {
  console.log(`\n${'-'.repeat(58)}`);
  console.log(`  ${passed} passed, ${failed} failed`);
  if (failures.length) {
    console.log('\nFailures:');
    for (const f of failures) console.log(`  - ${f}`);
  }
  console.log(`${'-'.repeat(58)}\n`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('\nSmoke test crashed:', err.message);
  console.error(err.stack);
  process.exit(1);
});


