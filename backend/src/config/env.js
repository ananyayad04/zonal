import dotenv from 'dotenv';

dotenv.config();

const num = (key, fallback) => {
  const raw = process.env[key];
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const isProduction = (process.env.NODE_ENV ?? 'development') === 'production';

const DEV_JWT_SECRET = 'dev-only-insecure-secret';

/**
 * In production a missing secret is not a warning, it is a breach: anyone who
 * has read this source can forge an admin token. Refuse to start instead.
 */
function requiredSecret() {
  const secret = process.env.JWT_SECRET;

  if (!isProduction) return secret ?? DEV_JWT_SECRET;

  if (!secret || secret === DEV_JWT_SECRET || secret.length < 32) {
    console.error(
      '\nFATAL: JWT_SECRET is missing, too short, or still the development default.\n' +
        'Anyone could forge an admin session. Generate one and put it in .env:\n\n' +
        "  node -e \"console.log(require('crypto').randomBytes(48).toString('base64url'))\"\n",
    );
    process.exit(1);
  }
  return secret;
}

/** Comma-separated list, e.g. "https://clean.mmmut.ac.in,https://admin.mmmut.ac.in" */
const list = (key) =>
  (process.env[key] ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

export const env = {
  port: num('PORT', 4000),
  nodeEnv: process.env.NODE_ENV ?? 'development',
  isProduction,

  jwtSecret: requiredSecret(),
  jwtExpiresIn: process.env.JWT_EXPIRES_IN ?? '30d',

  /// Origins allowed to call the API from a browser. Empty in development
  /// means "allow anything", which is convenient locally and unacceptable in
  /// production - so production with an empty list is refused below.
  corsOrigins: list('CORS_ORIGINS'),

  /// Behind nginx, Express sees the proxy's IP unless it is told to trust it.
  /// Rate limiting is per-IP, so without this every user shares one bucket.
  trustProxy: (process.env.TRUST_PROXY ?? (isProduction ? '1' : '')) || false,

  /// Public base URL, used to build absolute media links.
  publicUrl: process.env.PUBLIC_URL ?? '',

  // --- rate limits ---------------------------------------------------------
  // Defaults are deliberately generous in development so testing is not
  // throttled, and tight in production. Every one is tunable, because the
  // right number depends on how many people actually use this.
  rateLimit: {
    /// Login and registration - the only endpoints reachable without a token,
    /// so the only ones an attacker can hammer to guess passwords.
    authMax: num('RATE_LIMIT_AUTH_MAX', isProduction ? 20 : 1000),
    authWindowMin: num('RATE_LIMIT_AUTH_WINDOW_MIN', 15),

    /// Everything else. A person tapping around the app makes a handful of
    /// requests per screen; this leaves room for that and stops a script.
    apiMax: num('RATE_LIMIT_API_MAX', isProduction ? 300 : 10_000),
    apiWindowMin: num('RATE_LIMIT_API_WINDOW_MIN', 1),

    /// Uploads cost far more than a read - disk, bandwidth, and they are
    /// permanent. Filing a complaint should never be fast enough to spam.
    uploadMax: num('RATE_LIMIT_UPLOAD_MAX', isProduction ? 20 : 5000),
    uploadWindowMin: num('RATE_LIMIT_UPLOAD_WINDOW_MIN', 10),
  },

  uploadDir: process.env.UPLOAD_DIR ?? 'uploads',

  /// Where complaint media lives.
  ///
  /// `local` writes to disk - correct for development and for a real server
  /// with a real disk. `supabase` uses object storage, which is what any
  /// container platform needs: their filesystems are wiped on every deploy,
  /// so disk uploads disappear without warning.
  storage: {
    driver: (process.env.STORAGE_DRIVER ?? 'local').toLowerCase(),
    supabaseUrl: process.env.SUPABASE_URL ?? '',
    /// The service key. Server-side only - it bypasses row-level security and
    /// must never reach the app or a browser.
    supabaseSecretKey: process.env.SUPABASE_SECRET_KEY ?? '',
    bucket: process.env.SUPABASE_BUCKET ?? 'complaint-media',
    /// How long a signed media link stays valid. Long enough to open a
    /// complaint and scroll its photos, short enough that a copied link dies.
    signedUrlSeconds: num('SIGNED_URL_SECONDS', 3600),
  },
  maxPhotoMb: num('MAX_PHOTO_MB', 10),
  maxVideoMb: num('MAX_VIDEO_MB', 25),
  maxAudioMb: num('MAX_AUDIO_MB', 5),
  maxVideoSeconds: num('MAX_VIDEO_SECONDS', 30),
  maxAudioSeconds: num('MAX_AUDIO_SECONDS', 60),

  /// How far the resident may nudge the pin off the raw GPS fix. Enough to
  /// correct a bad indoor reading, not enough to relocate the complaint.
  maxPinAdjustMeters: num('MAX_PIN_ADJUST_METERS', 150),

  // --- insights ------------------------------------------------------------
  /// A complaint at the same place and category within this many days of the
  /// last one being signed off counts as a recurrence.
  recurrenceWindowDays: num('RECURRENCE_WINDOW_DAYS', 7),
  /// How far back the insight queries look.
  insightWindowDays: num('INSIGHT_WINDOW_DAYS', 30),
  /// Complaints at one place before it is called a hotspot.
  insightHotspotMinComplaints: num('INSIGHT_HOTSPOT_MIN_COMPLAINTS', 4),
  /// Below this, a staffing recommendation would be noise rather than signal.
  insightMinComplaintsForStaffing: num('INSIGHT_MIN_COMPLAINTS_FOR_STAFFING', 15),

  // Business rules. Hours, because that is how the report describes them.
  slaOfficerAllotHours: num('SLA_OFFICER_ALLOT_HOURS', 0.5),
  slaWorkerCompleteHours: num('SLA_WORKER_COMPLETE_HOURS', 24),
  helpRequestExpiryHours: num('HELP_REQUEST_EXPIRY_HOURS', 0.5),
  /// 0 disables auto-closing entirely, which is the default: a complaint is
  /// closed by the person who filed it or not at all. Set a positive number of
  /// hours only if you deliberately want a backstop.
  autoCloseHours: num('AUTO_CLOSE_HOURS', 0),
  maxReopenCount: num('MAX_REOPEN_COUNT', 1),
  maxTasksPerWorker: num('MAX_TASKS_PER_WORKER', 1),

  // Madan Mohan Malaviya University of Technology, Gorakhpur, Uttar Pradesh.
  // Every seeded zone polygon is generated relative to this point, so the map
  // opens on the real campus rather than a placeholder.
  //
  // These coordinates are close but not surveyed. The admin's "Set up zones"
  // screen is the way to place the zones exactly - drop a pin in each part of
  // campus (or stand there and use GPS) and the boundaries are recomputed.
  campusCenterLat: num('CAMPUS_CENTER_LAT', 26.7314),
  campusCenterLng: num('CAMPUS_CENTER_LNG', 83.4324),
  // MMMUT is a compact campus, so the seeded grid is tighter than the default.
  campusCellMeters: num('CAMPUS_CELL_METERS', 250),
};

export const hoursFromNow = (hours) => new Date(Date.now() + hours * 60 * 60 * 1000);

/**
 * Checks that must pass before this is allowed to serve real users.
 * Called once at boot; refuses to start rather than running insecurely.
 */
export function assertProductionReady() {
  if (!env.isProduction) return;

  const problems = [];

  if (env.corsOrigins.length === 0) {
    problems.push(
      'CORS_ORIGINS is empty. Set it to the exact origins allowed to call this ' +
        'API, e.g. CORS_ORIGINS=https://clean.mmmut.ac.in',
    );
  }
  if (!process.env.DATABASE_URL) {
    problems.push('DATABASE_URL is not set.');
  }
  if (process.env.DATABASE_URL?.includes('zonal_dev_password')) {
    problems.push('DATABASE_URL still uses the development password.');
  }
  if (!env.publicUrl) {
    problems.push('PUBLIC_URL is not set (used to build media links).');
  }

  if (env.storage.driver === 'supabase') {
    if (!env.storage.supabaseUrl) problems.push('SUPABASE_URL is not set.');
    if (!env.storage.supabaseSecretKey) problems.push('SUPABASE_SECRET_KEY is not set.');
  } else {
    // Not fatal - a server with a real disk is a legitimate setup - but on a
    // container platform this is how months of evidence silently disappear.
    console.warn(
      '\nWARNING: STORAGE_DRIVER is "local". Uploaded photos are written to ' +
        'the container filesystem.\nOn Railway, Render, Fly or similar they ' +
        'will be DELETED on the next deploy.\nSet STORAGE_DRIVER=supabase, or ' +
        'attach a persistent volume.\n',
    );
  }

  if (problems.length) {
    console.error('\nFATAL: this build is not safe to run in production.\n');
    for (const p of problems) console.error(`  - ${p}`);
    console.error('');
    process.exit(1);
  }
}
