/**
 * Production seed.
 *
 * Creates ONLY what a real deployment cannot start without: the eight zone
 * records, the campus landmarks, and one admin account. No demo users, no
 * sample complaints, no shared password.
 *
 * Zones are created with NO boundaries - the admin draws them from the app
 * once the real campus is mapped.
 *
 *   ADMIN_EMAIL=... ADMIN_PASSWORD=... node prisma/seed-production.js
 *
 * Safe to re-run: it skips anything that already exists rather than wiping.
 */

import { PrismaClient } from '@prisma/client';
import bcrypt from 'bcryptjs';

const prisma = new PrismaClient();

const ZONES = [
  { code: 1, label: 'Academic Blocks (North)', colorHex: '#0072B2' },
  { code: 2, label: 'Boys Hostel 1 & 2', colorHex: '#6E8B00' },
  { code: 3, label: 'Academic Blocks (West)', colorHex: '#CC79A7' },
  { code: 4, label: 'Girls Hostel', colorHex: '#D55E00' },
  { code: 5, label: 'Faculty Residence', colorHex: '#56B4E9' },
  { code: 6, label: 'Non-Teaching Staff Residence 1', colorHex: '#7A52CC' },
  { code: 7, label: 'Academic Blocks (East)', colorHex: '#009E73' },
  { code: 8, label: 'Non-Teaching Staff Residence 2', colorHex: '#E69F00' },
];

const LANDMARKS = [
  { name: 'Information Technology Department', category: 'DEPARTMENT', zone: 1 },
  { name: 'CSE Department', category: 'DEPARTMENT', zone: 1 },
  { name: 'Civil Department', category: 'DEPARTMENT', zone: 3 },
  { name: 'Mechanical Department', category: 'DEPARTMENT', zone: 3 },
  { name: 'B.Pharma Department', category: 'DEPARTMENT', zone: 7 },
  { name: 'Management Department', category: 'DEPARTMENT', zone: 7 },
  { name: 'Library', category: 'DEPARTMENT', zone: 1 },
  { name: 'ITRC', category: 'DEPARTMENT', zone: 1 },
  { name: 'DSA', category: 'DEPARTMENT', zone: 7 },
  { name: 'Raman Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Subhash Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Visveswarya Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Tagore Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Ambedkar Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Tilak Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Ramanujam Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Saraswati Hostel', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Sarojani Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Kalpana Chawla Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Kasturba Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Savitribai Phule Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Main Gate', category: 'FACILITY', zone: 1 },
  { name: 'ATM', category: 'FACILITY', zone: 1 },
  { name: 'Fountain', category: 'FACILITY', zone: 1 },
  { name: 'Atal Bhawan', category: 'FACILITY', zone: 7 },
  { name: 'Residency Area', category: 'RESIDENCE', zone: 5 },
];

async function main() {
  // Trim and lower-case: a dashboard variable pasted with a trailing space, or
  // typed with a capital, would otherwise create an account nobody can log
  // into - and the failure reads as a wrong password rather than a wrong
  // address.
  const email = process.env.ADMIN_EMAIL?.trim().toLowerCase();
  const password = process.env.ADMIN_PASSWORD?.trim();

  if (!email || !password) {
    console.error(
      '\nSet ADMIN_EMAIL and ADMIN_PASSWORD before running this.\n\n' +
        '  ADMIN_EMAIL=admin@mmmut.ac.in ADMIN_PASSWORD="..." node prisma/seed-production.js\n',
    );
    process.exit(1);
  }

  if (password.length < 12) {
    console.error('\nADMIN_PASSWORD must be at least 12 characters.\n');
    process.exit(1);
  }

  console.log('\nPreparing production data...\n');

  // --- zones -------------------------------------------------------------
  let created = 0;
  for (const z of ZONES) {
    const existing = await prisma.zone.findUnique({ where: { code: z.code } });
    if (existing) continue;

    await prisma.zone.create({
      data: {
        code: z.code,
        name: `Zone ${z.code}`,
        label: z.label,
        colorHex: z.colorHex,
        // Deliberately undrawn. The admin maps the real campus from the app.
        polygon: undefined,
        centroidLat: null,
        centroidLng: null,
        neighbourCodes: ZONES.map((o) => o.code).filter((c) => c !== z.code),
      },
    });
    created++;
  }
  console.log(`  zones      ${created} created, ${ZONES.length - created} already existed`);

  // --- landmarks ---------------------------------------------------------
  let lmCreated = 0;
  for (const [i, l] of LANDMARKS.entries()) {
    const existing = await prisma.landmark.findUnique({ where: { name: l.name } });
    if (existing) continue;

    await prisma.landmark.create({
      data: { name: l.name, category: l.category, zoneCode: l.zone, sortOrder: i },
    });
    lmCreated++;
  }
  console.log(`  landmarks  ${lmCreated} created, ${LANDMARKS.length - lmCreated} already existed`);

  // --- the one admin -----------------------------------------------------
  //
  // Matched case-insensitively so an account stored with capitals is found
  // rather than duplicated.
  const existingAdmin = await prisma.user.findFirst({
    where: { email: { equals: email, mode: 'insensitive' } },
  });

  if (existingAdmin && process.env.SEED_ADMIN_RESET === 'true') {
    // Escape hatch for the case this script itself can create: an admin whose
    // stored hash came from a value that is not what the operator believes
    // they set - a pasted trailing space, a stray capital. Without this the
    // account is unreachable and the only cure is dropping the database.
    await prisma.user.update({
      where: { id: existingAdmin.id },
      data: {
        email,
        passwordHash: await bcrypt.hash(password, 12),
        isActive: true,
      },
    });
    console.log(`  admin      ${email} password RESET`);
  } else if (existingAdmin) {
    console.log(`  admin      ${email} already exists — not modified`);
    console.log('             (set SEED_ADMIN_RESET=true to reset its password)');
  } else {
    await prisma.user.create({
      data: {
        name: 'Campus Admin',
        email,
        passwordHash: await bcrypt.hash(password, 12),
        role: 'ADMIN',
      },
    });
    console.log(`  admin      ${email} created`);
  }

  const demoAccounts = await prisma.user.count({ where: { email: { endsWith: '@campus.edu' } } });
  if (demoAccounts > 0) {
    console.log(
      `\n  WARNING: ${demoAccounts} demo account(s) ending in @campus.edu are in this ` +
        'database.\n  They all share a published password. Delete them before going live.',
    );
  }

  console.log('\nDone. Next steps in the app:');
  console.log('  1. Sign in as the admin');
  console.log('  2. Set up zones — draw the real campus boundaries');
  console.log('  3. Create the zone officers, and assign one to each zone');
  console.log('  4. Workers self-register; verify them as they come in\n');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
