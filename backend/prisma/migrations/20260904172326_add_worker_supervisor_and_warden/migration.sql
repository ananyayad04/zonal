-- AlterEnum
ALTER TYPE "ComplaintStatus" ADD VALUE 'ALLOTTED_TO_HOSTEL_STAFF';

-- AlterEnum
-- This migration adds more than one value to an enum.
-- With PostgreSQL versions 11 and earlier, this is not possible
-- in a single migration. This can be worked around by creating
-- multiple migrations, each migration adding only one value to
-- the enum.


ALTER TYPE "Role" ADD VALUE 'WORKER_SUPERVISOR';
ALTER TYPE "Role" ADD VALUE 'WARDEN';

-- AlterTable
ALTER TABLE "Complaint" ADD COLUMN     "assignedWardenId" TEXT,
ADD COLUMN     "isHostelComplaint" BOOLEAN NOT NULL DEFAULT false;

-- AlterTable
ALTER TABLE "Landmark" ADD COLUMN     "wardenId" TEXT;

-- CreateIndex
CREATE INDEX "Complaint_assignedWardenId_status_idx" ON "Complaint"("assignedWardenId", "status");

-- CreateIndex
CREATE UNIQUE INDEX "Landmark_wardenId_key" ON "Landmark"("wardenId");

-- AddForeignKey
ALTER TABLE "Landmark" ADD CONSTRAINT "Landmark_wardenId_fkey" FOREIGN KEY ("wardenId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Complaint" ADD CONSTRAINT "Complaint_assignedWardenId_fkey" FOREIGN KEY ("assignedWardenId") REFERENCES "User"("id") ON DELETE SET NULL ON UPDATE CASCADE;

