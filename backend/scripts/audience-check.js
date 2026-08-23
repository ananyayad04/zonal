/**
 * Residents and students are separate audiences. This checks the separation
 * holds at every door, not just the one the app happens to use.
 *
 *   node scripts/audience-check.js            (against a seeded dev database)
 */

const BASE = process.env.API ?? 'http://localhost:4000';
let passed = 0;
let failed = 0;

const check = (name, ok, detail = '') => {
  ok ? passed++ : failed++;
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  return ok;
};

async function api(path, { method = 'GET', body, token } = {}) {
  const res = await fetch(`${BASE}/api${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = {};
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text.slice(0, 200) };
  }
  return { status: res.status, ok: res.ok, body: json };
}

const login = async (email, password = 'password123') => {
  const r = await api('/auth/login', { method: 'POST', body: { email, password } });
  if (!r.ok) {
    console.error(`\n  Could not log in as ${email}. Run \`npm run db:seed\` first.\n`);
    process.exit(1);
  }
  return r.body.token;
};

console.log('\nResident and student audiences\n');

const admin = await login('admin@campus.edu');
const resident = await login('aditya@campus.edu');
const student = await login('rohit@campus.edu');
// A second resident, so the feed contains something this one did not file.
// Checking privacy against your own complaint proves nothing: you are allowed
// to see your own phone number.
const neighbour = await login('neha@campus.edu');

// --- give both communities something to see --------------------------------
//
// Without this the cross-audience checks below pass against two empty lists,
// which proves nothing at all.

/** A one-pixel PNG. Complaints are refused without evidence attached. */
const PIXEL = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
);

// Zones ship undrawn on purpose - a placeholder boundary looks configured, so
// nobody corrects it. Draw one small square around the campus centre so there
// is somewhere for a complaint to land.
const CENTRE = { lat: 26.7314, lng: 83.4324 };
const d = 0.004;
const square = [
  [CENTRE.lat - d, CENTRE.lng - d],
  [CENTRE.lat - d, CENTRE.lng + d],
  [CENTRE.lat + d, CENTRE.lng + d],
  [CENTRE.lat + d, CENTRE.lng - d],
];

const drawn = await api('/admin/zones/1', {
  method: 'PUT',
  token: admin,
  body: { polygon: square },
});
if (!drawn.ok) {
  console.error(`\n  Could not draw a test zone: ${drawn.body.error ?? drawn.status}\n`);
  process.exit(1);
}

const landmarks = await api('/landmarks', { token: resident });
const landmark = (landmarks.body.landmarks ?? [])[0];
if (!landmark) {
  console.error('\n  No landmarks in the database. Run `npm run db:seed` first.\n');
  process.exit(1);
}

async function file(token, description) {
  const form = new FormData();
  form.set('category', 'GARBAGE');
  form.set('description', description);
  form.set('lat', '26.7314');
  form.set('lng', '83.4324');
  form.set('accuracyM', '8');
  form.set('landmarkId', landmark.id);
  form.append('media', new Blob([PIXEL], { type: 'image/png' }), 'before.png');

  const res = await fetch(`${BASE}/api/complaints`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    console.error(`\n  Could not file a test complaint: ${body.error ?? res.status}\n`);
    process.exit(1);
  }
  return body.complaint;
}

const residentComplaint = await file(resident, 'Bins overflowing near the block');
const neighbourComplaint = await file(neighbour, 'Drain blocked outside C block');
const studentComplaint = await file(student, 'Corridor not swept for days');

check(
  'a complaint records which community filed it',
  residentComplaint.reporterRole === 'RESIDENT' && studentComplaint.reporterRole === 'STUDENT',
  `${residentComplaint.reporterRole} / ${studentComplaint.reporterRole}`,
);

// Approve both, so they reach the feeds.
for (const c of [residentComplaint, neighbourComplaint, studentComplaint]) {
  const r = await api(`/admin/complaints/${c.id}/review`, {
    method: 'POST',
    token: admin,
    body: { approve: true },
  });
  if (!r.ok) {
    console.error(`\n  Could not approve ${c.ref}: ${r.body.error ?? r.status}\n`);
    process.exit(1);
  }
}

// --- both communities can read their own feed ------------------------------
const rFeed = await api('/complaints/community', { token: resident });
const sFeed = await api('/complaints/community', { token: student });

check('a resident can read the community feed', rFeed.ok, `HTTP ${rFeed.status}`);
check('a student can read the community feed', sFeed.ok, `HTTP ${sFeed.status}`);
check('the feed says which audience it is', rFeed.body.audience === 'RESIDENT', rFeed.body.audience);
check('and it differs for a student', sFeed.body.audience === 'STUDENT', sFeed.body.audience);

// --- and never the other's -------------------------------------------------
const rItems = rFeed.body.complaints ?? [];
const sItems = sFeed.body.complaints ?? [];

check(
  'a resident feed contains only resident reports',
  rItems.length > 0 && rItems.every((c) => c.reporterRole === 'RESIDENT'),
  `${rItems.length} item(s)`,
);
check(
  'a student feed contains only student reports',
  sItems.length > 0 && sItems.every((c) => c.reporterRole === 'STUDENT'),
  `${sItems.length} item(s)`,
);
check(
  "a resident never sees the student's complaint",
  !rItems.some((c) => c.id === studentComplaint.id),
);
check(
  "a student never sees the resident's complaint",
  !sItems.some((c) => c.id === residentComplaint.id),
);

const rIds = new Set(rItems.map((c) => c.id));
check(
  'the two feeds share nothing',
  sItems.every((c) => !rIds.has(c.id)),
);

// --- nothing unapproved leaks in -------------------------------------------
const HIDDEN = ['SUBMITTED', 'UNDER_REVIEW', 'REJECTED_INVALID'];
check(
  'unverified complaints never appear',
  [...rItems, ...sItems].every((c) => !HIDDEN.includes(c.status)),
);

// --- a peer gets the report, not a phone number ----------------------------
const theirs = rItems.find((c) => c.id === neighbourComplaint.id);
const own = rItems.find((c) => c.id === residentComplaint.id);

check("someone else's complaint is in the feed", Boolean(theirs));
check(
  "a peer does not receive the reporter's phone number",
  theirs != null && theirs.reporter?.phone === undefined,
  theirs?.reporter?.phone ? 'phone leaked' : 'withheld',
);
check(
  'but the name is shown, so the report is attributable',
  Boolean(theirs?.reporter?.name),
  theirs?.reporter?.name ?? 'missing',
);
check(
  'and you still get your own details on your own complaint',
  own != null && own.reporter?.phone !== undefined,
  own?.reporter?.phone ? 'present' : 'withheld from its own reporter',
);

// --- the detail endpoint enforces the same rule ----------------------------
if (sItems.length) {
  const studentComplaint = sItems[0].id;
  const asResident = await api(`/complaints/${studentComplaint}`, { token: resident });
  check(
    'a resident cannot open a student complaint',
    asResident.status === 403,
    `HTTP ${asResident.status}`,
  );

  const asStudent = await api(`/complaints/${studentComplaint}`, { token: student });
  check('a student can open their own community complaint', asStudent.ok, `HTTP ${asStudent.status}`);
}

if (rItems.length) {
  const residentComplaint = rItems[0].id;
  const asStudent = await api(`/complaints/${residentComplaint}`, { token: student });
  check(
    'a student cannot open a resident complaint',
    asStudent.status === 403,
    `HTTP ${asStudent.status}`,
  );
}

// --- staff read through their own queues, not this one ---------------------
const adminFeed = await api('/complaints/community', { token: admin });
check('staff are refused the community feed', adminFeed.status === 403, `HTTP ${adminFeed.status}`);

// --- staff can tell the two apart ------------------------------------------
const pending = await api('/admin/complaints/pending', { token: admin });
check(
  'the admin queue labels who reported each complaint',
  (pending.body.complaints ?? []).every((c) => typeof c.reporterRole === 'string'),
  `${(pending.body.complaints ?? []).length} in queue`,
);

// --- signing off requires saying something ---------------------------------
//
// Driven all the way through rather than looked for, because the interesting
// behaviour is at the end of the flow: nothing closes until the person who
// filed it says so, and saying so means saying something.

const officer = await login('officer1@campus.edu');
const worker = await login('ramesh.kumar@campus.edu');

// The worker has to be on duty before anything can be allotted to them.
await api('/worker/duty', { method: 'POST', token: worker, body: { onDuty: true } });

const candidates = await api(`/officer/complaints/${residentComplaint.id}/candidates`, {
  token: officer,
});
const freeWorker = candidates.body.suggested ?? (candidates.body.freeWorkers ?? [])[0];
check('the officer is offered a worker to allot', Boolean(freeWorker));

if (freeWorker) {
  const allot = await api(`/officer/complaints/${residentComplaint.id}/allot`, {
    method: 'POST',
    token: officer,
    body: { workerUserId: freeWorker.userId ?? freeWorker.id },
  });
  check('the officer can allot it', allot.ok, allot.body.error ?? `HTTP ${allot.status}`);

  const start = await api(`/worker/tasks/${residentComplaint.id}/start`, {
    method: 'POST',
    token: worker,
  });
  check('the worker can start it', start.ok, start.body.error ?? `HTTP ${start.status}`);

  // Finishing needs after-photos, the same as the app sends.
  const doneForm = new FormData();
  doneForm.append('media', new Blob([PIXEL], { type: 'image/png' }), 'after.png');
  const doneRes = await fetch(`${BASE}/api/worker/tasks/${residentComplaint.id}/done`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${worker}` },
    body: doneForm,
  });
  check('the worker can mark it done', doneRes.ok, `HTTP ${doneRes.status}`);

  // --- the queue holds ----------------------------------------------------
  const awaiting = await api('/complaints/awaiting-confirmation', { token: resident });
  check(
    'finished work waits on the person who reported it',
    (awaiting.body.complaints ?? []).some((c) => c.id === residentComplaint.id),
  );

  const notMine = await api(`/complaints/${residentComplaint.id}/satisfaction`, {
    method: 'POST',
    token: neighbour,
    body: { satisfied: true, note: 'Looks fine to me' },
  });
  check(
    'nobody else can sign it off',
    notMine.status === 403,
    notMine.body.error ?? `HTTP ${notMine.status}`,
  );

  // --- and feedback is not optional ---------------------------------------
  const bare = await api(`/complaints/${residentComplaint.id}/satisfaction`, {
    method: 'POST',
    token: resident,
    body: { satisfied: true },
  });
  check('approving without feedback is refused', bare.status === 400, bare.body.error ?? '');

  const stillOpen = await api(`/complaints/${residentComplaint.id}`, { token: resident });
  check(
    'and the refusal leaves it open, not half-closed',
    stillOpen.body.complaint?.status === 'WORK_DONE',
    stillOpen.body.complaint?.status,
  );

  const FEEDBACK = 'Cleaned properly, looks good now';
  const signed = await api(`/complaints/${residentComplaint.id}/satisfaction`, {
    method: 'POST',
    token: resident,
    body: { satisfied: true, note: FEEDBACK },
  });
  check('approving with feedback closes it', signed.ok, signed.body.error ?? '');
  check(
    'the feedback is kept on the complaint',
    signed.body.complaint?.feedbackNote === FEEDBACK,
    signed.body.complaint?.feedbackNote ?? 'not stored',
  );
  check(
    'and it is recorded as satisfied by a person, not a timeout',
    signed.body.complaint?.satisfaction === 'SATISFIED',
    signed.body.complaint?.satisfaction,
  );
}

// --- nothing closes itself -------------------------------------------------
//
// Read from config rather than by running the job, so this stays an HTTP-level
// test rather than reaching into the server's own database connection.
const { env } = await import('../src/config/env.js');
check(
  'auto-close is off, so only the reporter can close a complaint',
  !env.autoCloseHours || env.autoCloseHours <= 0,
  `AUTO_CLOSE_HOURS=${env.autoCloseHours}`,
);

console.log(`\n${'-'.repeat(56)}`);
console.log(`  ${passed} passed, ${failed} failed`);
console.log(`${'-'.repeat(56)}\n`);
process.exit(failed > 0 ? 1 : 0);
