# Project Guide — Smart Clean Campus (Zonal)

A zone-based campus cleanliness complaint management system. The campus is
split into 8 zones; residents and students report cleanliness issues, zone
officers route them to workers, and admins oversee the whole system.

This file is a map: what each part of the repo does, what the five roles can
do, and how to run/configure the backend. For deploying to Railway, see
`CONNECT_MOBILE_TO_BACKEND.md` (pointing the app at a deployed backend) and
`RAILWAY.md` (deploying the backend itself).

---

## Roles

The system has exactly five roles (`Role` enum in
`backend/prisma/schema.prisma`):

| Role | What they do |
|---|---|
| **RESIDENT** | Files complaints about cleanliness issues on campus. Sees only the resident community feed (other residents' complaints), never students'. |
| **STUDENT** | Same as resident, but a separate community — sees only the student feed. Added as a second reporting community, kept isolated from residents. |
| **WORKER** | Cleans up allotted complaints. Registers and waits for admin approval before receiving work. Belongs to exactly one zone. Toggles on/off duty; locked off-duty while holding an active task. |
| **OFFICER** | Runs one zone (`Zone.officerId`, one officer per zone). Verifies complaints, allots them to workers in their own zone, or asks neighboring zones for help if nobody's free. Can self-register and wait for admin approval, same as workers. |
| **ADMIN** | Oversees everything: verifies workers/officers, draws zone boundaries, can allot any complaint to any worker campus-wide (bypassing the officer), tracks cross-zone worker lending, and views analytics. |

**Emergency reports** (flooding, sewage, broken glass, etc.) skip the normal
admin-verification queue and broadcast immediately to every officer, every
on-duty worker, the admin, and the reporter's own community (residents or
students — not both, scoped to whoever filed it).

---

## Repo layout

```
zonal/
├── backend/            Node.js/Express API + Prisma/Postgres
├── mobile/             Flutter app (Android; all 5 roles in one app)
├── deploy/             Deployment-related scripts/configs
├── scripts/            Repo-level scripts
├── DEPLOYMENT.md        General deployment notes
├── RAILWAY.md           Railway-specific deploy guide
├── CONNECT_MOBILE_TO_BACKEND.md   How to point the app at a deployed backend
├── CHANGELOG.md         Dated log of notable changes
└── TODO.md              Known gaps / deferred work
```

### Backend (`backend/`)

```
backend/
├── prisma/
│   ├── schema.prisma        The entire data model — read this first
│   ├── migrations/          One folder per schema change, in order
│   ├── seed.js               Local dev seed: 8 zones, demo accounts, landmarks
│   └── seed-production.js    Production seed: creates exactly one admin,
│                              driven by SEED_ADMIN_EMAIL/SEED_ADMIN_PASSWORD
├── scripts/
│   ├── startup.js            Production entrypoint (Railway's start command):
│   │                          checks config → checks DB → runs migrations →
│   │                          seeds once if asked → starts the server
│   ├── demo-data.js          Generates ~70 realistic historical complaints
│   │                          (for demoing Analytics/Insights with real data)
│   └── *-check.js / *-test.js  Test scripts (see "Running tests" below)
└── src/
    ├── server.js              Express app entrypoint, middleware wiring
    ├── config/env.js          All environment variables, read in one place
    ├── lib/
    │   ├── prisma.js          Prisma client singleton
    │   └── storage.js         File storage abstraction (local disk or Supabase)
    ├── middleware/
    │   ├── auth.js            JWT authentication + role-gating
    │   ├── error.js           Central error handling, asyncHandler wrapper
    │   ├── upload.js           Multer config for photo/video/audio uploads
    │   └── mediaUrls.js        Rewrites relative media paths to full URLs
    ├── routes/
    │   ├── auth.routes.js          Register/login for every role
    │   ├── complaint.routes.js     Resident/student: file, view, confirm/reopen
    │   ├── zone.routes.js          Public zone list (for the map/picker)
    │   ├── landmark.routes.js      Campus landmarks (where a complaint is filed)
    │   ├── worker.routes.js        Worker: duty toggle, task list, start/complete
    │   ├── officer.routes.js       Officer: verify, allot, ask-help, help-requests
    │   ├── admin.routes.js         Admin: verify people, force-allot, dashboard,
    │   │                            free-workers, multi-zone-workers
    │   ├── zoneAdmin.routes.js     Admin: draw/edit zone boundaries, coverage
    │   ├── analytics.routes.js     Stats: overview, insights, heatmap
    │   └── notification.routes.js  In-app notification inbox
    ├── services/
    │   ├── workflow.js         The complaint state machine — every status
    │   │                        change goes through transition() here
    │   ├── allocation.js       allotWorker(), cross-zone help-request logic,
    │   │                        emergency broadcast
    │   └── insights.js         Hotspot/staffing/recurrence detection (pure
    │                            statistics, no AI/ML)
    ├── jobs/scheduler.js        Cron job: sweeps for SLA breaches every minute
    └── utils/
        ├── geo.js               Point-in-polygon zone resolution, area/centroid
        └── serialize.js          Shapes Prisma records into API JSON responses
```

**Reading order for a newcomer**: `prisma/schema.prisma` (the data model) →
`src/services/workflow.js` (the state machine every complaint moves through)
→ `src/services/allocation.js` (how a worker actually gets assigned) →
whichever `routes/*.js` file matches the role you're interested in.

### Mobile (`mobile/lib/`)

```
mobile/lib/
├── main.dart                  App entrypoint
├── core/
│   ├── api_client.dart        HTTP client, error handling, auth header
│   ├── config.dart             Server address (compile-time default +
│   │                            in-app override, see CONNECT_MOBILE_TO_BACKEND.md)
│   ├── models.dart              Dart data classes mirroring the API's JSON
│   ├── palette.dart             Color system (identity/magnitude/status rules)
│   ├── theme.dart                App-wide Material theme
│   └── session.dart              Logged-in user state, auth persistence
├── features/
│   ├── auth/          login_screen.dart, register_screen.dart
│   ├── resident/       resident_home.dart, new_complaint_screen.dart,
│   │                    community_screen.dart, location_step.dart,
│   │                    satisfaction_sheet.dart
│   ├── worker/          worker_home.dart, complete_task_screen.dart
│   ├── officer/          officer_home.dart, officer_pending_screen.dart,
│   │                     allot_sheet.dart, help_inbox_screen.dart
│   ├── admin/            admin_home.dart (dashboard), zones_screen.dart +
│   │                     zone_editor_screen.dart + zone_setup_screen.dart,
│   │                     verify_people_screen.dart (workers AND officers),
│   │                     verify_complaints_screen.dart, escalations_screen.dart,
│   │                     unallotted_complaints_screen.dart,
│   │                     multi_zone_workers_screen.dart,
│   │                     analytics_screen.dart, insights_screen.dart,
│   │                     campus_map_screen.dart
│   └── shared/           complaint_detail_screen.dart, app_drawer.dart,
│                          notifications_screen.dart
└── shared/                Widgets reused across roles: complaint_card.dart,
                            zone_grid.dart, authed_image.dart, ui.dart
                            (AsyncBody, chips, formatters), pick_any_worker_sheet.dart,
                            allotment_details_sheet.dart
```

Android-specific project files live under `mobile/android/` (Gradle config,
manifest, app icons) — see `mobile/android/app/build.gradle.kts` for the
`applicationId` (`edu.campus.zonal`).

---

## Backend: running locally

```bash
cd backend
npm install
docker compose up -d          # Postgres on localhost:5433 (see ../docker-compose.yml)
cp .env.example .env          # fill in DATABASE_URL etc.
npx prisma migrate dev
npm run db:seed               # 8 zones + demo accounts (see prisma/seed.js output)
npm run dev                   # starts on :4000, auto-restarts on file change
```

Demo accounts after seeding (password `password123` for all):
`admin@campus.edu`, `officer1@campus.edu`…`officer8@campus.edu`,
`ramesh.kumar@campus.edu` (approved worker), `aditya@campus.edu` (resident),
`rohit@campus.edu` (student).

### Useful npm scripts (`backend/package.json`)

| Script | What it does |
|---|---|
| `npm run dev` | Local dev server with hot-restart |
| `npm run db:seed` | Reseed local dev data (wipes and recreates) |
| `npm run demo:data` | Reseed, then generate ~70 realistic historical complaints |
| `npm run demo:reset` | Reseed to a clean, empty-complaints state |
| `npm run db:studio` | Prisma Studio — browse the database visually |
| `npm run test:all` | Full test suite (see below) |
| `npm run start:prod` | `prisma migrate deploy && node src/server.js` (manual prod start) |

### Running tests

`npm run test:all` chains every test script: `test:geo`, `test:draw`,
`test:allotment`, `test:officers`, `test:audiences`, `test:e2e`,
`test:emergency`, then `demo:reset` to leave the database clean. Each can
also be run individually. These hit a **running server** (start it first
with `npm run dev` in another terminal) and reseed the database as they go —
don't run them against data you want to keep.

### Environment variables

See `backend/.env.example` (local) and `backend/.env.production.example`
(production, more complete — rate limits, SLA hours, campus GPS center,
upload limits). The server refuses to start in production if `DATABASE_URL`,
`JWT_SECRET`, `PUBLIC_URL`, or `CORS_ORIGINS` are missing.

Business-rule variables (`SLA_OFFICER_ALLOT_HOURS`, `SLA_WORKER_COMPLETE_HOURS`,
`HELP_REQUEST_EXPIRY_HOURS`, `AUTO_CLOSE_HOURS`, `MAX_REOPEN_COUNT`,
`MAX_TASKS_PER_WORKER`, `MAX_PIN_ADJUST_METERS`) set campus-wide *defaults*.
Since this session's changes, an officer or admin can also set a custom
duration per individual task at the moment of allotment — the env var only
applies when no per-task duration is given.

---

## Complaint lifecycle (high level)

```
SUBMITTED → UNDER_REVIEW → ALLOTTED_TO_OFFICER → ALLOTTED_TO_WORKER
    → IN_PROGRESS → WORK_DONE → CLOSED
```

Branches: `REJECTED_INVALID` (admin rejects at review), `HELP_REQUESTED`
(officer has no free worker, asks nearby zones), `ESCALATED` (any SLA
breach, or nobody could help — goes to the admin), `REOPENED` (resident
rejects the finished work, up to `MAX_REOPEN_COUNT` times), `AUTO_CLOSED`
(only if `AUTO_CLOSE_HOURS` > 0). Emergencies skip straight from filing to
`ALLOTTED_TO_OFFICER`. Full transition table in
`backend/src/services/workflow.js`.

---

## Deploying

- **Backend on Railway**: see `RAILWAY.md` for the full walkthrough, and
  `CHANGELOG.md` for the Postgres compatibility note on the latest schema
  change.
- **Pointing the app at a deployed backend**: see
  `CONNECT_MOBILE_TO_BACKEND.md` — either the in-app server-address setting
  (no rebuild) or `flutter build apk --release --dart-define=API_BASE_URL=...`
  (bakes in a default).
