/**
 * The personnel trail.
 *
 * Every complaint transition already writes to StatusLog - this is
 * deliberately separate and narrower: who Admin verified, created, or
 * appointed to run a zone or hostel, and when. The more this looks like a
 * formal cell with a head, the more that accountability trail matters, and
 * it should never be reconstructed by guessing from timestamps elsewhere.
 */

import { prisma } from '../lib/prisma.js';

/**
 * @param {object} opts
 * @param {object} opts.actor        user performing the action (req.user)
 * @param {string} opts.action       e.g. "OFFICER_CREATED"
 * @param {string} opts.targetType   e.g. "USER" | "ZONE" | "HOSTEL"
 * @param {string} [opts.targetId]
 * @param {string} opts.targetLabel  human-readable, e.g. a name or "Zone 3"
 * @param {string} [opts.note]
 */
export async function logAudit({ actor, action, targetType, targetId, targetLabel, note }) {
  return prisma.auditLog.create({
    data: {
      actorId: actor?.id ?? null,
      actorName: actor?.name ?? 'System',
      action,
      targetType,
      targetId: targetId ?? null,
      targetLabel,
      note: note ?? null,
    },
  });
}
