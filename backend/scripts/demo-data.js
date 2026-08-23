/**
 * Generates a month of realistic history so the dashboards and insights have
 * something to say.
 *
 * The patterns are planted deliberately, because an insight engine with no
 * pattern to find proves nothing:
 *
 *   - CSE Department: mostly WASHROOM complaints, same note repeated
 *     -> should be flagged as structural, not a cleaning failure
 *   - Library: a similar count spread across many categories
 *     -> should NOT be flagged; it is just busy
 *   - Zone 5: heavy load, few workers, borrows repeatedly
 *     Zone 6: light load, lends out
 *     -> should produce a "move a worker" recommendation
 *   - A handful of places signed off then re-reported days later
 *     -> should appear as recurrences
 *
 *   npm run demo:data
 */

import { PrismaClient } from '@prisma/client';
import crypto from 'node:crypto';
import { voronoiCells, polygonCentroid, haversineMeters } from '../src/utils/geo.js';

const prisma = new PrismaClient();

const CAMPUS_LAT = 26.7314;
const CAMPUS_LNG = 83.4324;
const STEP = 0.0022;
const RING = [
  [1, 1, 0], [8, 1, 1], [7, 0, 1], [6, -1, 1],
  [5, -1, 0], [4, -1, -1], [3, 0, -1], [2, 1, -1],
];

const DAY = 86_400_000;
const ago = (days, hours = 0) => new Date(Date.now() - days * DAY - hours * 3_600_000);
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const between = (a, b) => a + Math.random() * (b - a);

const ref = () => `SC${crypto.randomInt(10000, 99999)}`;

async function main() {
  console.log('\nGenerating demo history...\n');

  // --- 1. Boundaries, so complaints can resolve to a zone ------------------
  const cells = voronoiCells(
    RING.map(([code, dLat, dLng]) => ({
      code,
      lat: CAMPUS_LAT + dLat * STEP,
      lng: CAMPUS_LNG + dLng * STEP,
    })),
    { marginM: 400 },
  );

  for (const cell of cells) {
    const centroid = polygonCentroid(cell.polygon);
    const anchor = RING.find(([c]) => c === cell.code);
    await prisma.zone.update({
      where: { code: cell.code },
      data: {
        polygon: cell.polygon,
        centroidLat: centroid[0],
        centroidLng: centroid[1],
        anchorLat: CAMPUS_LAT + anchor[1] * STEP,
        anchorLng: CAMPUS_LNG + anchor[2] * STEP,
      },
    });
  }

  // Neighbour ordering, nearest first.
  const zones = await prisma.zone.findMany({ orderBy: { code: 'asc' } });
  for (const self of zones) {
    await prisma.zone.update({
      where: { id: self.id },
      data: {
        neighbourCodes: zones
          .filter((z) => z.code !== self.code)
          .map((z) => ({
            code: z.code,
            d: haversineMeters(self.centroidLat, self.centroidLng, z.centroidLat, z.centroidLng),
          }))
          .sort((a, b) => a.d - b.d)
          .map((z) => z.code),
      },
    });
  }
  console.log('  zones drawn and neighbours computed');

  const byCode = Object.fromEntries(zones.map((z) => [z.code, z]));
  const landmarks = await prisma.landmark.findMany();
  const lm = (name) => landmarks.find((l) => l.name === name);

  const residents = await prisma.user.findMany({ where: { role: 'RESIDENT' } });
  const workerProfiles = await prisma.workerProfile.findMany({
    where: { approvalStatus: 'ACTIVE' },
    include: { user: true },
  });
  const admin = await prisma.user.findFirst({ where: { role: 'ADMIN' } });

  const workersInZone = (code) =>
    workerProfiles.filter((w) => w.zoneId === byCode[code].id);

  /** Create one complaint with a full, believable history. */
  async function make({
    landmarkName,
    note,
    category,
    zoneCode,
    daysBack,
    outcome = 'CLOSED',
    crossZoneFrom = null,
    recurrenceOf = null,
  }) {
    const zone = byCode[zoneCode];
    const landmark = lm(landmarkName);
    const reporter = pick(residents);

    // Scatter the pin a little inside the zone so the heatmap looks organic.
    const lat = zone.centroidLat + between(-0.0006, 0.0006);
    const lng = zone.centroidLng + between(-0.0006, 0.0006);

    const submittedAt = ago(daysBack, between(0, 12));
    const approvedAt = new Date(submittedAt.getTime() + between(5, 90) * 60_000);
    const allottedAt = new Date(approvedAt.getTime() + between(5, 60) * 60_000);
    const startedAt = new Date(allottedAt.getTime() + between(10, 120) * 60_000);
    const doneAt = new Date(startedAt.getTime() + between(20, 180) * 60_000);
    const closedAt = new Date(doneAt.getTime() + between(30, 600) * 60_000);

    const pool = crossZoneFrom ? workersInZone(crossZoneFrom) : workersInZone(zoneCode);
    const worker = pool.length ? pick(pool) : null;

    const open = outcome === 'OPEN';
    const status = open ? 'IN_PROGRESS' : outcome;

    const complaint = await prisma.complaint.create({
      data: {
        ref: ref(),
        category,
        description: note ? `${note}` : null,
        status,
        priority: 'MEDIUM',
        lat,
        lng,
        accuracyM: between(6, 25),
        gpsLat: lat,
        gpsLng: lng,
        gpsAccuracyM: between(6, 25),
        locationCapturedAt: submittedAt,
        zoneId: zone.id,
        zoneResolvedBy: 'POLYGON',
        zoneDistanceM: 0,
        landmarkId: landmark?.id ?? null,
        landmarkName: landmark?.name ?? landmarkName,
        landmarkNote: note ?? null,
        recurrenceOfId: recurrenceOf?.id ?? null,
        recurrenceDays: recurrenceOf?.days ?? null,
        reporterId: reporter.id,
        approvedByAdminId: admin.id,
        assignedOfficerId: zone.officerId,
        assignedWorkerId: worker?.userId ?? null,
        isCrossZone: Boolean(crossZoneFrom),
        lendingZoneId: crossZoneFrom ? byCode[crossZoneFrom].id : null,
        submittedAt,
        approvedAt,
        allottedOfficerAt: approvedAt,
        officerActedAt: allottedAt,
        allottedWorkerAt: allottedAt,
        startedAt,
        doneAt: open ? null : doneAt,
        closedAt: open ? null : closedAt,
        satisfaction: open ? 'PENDING' : outcome === 'CLOSED' ? 'SATISFIED' : 'AUTO',
        media: {
          create: {
            url: '/uploads/demo.png',
            type: 'PHOTO',
            phase: 'BEFORE',
            capturedLat: lat,
            capturedLng: lng,
            capturedAt: submittedAt,
          },
        },
      },
    });

    return { id: complaint.id, closedAt: open ? null : closedAt };
  }

  let n = 0;

  // --- 2. The structural hotspot ------------------------------------------
  // Same building, same problem, same spot described again and again.
  for (let i = 0; i < 11; i++) {
    await make({
      landmarkName: 'CSE Department',
      note: i < 8 ? 'second floor washroom' : 'near the stairs',
      category: i < 9 ? 'WASHROOM' : 'GARBAGE',
      zoneCode: 1,
      daysBack: between(1, 29),
      outcome: i % 7 === 0 ? 'AUTO_CLOSED' : 'CLOSED',
    });
    n++;
  }

  // --- 3. The busy-but-fine place -----------------------------------------
  // Similar volume, spread across many different problems. Must NOT be flagged.
  const libraryCats = ['GARBAGE', 'WASHROOM', 'OVERFLOWING_BIN', 'WATER_LOGGING', 'PEST', 'OTHER'];
  for (let i = 0; i < 8; i++) {
    await make({
      landmarkName: 'Library',
      category: libraryCats[i % libraryCats.length],
      zoneCode: 1,
      daysBack: between(1, 29),
    });
    n++;
  }

  // --- 4. The understaffed zone -------------------------------------------
  // Zone 5 carries a heavy load and repeatedly borrows from elsewhere.
  for (let i = 0; i < 17; i++) {
    await make({
      landmarkName: 'Residency Area',
      category: pick(['GARBAGE', 'OVERFLOWING_BIN', 'DRAINAGE']),
      zoneCode: 5,
      daysBack: between(1, 29),
      // A third of them needed a worker from the quiet zone next door.
      crossZoneFrom: i % 3 === 0 ? 6 : null,
      outcome: i > 14 ? 'OPEN' : 'CLOSED',
    });
    n++;
  }

  // --- 5. Ordinary traffic elsewhere --------------------------------------
  const ordinary = [
    ['Raman Bhawan', 2], ['Ambedkar Bhawan', 2], ['Subhash Bhawan', 2],
    ['Tagore Bhawan', 2], ['Saraswati Hostel', 4], ['Kasturba Bhawan', 4],
    ['Civil Department', 3], ['Mechanical Department', 3],
    ['B.Pharma Department', 7], ['Management Department', 7],
    ['Main Gate', 1], ['ATM', 1], ['Fountain', 1], ['Atal Bhawan', 7],
    ['ITRC', 1], ['DSA', 7],
  ];
  for (const [name, zoneCode] of ordinary) {
    const count = Math.floor(between(1, 4));
    for (let i = 0; i < count; i++) {
      await make({
        landmarkName: name,
        category: pick(['GARBAGE', 'OVERFLOWING_BIN', 'WASHROOM', 'WATER_LOGGING', 'PEST']),
        zoneCode,
        daysBack: between(1, 29),
        outcome: Math.random() < 0.15 ? 'OPEN' : 'CLOSED',
      });
      n++;
    }
  }

  // --- 6. Recurrences -----------------------------------------------------
  // Signed off, then reported again days later at the same place.
  const recurrencePairs = [
    ['Raman Bhawan', 'OVERFLOWING_BIN', 2, 12, 3],
    ['Saraswati Hostel', 'WASHROOM', 4, 16, 4],
    ['Main Gate', 'GARBAGE', 1, 9, 2],
  ];
  for (const [name, category, zoneCode, firstDaysBack, gap] of recurrencePairs) {
    const first = await make({
      landmarkName: name,
      category,
      zoneCode,
      daysBack: firstDaysBack,
      outcome: 'CLOSED',
    });
    n++;

    await make({
      landmarkName: name,
      category,
      zoneCode,
      daysBack: firstDaysBack - gap,
      outcome: 'OPEN',
      recurrenceOf: { id: first.id, days: gap },
    });
    n++;
  }

  console.log(`  ${n} complaints created across 30 days`);
  console.log('\n  Planted patterns:');
  console.log('    CSE Department  — concentrated WASHROOM repeats  (structural)');
  console.log('    Library         — similar volume, mixed problems (just busy)');
  console.log('    Zone 5 / Zone 6 — heavy vs idle                  (staffing)');
  console.log('    3 places        — cleaned then dirty again       (recurrence)');
  console.log('\nDone. Sign in as admin@campus.edu and open Insights.\n');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
