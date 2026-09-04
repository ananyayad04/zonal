/**
 * Seeds the demo campus.
 *
 * The 8 zones are laid out exactly like the project poster: a 3x3 grid with
 * the central park in the middle cell and the 8 zones ringing it. Everything
 * is generated from a single centre point (CAMPUS_CENTER_LAT/LNG), so when you
 * are ready to run this on the real campus you only need to retrace the
 * polygons - no other code changes.
 *
 *   N
 *   +-----------+-----------+-----------+
 *   |  ZONE 2   |  ZONE 1   |  ZONE 8   |
 *   | Boys Hos. | Acad. (N) | NT Staff2 |
 *   +-----------+-----------+-----------+
 *   |  ZONE 3   |  CENTRAL  |  ZONE 7   |
 *   | Acad. (W) |   PARK    | Acad. (E) |
 *   +-----------+-----------+-----------+
 *   |  ZONE 4   |  ZONE 5   |  ZONE 6   |
 *   |Girls Hos. | Faculty   | NT Staff1 |
 *   +-----------+-----------+-----------+
 */

import { PrismaClient } from '@prisma/client';
import bcrypt from 'bcryptjs';
import { env } from '../src/config/env.js';
import { offsetMeters, haversineMeters } from '../src/utils/geo.js';

const prisma = new PrismaClient();

const DEMO_PASSWORD = 'password123';

// row 0 is the north edge, col 0 the west edge. `null` is the central park.
const GRID = [
  [2, 1, 8],
  [3, null, 7],
  [4, 5, 6],
];

/**
 * Zone colours.
 *
 * These are NOT the poster's pastels. Those failed a colourblind-safety check
 * badly: Zone 3 (green) and Zone 4 (pink) came out at deltaE 0.5 under
 * deuteranopia - indistinguishable to roughly 1 in 12 men - and those two
 * zones share a border on the map.
 *
 * This set passes all six checks (lightness band, chroma floor, CVD adjacent
 * separation, normal-vision floor, contrast). Worst adjacent pair is deltaE
 * 11.4 under protanopia.
 *
 * The assignment order matters. The 8 zones form a RING around the central
 * park - 1, 8, 7, 6, 5, 4, 3, 2 and back to 1 - so colours are handed out in
 * ring order. That makes "next to each other on the map" the same thing as
 * "next to each other in the validated palette", including the wrap-around.
 *
 * Three of these fall below 3:1 contrast on a white surface, so the zone name
 * is always drawn on top of the fill. Never render a zone as colour alone.
 */
const ZONE_META = {
  1: { label: 'Academic Blocks (North)', colorHex: '#0072B2' }, // blue
  8: { label: 'Non-Teaching Staff Residence 2', colorHex: '#E69F00' }, // orange
  7: { label: 'Academic Blocks (East)', colorHex: '#009E73' }, // green
  6: { label: 'Non-Teaching Staff Residence 1', colorHex: '#7A52CC' }, // purple
  5: { label: 'Faculty Residence', colorHex: '#56B4E9' }, // sky
  4: { label: 'Girls Hostel', colorHex: '#D55E00' }, // vermillion
  3: { label: 'Academic Blocks (West)', colorHex: '#CC79A7' }, // pink
  2: { label: 'Boys Hostel 1 & 2', colorHex: '#6E8B00' }, // olive
};

const OFFICERS = {
  1: 'Rakesh Verma',
  2: 'Sunil Yadav',
  3: 'Priya Nair',
  4: 'Anita Sharma',
  5: 'Mohan Das',
  6: 'Kavita Singh',
  7: 'Imran Khan',
  8: 'Deepak Joshi',
};

// Two workers per zone. The `pending` ones are left unverified on purpose so
// the Admin's "verify worker" screen has something real to act on at the demo.
const WORKERS = {
  1: [{ name: 'Ramesh Kumar' }, { name: 'Salim Ansari', pending: true }],
  2: [{ name: 'Vijay Prasad' }, { name: 'Rahul Meena' }],
  3: [{ name: 'Sita Devi' }, { name: 'Manoj Kumar' }],
  4: [{ name: 'Lakshmi Bai' }, { name: 'Geeta Rani', pending: true }],
  5: [{ name: 'Suresh Pal' }, { name: 'Dinesh Rawat' }],
  6: [{ name: 'Pooja Kumari' }, { name: 'Arjun Singh' }],
  7: [{ name: 'Farhan Ali' }, { name: 'Nitin Chauhan' }],
  8: [{ name: 'Babu Lal' }, { name: 'Rekha Devi', pending: true }],
};

/**
 * Named places on campus.
 *
 * GPS resolves a complaint to a zone, but a zone is not an address - a worker
 * sent to "Zone 3" still has to hunt. The landmark is what actually tells them
 * where to go, which is why the app requires one on every complaint.
 *
 * `zone` is the zone each place sits in. It is used to sanity-check the GPS
 * fix against what the resident picked, never to override it.
 */
const LANDMARKS = [
  // Departments and academic buildings
  { name: 'Information Technology Department', category: 'DEPARTMENT', zone: 1 },
  { name: 'CSE Department', category: 'DEPARTMENT', zone: 1 },
  { name: 'Civil Department', category: 'DEPARTMENT', zone: 3 },
  { name: 'Mechanical Department', category: 'DEPARTMENT', zone: 3 },
  { name: 'B.Pharma Department', category: 'DEPARTMENT', zone: 7 },
  { name: 'Management Department', category: 'DEPARTMENT', zone: 7 },
  { name: 'Library', category: 'DEPARTMENT', zone: 1 },
  { name: 'ITRC', category: 'DEPARTMENT', zone: 1 },
  { name: 'DSA', category: 'DEPARTMENT', zone: 7 },

  // Boys hostels
  { name: 'Raman Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Subhash Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Visveswarya Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Tagore Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Ambedkar Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Tilak Bhawan', category: 'BOYS_HOSTEL', zone: 2 },
  { name: 'Ramanujam Bhawan', category: 'BOYS_HOSTEL', zone: 2 },

  // Girls hostels
  { name: 'Saraswati Hostel', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Sarojani Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Kalpana Chawla Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Kasturba Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },
  { name: 'Savitribai Phule Bhawan', category: 'GIRLS_HOSTEL', zone: 4 },

  // Shared facilities
  { name: 'Main Gate', category: 'FACILITY', zone: 1 },
  { name: 'ATM', category: 'FACILITY', zone: 1 },
  { name: 'Fountain', category: 'FACILITY', zone: 1 },
  { name: 'Atal Bhawan', category: 'FACILITY', zone: 7 },

  // Staff and faculty housing
  { name: 'Residency Area', category: 'RESIDENCE', zone: 5 },
];

/// One Worker Supervisor, plus one Warden per demo hostel - both created
/// directly (no self-registration, no approval queue), mirroring how this
/// seed script creates zone officers directly.
const SUPERVISOR = { name: 'Meera Kapoor', email: 'supervisor@campus.edu' };

const WARDENS = [
  { name: 'Ashok Tiwari', email: 'warden.raman@campus.edu', hostelName: 'Raman Bhawan' },
  { name: 'Sunita Bhatt', email: 'warden.saraswati@campus.edu', hostelName: 'Saraswati Hostel' },
];

const RESIDENTS = [
  { name: 'Aditya Srivastava', email: 'aditya@campus.edu' },
  { name: 'Neha Gupta', email: 'neha@campus.edu' },
  { name: 'Karan Mehta', email: 'karan@campus.edu' },
  { name: 'Sneha Patil', email: 'sneha@campus.edu' },
];

/// A second reporting community. Their complaints are visible to each other
/// and to staff, and never to the residents above - which is the whole point
/// of having both in the demo data.
const STUDENTS = [
  { name: 'Rohit Yadav', email: 'rohit@campus.edu' },
  { name: 'Priya Singh', email: 'priya@campus.edu' },
  { name: 'Aman Verma', email: 'aman@campus.edu' },
];

const slug = (name) => name.toLowerCase().replace(/[^a-z]+/g, '.');

/** Build the square polygon and centroid for one grid cell. */
function cellGeometry(row, col) {
  const { campusCenterLat: lat0, campusCenterLng: lng0, campusCellMeters: cell } = env;
  const half = cell / 2;

  // Grid centre is the campus centre; row 0 is north, col 0 is west.
  const northM = (1 - row) * cell;
  const eastM = (col - 1) * cell;

  const [centroidLat, centroidLng] = offsetMeters(lat0, lng0, northM, eastM);

  const polygon = [
    offsetMeters(lat0, lng0, northM + half, eastM - half), // NW
    offsetMeters(lat0, lng0, northM + half, eastM + half), // NE
    offsetMeters(lat0, lng0, northM - half, eastM + half), // SE
    offsetMeters(lat0, lng0, northM - half, eastM - half), // SW
  ];

  return { polygon, centroidLat, centroidLng };
}

async function main() {
  console.log('Seeding Smart Clean Campus...\n');

  // Wipe in dependency order so the seed is safely re-runnable.
  await prisma.auditLog.deleteMany();
  await prisma.notification.deleteMany();
  await prisma.statusLog.deleteMany();
  await prisma.helpRequest.deleteMany();
  await prisma.media.deleteMany();
  await prisma.complaint.deleteMany();
  await prisma.landmark.deleteMany();
  await prisma.workerProfile.deleteMany();
  await prisma.zone.updateMany({ data: { officerId: null } });
  await prisma.user.deleteMany();
  await prisma.zone.deleteMany();

  const passwordHash = await bcrypt.hash(DEMO_PASSWORD, 10);

  // --- 1. Zones ----------------------------------------------------------
  const geometryByCode = {};
  for (let row = 0; row < 3; row++) {
    for (let col = 0; col < 3; col++) {
      const code = GRID[row][col];
      if (code === null) continue; // central park
      geometryByCode[code] = cellGeometry(row, col);
    }
  }

  // Zones are seeded with NO boundary. The admin draws each one on the map,
  // or marks it with a pin and lets the boundaries be computed.
  //
  // Shipping placeholder rectangles was worse than shipping nothing: they look
  // like a configured campus, so nobody replaces them, and every complaint
  // resolves against a shape that has no relationship to the real place.
  const zonesByCode = {};
  for (const code of Object.keys(ZONE_META).map(Number).sort((a, b) => a - b)) {
    zonesByCode[code] = await prisma.zone.create({
      data: {
        code,
        name: `Zone ${code}`,
        label: ZONE_META[code].label,
        colorHex: ZONE_META[code].colorHex,
        polygon: undefined,
        centroidLat: null,
        centroidLng: null,
        // Ordering is recomputed the moment any boundary is saved.
        neighbourCodes: Object.keys(ZONE_META)
          .map(Number)
          .filter((c) => c !== code)
          .sort((a, b) => a - b),
      },
    });
  }
  console.log('  8 zones created (no boundaries — the admin draws them)');

  // --- 2. Admin ----------------------------------------------------------
  const admin = await prisma.user.create({
    data: {
      name: 'Campus Admin',
      email: 'admin@campus.edu',
      phone: '9000000001',
      passwordHash,
      role: 'ADMIN',
    },
  });
  console.log('  admin created');

  // --- 3. Zone Officers (one per zone, admin-created not self-registered) --
  for (const [codeStr, name] of Object.entries(OFFICERS)) {
    const code = Number(codeStr);
    const officer = await prisma.user.create({
      data: {
        name,
        email: `officer${code}@campus.edu`,
        phone: `90000001${String(code).padStart(2, '0')}`,
        passwordHash,
        role: 'OFFICER',
      },
    });
    await prisma.zone.update({
      where: { id: zonesByCode[code].id },
      data: { officerId: officer.id },
    });
  }
  console.log('  8 zone officers created');

  // --- 4. Workers --------------------------------------------------------
  let workerCount = 0;
  let pendingCount = 0;
  for (const [codeStr, list] of Object.entries(WORKERS)) {
    const code = Number(codeStr);
    for (const w of list) {
      const user = await prisma.user.create({
        data: {
          name: w.name,
          email: `${slug(w.name)}@campus.edu`,
          phone: `9100000${String(workerCount).padStart(3, '0')}`,
          passwordHash,
          role: 'WORKER',
        },
      });

      await prisma.workerProfile.create({
        data: {
          userId: user.id,
          zoneId: zonesByCode[code].id,
          approvalStatus: w.pending ? 'PENDING' : 'ACTIVE',
          approvedAt: w.pending ? null : new Date(),
          // Approved workers start their shift on, so the allocation engine
          // has a live roster the moment you open the demo.
          dutyStatus: w.pending ? 'OFF' : 'ON',
          availability: 'AVAILABLE',
        },
      });

      workerCount++;
      if (w.pending) pendingCount++;
    }
  }
  console.log(`  ${workerCount} workers created (${pendingCount} awaiting admin verification)`);

  // --- 5. Landmarks ------------------------------------------------------
  for (const [i, lm] of LANDMARKS.entries()) {
    await prisma.landmark.create({
      data: {
        name: lm.name,
        category: lm.category,
        zoneCode: lm.zone ?? null,
        sortOrder: i,
      },
    });
  }
  console.log(`  ${LANDMARKS.length} landmarks created`);

  // --- 5b. Worker Supervisor + Wardens ------------------------------------
  // Created directly, not self-registered - there is no approval queue for
  // either role.
  await prisma.user.create({
    data: {
      name: SUPERVISOR.name,
      email: SUPERVISOR.email,
      phone: '9400000000',
      passwordHash,
      role: 'WORKER_SUPERVISOR',
    },
  });
  console.log('  1 worker supervisor created');

  for (const [i, w] of WARDENS.entries()) {
    const hostel = await prisma.landmark.findUnique({ where: { name: w.hostelName } });
    const warden = await prisma.user.create({
      data: {
        name: w.name,
        email: w.email,
        phone: `9500000${String(i).padStart(3, '0')}`,
        passwordHash,
        role: 'WARDEN',
      },
    });
    await prisma.landmark.update({ where: { id: hostel.id }, data: { wardenId: warden.id } });
  }
  console.log(`  ${WARDENS.length} wardens created, one per hostel`);

  // --- 6. Residents ------------------------------------------------------
  for (const [i, r] of RESIDENTS.entries()) {
    await prisma.user.create({
      data: {
        name: r.name,
        email: r.email,
        phone: `9200000${String(i).padStart(3, '0')}`,
        passwordHash,
        role: 'RESIDENT',
      },
    });
  }
  console.log(`  ${RESIDENTS.length} residents created`);

  // --- 7. Students -------------------------------------------------------
  for (const [i, st] of STUDENTS.entries()) {
    await prisma.user.create({
      data: {
        name: st.name,
        email: st.email,
        phone: `9300000${String(i).padStart(3, '0')}`,
        passwordHash,
        role: 'STUDENT',
      },
    });
  }
  console.log(`  ${STUDENTS.length} students created`);

  console.log('\nDemo logins (password for every account: ' + DEMO_PASSWORD + ')');
  console.log('  Admin     admin@campus.edu');
  console.log('  Officer   officer1@campus.edu  ... officer8@campus.edu');
  console.log('  Worker    ramesh.kumar@campus.edu   (Zone 1, approved)');
  console.log('  Worker    salim.ansari@campus.edu   (Zone 1, PENDING approval)');
  console.log('  Supervisor ' + SUPERVISOR.email);
  console.log('  Warden    warden.raman@campus.edu     (Raman Bhawan)');
  console.log('  Warden    warden.saraswati@campus.edu (Saraswati Hostel)');
  console.log('  Resident  aditya@campus.edu');
  console.log('  Student   rohit@campus.edu');
  console.log('\nCampus centre: ' + env.campusCenterLat + ', ' + env.campusCenterLng);
  console.log('Seed complete.\n');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
