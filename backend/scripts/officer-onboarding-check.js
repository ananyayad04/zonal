/**
 * Officers self-register the same way workers do, but approval means something
 * different: it appoints them to a zone only one person can hold. These checks
 * cover the parts that differ, and the ways they can collide.
 *
 *   node scripts/officer-onboarding-check.js
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

const stamp = Date.now();
console.log('\nOfficer onboarding\n');

// --- admin, to review with -------------------------------------------------
const adminLogin = await api('/auth/login', {
  method: 'POST',
  body: { email: 'admin@campus.edu', password: 'password123' },
});
if (!adminLogin.ok) {
  console.error('\n  Could not log in as the seeded admin. Run `npm run db:seed` first.\n');
  process.exit(1);
}
const admin = adminLogin.body.token;

// Find a zone with no officer, so approval is actually possible.
const zonesRes = await api('/zones');
const zones = zonesRes.body.zones ?? [];
const dashboard = await api('/admin/dashboard', { token: admin });
const taken = new Set(
  (dashboard.body.zones ?? []).filter((z) => z.officer).map((z) => z.code),
);
const freeZone = zones.find((z) => !taken.has(z.code));
const takenZone = zones.find((z) => taken.has(z.code));

// The dev seed appoints an officer to every zone, so there is nothing to
// apply for. Vacate one rather than depending on how the database was seeded:
// the test should work against a fresh install and a full one alike.
let openZone = freeZone;
if (!openZone) {
  const victim = zones[zones.length - 1];
  const vacated = await api(`/admin/zones/${victim.code}`, {
    method: 'PUT',
    token: admin,
    body: { officerId: null },
  });
  if (!vacated.ok) {
    console.error(`  Could not free a zone to test with: ${vacated.body.error ?? vacated.status}`);
    process.exit(1);
  }
  openZone = victim;
}

// --- registering -----------------------------------------------------------
const applicant = {
  name: 'Test Officer',
  email: `officer.${stamp}@campus.edu`,
  password: 'password123',
  phone: `9${String(stamp).slice(-9)}`,
  role: 'OFFICER',
  zoneCode: openZone.code,
};

const reg = await api('/auth/register', { method: 'POST', body: applicant });
check('an officer can self-register', reg.status === 201, reg.body.error ?? '');
check(
  'signup says approval is still needed',
  /approve/i.test(reg.body.message ?? ''),
  reg.body.message,
);
check('the application starts PENDING', reg.body.user?.officer?.approvalStatus === 'PENDING');
check(
  'no zone is held before approval',
  reg.body.user?.zone == null,
  reg.body.user?.zone ? 'zone granted too early' : 'correct',
);

const officerToken = reg.body.token;

// --- what a pending officer may do ----------------------------------------
const early = await api('/officer/complaints', { token: officerToken });
check('a pending officer cannot open the officer queue', early.status === 403, `HTTP ${early.status}`);
check(
  'and is told they are awaiting verification',
  /awaiting verification/i.test(early.body.error ?? ''),
  early.body.error,
);

// --- a zone already run by somebody ---------------------------------------
if (takenZone) {
  const clash = await api('/auth/register', {
    method: 'POST',
    body: {
      ...applicant,
      email: `clash.${stamp}@campus.edu`,
      phone: `8${String(stamp).slice(-9)}`,
      zoneCode: takenZone.code,
    },
  });
  check(
    'applying for a zone that already has an officer is refused',
    clash.status === 409,
    clash.body.error ?? `HTTP ${clash.status}`,
  );
}

// --- a worker must still not be able to claim a zone ----------------------
const asWorker = await api('/auth/register', {
  method: 'POST',
  body: {
    name: 'Test Worker',
    email: `worker.${stamp}@campus.edu`,
    password: 'password123',
    phone: `7${String(stamp).slice(-9)}`,
    role: 'WORKER',
    zoneCode: openZone.code,
  },
});
check('workers still register normally', asWorker.status === 201);
check(
  'a worker registration does not create an officer application',
  asWorker.body.user?.officer == null,
);

// --- the admin queue -------------------------------------------------------
const queue = await api('/admin/officers?status=PENDING', { token: admin });
const mine = (queue.body.officers ?? []).find((o) => o.email === applicant.email);
check('the application appears in the admin queue', Boolean(mine));
check('the queue names the zone applied for', mine?.zone?.code === openZone.code);
check('the queue reports whether that zone is free', mine?.zoneIsTaken === false);

const dash = await api('/admin/dashboard', { token: admin });
check(
  'the dashboard counts officers waiting',
  (dash.body.queues?.pendingOfficers ?? 0) >= 1,
  `${dash.body.queues?.pendingOfficers ?? 0} pending`,
);

// --- approval --------------------------------------------------------------
const approve = await api(`/admin/officers/${mine?.userId}/verify`, {
  method: 'POST',
  token: admin,
  body: { approve: true },
});
check('the admin can approve', approve.ok, approve.body.error ?? '');

const after = await api('/auth/me', { token: officerToken });
check('approval grants the zone', after.body.user?.zone?.code === openZone.code);
check('the application reads ACTIVE', after.body.user?.officer?.approvalStatus === 'ACTIVE');

const nowAllowed = await api('/officer/complaints', { token: officerToken });
check('an approved officer can open their queue', nowAllowed.ok, `HTTP ${nowAllowed.status}`);

// --- the zone is now taken -------------------------------------------------
const second = await api('/auth/register', {
  method: 'POST',
  body: {
    ...applicant,
    email: `second.${stamp}@campus.edu`,
    phone: `6${String(stamp).slice(-9)}`,
  },
});
check(
  'a second applicant for that zone is now refused',
  second.status === 409,
  second.body.error ?? `HTTP ${second.status}`,
);

check('approving twice is refused', 
  (await api(`/admin/officers/${mine?.userId}/verify`, {
    method: 'POST', token: admin, body: { approve: true },
  })).status === 409,
);

console.log(`\n${'-'.repeat(56)}`);
console.log(`  ${passed} passed, ${failed} failed`);
console.log(`${'-'.repeat(56)}\n`);
process.exit(failed > 0 ? 1 : 0);
