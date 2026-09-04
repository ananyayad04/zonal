/**
 * Zone officers are fixed faculty appointments, created directly by the
 * Admin - not self-registered. These checks cover that creation path, that
 * the old self-registration door is actually closed, and that a zone can
 * never end up with two officers.
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
console.log('\nZone officer appointment\n');

// --- admin, to create with --------------------------------------------------
const adminLogin = await api('/auth/login', {
  method: 'POST',
  body: { email: 'admin@campus.edu', password: 'password123' },
});
if (!adminLogin.ok) {
  console.error('\n  Could not log in as the seeded admin. Run `npm run db:seed` first.\n');
  process.exit(1);
}
const admin = adminLogin.body.token;

// Find a zone with no officer, so creation is actually possible.
const zonesRes = await api('/zones');
const zones = zonesRes.body.zones ?? [];
const dashboard = await api('/admin/dashboard', { token: admin });
const taken = new Set(
  (dashboard.body.zones ?? []).filter((z) => z.officer).map((z) => z.code),
);
const freeZone = zones.find((z) => !taken.has(z.code));
const takenZone = zones.find((z) => taken.has(z.code));

// The dev seed appoints an officer to every zone, so there is nothing free.
// Vacate one rather than depending on how the database was seeded: this
// should work against a fresh install and a full one alike.
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

// --- self-registration is closed --------------------------------------------
const selfReg = await api('/auth/register', {
  method: 'POST',
  body: {
    name: 'Should Not Work',
    email: `blocked.${stamp}@campus.edu`,
    password: 'password123',
    phone: `9${String(stamp).slice(-9)}`,
    role: 'OFFICER',
    zoneCode: openZone.code,
  },
});
check(
  'officer self-registration is rejected',
  selfReg.status === 400,
  selfReg.body.error ?? `HTTP ${selfReg.status}`,
);

// A non-admin cannot use the creation endpoint either.
const asStudent = await api('/auth/register', {
  method: 'POST',
  body: {
    name: 'Test Student',
    email: `student.${stamp}@campus.edu`,
    password: 'password123',
    role: 'STUDENT',
  },
});
const studentToken = asStudent.body.token;
const studentTriesCreate = await api('/admin/zones/officers', {
  method: 'POST',
  token: studentToken,
  body: {
    name: 'Test Officer',
    email: `sneaky.${stamp}@campus.edu`,
    password: 'password123',
    zoneCode: openZone.code,
  },
});
check(
  'a student cannot create an officer account',
  studentTriesCreate.status === 403,
  `HTTP ${studentTriesCreate.status}`,
);

// --- the admin creates one directly -----------------------------------------
const created = await api('/admin/zones/officers', {
  method: 'POST',
  token: admin,
  body: {
    name: 'Test Officer',
    email: `officer.${stamp}@campus.edu`,
    password: 'password123',
    phone: `9${String(stamp).slice(-9)}`,
    zoneCode: openZone.code,
  },
});
check('the admin can create an officer directly', created.status === 201, created.body.error ?? '');
check(
  'the zone is theirs immediately, not pending',
  /now runs/i.test(created.body.message ?? ''),
  created.body.message,
);

// --- they can act right away, no verification wait --------------------------
const officerLogin = await api('/auth/login', {
  method: 'POST',
  body: { email: `officer.${stamp}@campus.edu`, password: 'password123' },
});
check('the new officer can log in immediately', officerLogin.ok, officerLogin.body.error ?? '');
const officerToken = officerLogin.body.token;

const me = await api('/auth/me', { token: officerToken });
check('their account already holds the zone', me.body.user?.zone?.code === openZone.code);
check('there is no application/approval state on the account', me.body.user?.officer == null);

const canOpenQueue = await api('/officer/complaints', { token: officerToken });
check('they can open their queue with no waiting period', canOpenQueue.ok, `HTTP ${canOpenQueue.status}`);

// --- a zone already run by somebody -----------------------------------------
if (takenZone) {
  const clash = await api('/admin/zones/officers', {
    method: 'POST',
    token: admin,
    body: {
      name: 'Test Officer Two',
      email: `clash.${stamp}@campus.edu`,
      password: 'password123',
      zoneCode: takenZone.code,
    },
  });
  check(
    'creating an officer for a zone that already has one is refused',
    clash.status === 409,
    clash.body.error ?? `HTTP ${clash.status}`,
  );
}

// The zone just appointed is now taken too.
const second = await api('/admin/zones/officers', {
  method: 'POST',
  token: admin,
  body: {
    name: 'Test Officer Three',
    email: `second.${stamp}@campus.edu`,
    password: 'password123',
    zoneCode: openZone.code,
  },
});
check(
  'a second officer for that same zone is now refused',
  second.status === 409,
  second.body.error ?? `HTTP ${second.status}`,
);

// --- workers are unaffected --------------------------------------------------
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
check('workers still self-register normally', asWorker.status === 201, asWorker.body.error ?? '');
check('their registration starts PENDING', asWorker.body.user?.worker?.approvalStatus === 'PENDING');

console.log(`\n${'-'.repeat(56)}`);
console.log(`  ${passed} passed, ${failed} failed`);
console.log(`${'-'.repeat(56)}\n`);
process.exit(failed > 0 ? 1 : 0);
