/**
 * The audit log: what happened, to what, by whom, written only from here.
 *
 * `auditLog/{id}` is append-only and unreachable from any client (rules
 * refuse every write), so it is the record that survives an argument. Routes
 * write it with the acting uid; Firestore triggers write it for the document
 * changes clients make directly (profiles, listings, offers, orders), where
 * the actor is the party the document names.
 *
 * `adminActions` stays as the staff's own, rule-validated log of moderation
 * decisions; the audit log is the platform's, and includes those too.
 */

/** Actions the log knows. Free-form strings would drift; the admin screen
 *  groups by these. */
const ACTIONS = Object.freeze({
  authSignIn: 'auth.sign_in',
  authRejected: 'auth.rejected',
  userCreated: 'user.created',
  userSuspended: 'user.suspended',
  userReinstated: 'user.reinstated',
  userVerified: 'user.identity_verified',
  serviceCreated: 'service.created',
  servicePricingChanged: 'service.pricing_changed',
  serviceStatusChanged: 'service.status_changed',
  offerSent: 'offer.sent',
  offerDecided: 'offer.decided',
  orderCreated: 'order.created',
  orderStatusChanged: 'order.status_changed',
  paymentSettled: 'payment.settled',
  paymentReleased: 'payment.released',
  paymentRefunded: 'payment.refunded',
  paymentDuplicate: 'payment.duplicate',
  paymentChargedBack: 'payment.charged_back',
  walletDormant: 'wallet.dormant',
  payoutRequested: 'payout.requested',
  payoutSettled: 'payout.settled',
  payoutRejected: 'payout.rejected',
  proActivated: 'pro.activated',
  featuredChanged: 'service.featured_changed',
  verificationDecided: 'verification.decided',
  staffChanged: 'staff.changed',
  settingsChanged: 'settings.changed',
  categoryChanged: 'category.changed',
});

/**
 * Appends one entry. Never throws: a failed audit write is logged loudly but
 * must not undo the action it describes (a payout that happened is a payout
 * that happened, recorded or not).
 */
async function writeAudit(deps, { actorId, action, targetType, targetId, details }) {
  const { db, logger = console } = deps;
  try {
    await db.collection('auditLog').add({
      actorId: actorId ?? 'system',
      action,
      targetType: targetType ?? null,
      targetId: targetId ?? null,
      details: sanitize(details),
      createdAt: deps.serverTimestamp ? deps.serverTimestamp() : new Date(),
    });
  } catch (error) {
    logger.error('audit write failed', { action, targetId, message: error.message });
  }
}

/** Keeps entries small and free of anything a client typed at length. */
function sanitize(details) {
  if (!details || typeof details !== 'object') return {};
  const out = {};
  for (const [key, value] of Object.entries(details)) {
    if (value === undefined) continue;
    if (typeof value === 'string') out[key] = value.slice(0, 200);
    else if (typeof value === 'number' || typeof value === 'boolean' || value === null) out[key] = value;
    else if (value instanceof Date) out[key] = value;
    else out[key] = String(value).slice(0, 200);
  }
  return out;
}

/** The fields whose change on a listing is a pricing change. */
const PRICING_FIELDS = ['startingPrice', 'pricingMode', 'requiresContact'];

/**
 * Works out which audit entries a listing write deserves. Pure, so it is
 * testable without a trigger.
 */
function serviceAuditEntries(serviceId, before, after) {
  if (!after) return [];
  const entries = [];
  if (!before) {
    entries.push({
      actorId: after.sellerId,
      action: ACTIONS.serviceCreated,
      targetType: 'service',
      targetId: serviceId,
      details: {
        startingPrice: after.startingPrice,
        pricingMode: after.pricingMode || 'fixed',
        requiresContact: after.requiresContact === true,
        status: after.status,
      },
    });
    return entries;
  }
  const changed = PRICING_FIELDS.filter((f) => (before[f] ?? null) !== (after[f] ?? null));
  if (changed.length) {
    const details = {};
    for (const f of changed) {
      details[`${f}Before`] = before[f] ?? null;
      details[`${f}After`] = after[f] ?? null;
    }
    entries.push({
      actorId: after.sellerId,
      action: ACTIONS.servicePricingChanged,
      targetType: 'service',
      targetId: serviceId,
      details,
    });
  }
  if (before.status !== after.status) {
    entries.push({
      actorId: after.sellerId,
      action: ACTIONS.serviceStatusChanged,
      targetType: 'service',
      targetId: serviceId,
      details: { before: before.status, after: after.status },
    });
  }
  if ((before.featuredUntil ?? null) !== (after.featuredUntil ?? null)) {
    entries.push({
      actorId: after.sellerId,
      action: ACTIONS.featuredChanged,
      targetType: 'service',
      targetId: serviceId,
      details: { featured: after.featuredUntil != null },
    });
  }
  return entries;
}

function userAuditEntries(uid, before, after) {
  if (!after) return [];
  if (!before) {
    return [{
      actorId: uid,
      action: ACTIONS.userCreated,
      targetType: 'user',
      targetId: uid,
      details: {
        email: after.email ?? null,
        studentId: after.studentId ?? null,
        identityVerified: after.identityVerified === true,
      },
    }];
  }
  const entries = [];
  if ((before.suspended === true) !== (after.suspended === true)) {
    entries.push({
      actorId: 'staff',
      action: after.suspended ? ACTIONS.userSuspended : ACTIONS.userReinstated,
      targetType: 'user',
      targetId: uid,
      details: {},
    });
  }
  if ((before.identityVerified === true) !== (after.identityVerified === true)) {
    entries.push({
      actorId: 'staff',
      action: ACTIONS.userVerified,
      targetType: 'user',
      targetId: uid,
      details: { identityVerified: after.identityVerified === true },
    });
  }
  return entries;
}

function offerAuditEntries(offerId, before, after) {
  if (!after) return [];
  if (!before) {
    return [{
      actorId: after.freelancerId,
      action: ACTIONS.offerSent,
      targetType: 'offer',
      targetId: offerId,
      details: {
        serviceId: after.serviceId,
        clientId: after.clientId,
        price: after.price,
        deliveryDays: after.deliveryDays,
        revisionCount: after.revisionCount,
      },
    }];
  }
  if (before.status === after.status) return [];
  const byClient = ['accepted', 'declined', 'ordered'].includes(after.status);
  return [{
    actorId: byClient ? after.clientId : after.freelancerId,
    action: ACTIONS.offerDecided,
    targetType: 'offer',
    targetId: offerId,
    details: { before: before.status, after: after.status, orderId: after.orderId ?? null, price: after.price },
  }];
}

module.exports = {
  ACTIONS,
  writeAudit,
  serviceAuditEntries,
  userAuditEntries,
  offerAuditEntries,
};
