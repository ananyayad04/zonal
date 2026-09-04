import path from 'node:path';
import express from 'express';
import cors from 'cors';
import morgan from 'morgan';
import helmet from 'helmet';
import compression from 'compression';
import rateLimit, { ipKeyGenerator } from 'express-rate-limit';

import { env, assertProductionReady } from './config/env.js';
import { prisma } from './lib/prisma.js';
import { notFound, errorHandler, asyncHandler } from './middleware/error.js';
import { authenticate, requireRole } from './middleware/auth.js';
import { signMediaInResponses } from './middleware/mediaUrls.js';

import { authRouter } from './routes/auth.routes.js';
import { zoneRouter } from './routes/zone.routes.js';
import { landmarkRouter } from './routes/landmark.routes.js';
import { complaintRouter } from './routes/complaint.routes.js';
import { officerRouter } from './routes/officer.routes.js';
import { workerRouter } from './routes/worker.routes.js';
import { adminRouter } from './routes/admin.routes.js';
import { zoneAdminRouter } from './routes/zoneAdmin.routes.js';
import { hostelAdminRouter } from './routes/hostelAdmin.routes.js';
import { hostelRouter } from './routes/hostel.routes.js';
import { analyticsRouter } from './routes/analytics.routes.js';
import { notificationRouter } from './routes/notification.routes.js';

import { startScheduler, runAllChecks } from './jobs/scheduler.js';

assertProductionReady();

const app = express();

// Behind nginx, Express must be told to trust the proxy or every request
// appears to come from 127.0.0.1 - which would put all users in one
// rate-limit bucket and log the wrong IP.
if (env.trustProxy) app.set('trust proxy', env.trustProxy);

app.use(
  helmet({
    // Media is served from this origin and embedded by the app; the default
    // policy blocks that.
    crossOriginResourcePolicy: { policy: 'cross-origin' },
  }),
);
app.use(compression());

app.use(
  cors({
    origin(origin, callback) {
      // Mobile apps and curl send no Origin header - only browsers do, and
      // only browsers are subject to CORS.
      if (!origin) return callback(null, true);
      if (!env.isProduction) return callback(null, true);
      if (env.corsOrigins.includes(origin)) return callback(null, true);
      callback(new Error(`Origin ${origin} is not allowed`));
    },
    credentials: true,
  }),
);

app.use(express.json({ limit: '2mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(morgan(env.isProduction ? 'combined' : 'dev'));

/**
 * Rate limiting, in three tiers.
 *
 * Once a user is signed in the limit follows their account rather than their
 * IP. On a campus, hundreds of people share one NAT address - a purely
 * IP-based limit would let one script exhaust everybody else's budget, and
 * throttle a whole hostel because of one person.
 */
// ipKeyGenerator takes the IP STRING, not the request. Passing the request
// yields a different key every time, so the counter resets on each call and
// nothing is ever limited - which is exactly what the check caught.
const perUserOrIp = (req) => req.user?.id ?? ipKeyGenerator(req.ip);

const makeLimiter = ({ windowMin, max, message }) =>
  rateLimit({
    windowMs: windowMin * 60 * 1000,
    limit: max,
    keyGenerator: perUserOrIp,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    handler: (_req, res) => res.status(429).json({ error: message }),
  });

/** Login and registration: the only endpoints reachable without a token. */
const authLimiter = makeLimiter({
  windowMin: env.rateLimit.authWindowMin,
  max: env.rateLimit.authMax,
  message:
    `Too many sign-in attempts. Wait ${env.rateLimit.authWindowMin} minutes and try again.`,
});

/** Uploads: expensive, permanent, and the obvious spam vector. */
const uploadLimiter = makeLimiter({
  windowMin: env.rateLimit.uploadWindowMin,
  max: env.rateLimit.uploadMax,
  message: 'You have filed a lot of reports in a short time. Try again shortly.',
});

/** Everything else. */
const apiLimiter = makeLimiter({
  windowMin: env.rateLimit.apiWindowMin,
  max: env.rateLimit.apiMax,
  message: 'Too many requests. Slow down.',
});

// Order matters: the general limiter first so every request is counted, then
// the tighter ones on the routes that need them.
// Stored media keys become loadable URLs on the way out. One place, so a new
// endpoint cannot forget to do it.
app.use('/api', signMediaInResponses);

app.use('/api', apiLimiter);
app.use('/api/auth/login', authLimiter);
app.use('/api/auth/register', authLimiter);

// Filing a complaint and uploading proof-of-work both write media to disk.
app.post('/api/complaints', uploadLimiter);
app.use('/api/worker/tasks', uploadLimiter);

/**
 * Uploaded evidence is NOT public.
 *
 * These files are photographs of named people's complaints, tied to a
 * location and a time. Serving them from an unauthenticated static route
 * means anyone who guesses or is sent a filename can read them, forever.
 * Requiring a token costs nothing and closes that.
 */
app.use(
  '/uploads',
  authenticate,
  express.static(path.resolve(process.cwd(), env.uploadDir), {
    // Filenames are random, but do not let a browser cache them publicly.
    setHeaders: (res) => res.setHeader('Cache-Control', 'private, max-age=86400'),
    fallthrough: false,
  }),
);

app.get('/api/health', async (_req, res) => {
  let db = 'down';
  try {
    await prisma.$queryRaw`SELECT 1`;
    db = 'up';
  } catch {
    db = 'down';
  }
  // Report which commit is actually serving. Without this there is no way to
  // tell a deploy that failed from one that silently redeployed an old commit,
  // which is exactly how a fix can appear to have no effect.
  const commit = (
    process.env.RAILWAY_GIT_COMMIT_SHA ??
    process.env.GIT_COMMIT ??
    ''
  ).slice(0, 7);

  res.json({
    status: 'ok',
    db,
    env: env.nodeEnv,
    commit: commit || 'unknown',
    seeded: await isSeeded(),
    time: new Date().toISOString(),
  });
});

/** Cheap check for whether the production seed has ever run. */
async function isSeeded() {
  try {
    return (await prisma.zone.count()) > 0;
  } catch {
    return false;
  }
}

app.use('/api/auth', authRouter);
app.use('/api/zones', zoneRouter);
app.use('/api/landmarks', landmarkRouter);
app.use('/api/complaints', complaintRouter);
app.use('/api/officer', officerRouter);
app.use('/api/worker', workerRouter);
// Mounted before the general admin router so /api/admin/zones/* and
// /api/admin/hostels/* win.
app.use('/api/admin/zones', zoneAdminRouter);
app.use('/api/admin/hostels', hostelAdminRouter);
app.use('/api/admin', adminRouter);
app.use('/api/hostel', hostelRouter);
app.use('/api/analytics', analyticsRouter);
app.use('/api/notifications', notificationRouter);

/**
 * POST /api/admin/jobs/run
 * Fires every SLA rule immediately. Invaluable at the demo: set the SLA env
 * values low, hit this, and watch an escalation happen on cue rather than
 * waiting for a real deadline to pass.
 */
app.post(
  '/api/admin/jobs/run',
  authenticate,
  requireRole('ADMIN'),
  asyncHandler(async (_req, res) => {
    const summary = await runAllChecks();
    res.json({ ran: true, summary });
  }),
);

app.use(notFound);
app.use(errorHandler);

const server = app.listen(env.port, () => {
  console.log(`\nSmart Clean Campus API`);
  console.log(`  http://localhost:${env.port}/api/health`);
  console.log(`  environment: ${env.nodeEnv}\n`);
  startScheduler();
});

const shutdown = async (signal) => {
  console.log(`\n${signal} received, shutting down...`);
  server.close();
  await prisma.$disconnect();
  process.exit(0);
};

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

export { app };
