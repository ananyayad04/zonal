-- Students are a second reporting community alongside residents. Same
-- capability, separate audience: a complaint is shown only to peers of the
-- role that filed it. The STUDENT label itself is added by the migration
-- before this one.

-- Which community a complaint belongs to, snapshotted at submit time rather
-- than joined live. If someone's role is changed later, the complaint must not
-- silently move to a different audience.
ALTER TABLE "Complaint" ADD COLUMN "reporterRole" "Role" NOT NULL DEFAULT 'RESIDENT';

-- Everything filed so far was filed by a resident, which the default already
-- says. Set it from the reporter anyway so the column reflects reality rather
-- than an assumption, and so any complaint filed by staff is labelled as such.
UPDATE "Complaint" c
SET "reporterRole" = u."role"
FROM "User" u
WHERE u."id" = c."reporterId";

-- What the reporter said when signing the work off. Required on approval from
-- here on: a bare tick tells the officer nothing about whether the fix holds.
ALTER TABLE "Complaint" ADD COLUMN "feedbackNote" TEXT;

CREATE INDEX "Complaint_reporterRole_status_submittedAt_idx"
    ON "Complaint"("reporterRole", "status", "submittedAt");

-- --------------------------------------------------------------------------
-- Hostels, by their real names.
--
-- Renamed in place rather than replaced: complaints reference landmarks by id,
-- and each one also keeps a snapshot of the name it was filed under, so
-- history reads correctly either way.
-- --------------------------------------------------------------------------

UPDATE "Landmark" SET "name" = 'Raman Bhawan'       WHERE "name" = 'Raman Hostel';
UPDATE "Landmark" SET "name" = 'Subhash Bhawan'     WHERE "name" = 'Subhash Hostel';
UPDATE "Landmark" SET "name" = 'Visveswarya Bhawan' WHERE "name" IN ('VS Hostel', 'V.S. Hostel');
UPDATE "Landmark" SET "name" = 'Tagore Bhawan'      WHERE "name" = 'Tagore Hostel';
UPDATE "Landmark" SET "name" = 'Ambedkar Bhawan'    WHERE "name" = 'Ambedkar Hostel';

-- Retired, not deleted: complaints already point at it.
UPDATE "Landmark" SET "isActive" = false WHERE "name" = 'New Girls Hostel';
