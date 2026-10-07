/**
 * Money held by the platform: release, refund, payout, and the Pro features
 * that are paid for with it.
 *
 * Every function here runs with the Admin SDK, which bypasses security rules
 * — which is precisely why the rules can forbid every client from touching
 * `wallets`, `ledger`, `payouts`, `featuredUntil`, `proUntil`, and
 * `identityVerified`. The client asks; this module decides.
 *
 * Money state changes are append-only: a wallet balance moves only alongside a
 * `ledger` entry that says why, in the same transaction. Nothing is ever
 * updated in place to a different amount.
 *
 * Written as plain functions over an injected `db` so the suite in
 * ledger.test.js can run them against an in-memory Firestore.
 */

const {
  DOC_ID,
  FEATURED_PER_SELLER,
  MINIMUM_PAYOUT,
  AUTO_COMPLETE_DAYS,
  REMINDER_HOURS_BEFORE,
  NEW_SELLER_CLEARANCE_DAYS,
  NEW_SELLER_CLEARED_RELEASES,
  DORMANT_WALLET_DAYS,
  isAdult,
  validAccountNumber,
  BANK_CHANNELS,
  GATEWAY_METHOD,
} = require('./policy');

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/** Errors carry a `code` the HTTP layer maps to a status. */
class LedgerError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const stamp = (deps) => (deps.serverTimestamp ? deps.serverTimestamp() : new Date());
const increment = (deps, n) => (deps.increment ? deps.increment(n) : n);

// --- hold and release ------------------------------------------------------

/**
 * Credits the freelancer once the client accepted the work.
 *
 * Only a gateway payment that is still `held` moves; manual settlements were
 * never in the platform's hands, and a second run (Firestore may deliver a
 * trigger more than once) finds `released` and does nothing.
 *
 * A seller's first few releases land in `clearing` rather than `available`
 * and move over after NEW_SELLER_CLEARANCE_DAYS (see clearSettledFunds). A
 * card chargeback filed after a payout is the platform's loss; the delay
 * gives the earliest, least-known sellers' disputes somewhere to land.
 */
async function releaseHeldPayment(deps, orderId) {
  const { db } = deps;
  const paymentRef = db.doc(`payments/${orderId}`);
  const now = deps.now ? deps.now() : new Date();
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(paymentRef);
    if (!snap.exists) return 'no-payment';
    const payment = snap.data() || {};
    if (payment.method !== GATEWAY_METHOD) return 'not-held';
    if (payment.status !== 'paid' || payment.holdStatus !== 'held') {
      return 'not-held';
    }
    const net = payment.netToFreelancer;
    if (!Number.isInteger(net) || net < 0) return 'invalid-record';

    const walletRef = db.doc(`wallets/${payment.freelancerId}`);
    const walletSnap = await tx.get(walletRef);
    const wallet = walletSnap.exists ? walletSnap.data() : {};
    const releases = Number.isInteger(wallet.releaseCount) ? wallet.releaseCount : 0;
    const clears = releases < NEW_SELLER_CLEARED_RELEASES;
    const clearsAt = clears
      ? new Date(now.getTime() + NEW_SELLER_CLEARANCE_DAYS * DAY)
      : null;
    const when = stamp(deps);

    // A chargeback the balance could not cover is repaid from the next
    // releases before anything is credited (see recordChargeback).
    const owed = Number.isInteger(wallet.owed) && wallet.owed > 0 ? wallet.owed : 0;
    const recovered = Math.min(owed, net);
    const credited = net - recovered;

    tx.update(paymentRef, {
      holdStatus: 'released',
      releasedAt: when,
      updatedAt: when,
    });
    tx.set(
      walletRef,
      {
        uid: payment.freelancerId,
        available: increment(deps, clears ? 0 : credited),
        clearing: increment(deps, clears ? credited : 0),
        owed: increment(deps, -recovered),
        pendingPayout: walletSnap.exists ? increment(deps, 0) : 0,
        totalReleased: increment(deps, net),
        totalPaidOut: walletSnap.exists ? increment(deps, 0) : 0,
        releaseCount: increment(deps, 1),
        updatedAt: when,
      },
      { merge: true },
    );
    if (recovered > 0) {
      tx.set(db.collection('ledger').doc(), {
        uid: payment.freelancerId,
        type: 'chargeback_recovery',
        amount: -recovered,
        orderId,
        createdAt: when,
      });
    }
    if (credited > 0) {
      tx.set(db.collection('ledger').doc(), {
        uid: payment.freelancerId,
        type: 'release',
        amount: credited,
        orderId,
        cleared: !clears,
        clearsAt,
        createdAt: when,
      });
    }
    return clears ? 'released-clearing' : 'released';
  });
}

/**
 * The seller's share of a payment the card network took back after it was
 * released. The gateway debits the platform; this passes the seller's part
 * on. Whatever the balance cannot cover becomes `owed` and is repaid from
 * the seller's next releases (releaseHeldPayment). The platform absorbs
 * its own commission. A payment still `held` is refunded, not charged back.
 */
async function recordChargeback(deps, { orderId, adminUid, reason }) {
  const { db } = deps;
  if (!DOC_ID.test(orderId)) throw new LedgerError('bad-request', 'valid orderId required');
  const paymentRef = db.doc(`payments/${orderId}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(paymentRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such payment.');
    const payment = snap.data() || {};
    if (payment.method !== GATEWAY_METHOD || payment.status !== 'paid') {
      throw new LedgerError('not-gateway', 'Only a settled gateway payment can be charged back.');
    }
    if (payment.chargebackStatus) {
      throw new LedgerError('already', 'This chargeback was already recorded.');
    }
    if (payment.holdStatus !== 'released') {
      throw new LedgerError(
        'not-released',
        'The money is still held or was refunded; use a refund instead.',
      );
    }
    const net = payment.netToFreelancer;
    if (!Number.isInteger(net) || net < 0) throw new LedgerError('invalid-record', 'Bad payment record.');

    const walletRef = db.doc(`wallets/${payment.freelancerId}`);
    const walletSnap = await tx.get(walletRef);
    const wallet = walletSnap.exists ? walletSnap.data() : {};
    const available = Number.isInteger(wallet.available) ? wallet.available : 0;
    const clearing = Number.isInteger(wallet.clearing) ? wallet.clearing : 0;
    const fromAvailable = Math.min(available, net);
    const fromClearing = Math.min(clearing, net - fromAvailable);
    const owed = net - fromAvailable - fromClearing;
    const when = stamp(deps);

    tx.update(paymentRef, {
      chargebackStatus: 'recorded',
      chargedBackAt: when,
      updatedAt: when,
    });
    tx.set(
      walletRef,
      {
        uid: payment.freelancerId,
        available: increment(deps, -fromAvailable),
        clearing: increment(deps, -fromClearing),
        owed: increment(deps, owed),
        updatedAt: when,
      },
      { merge: true },
    );
    tx.set(db.collection('ledger').doc(), {
      uid: payment.freelancerId,
      type: 'chargeback',
      amount: -net,
      orderId,
      note: reason,
      recordedBy: adminUid,
      createdAt: when,
    });
    tx.set(db.collection('adminActions').doc(), {
      actorId: adminUid,
      action: 'payment.chargeback',
      targetType: 'payment',
      targetId: orderId,
      note: reason,
      createdAt: when,
    });
    return { freelancerId: payment.freelancerId, net, recovered: fromAvailable + fromClearing, owed };
  });
}

/**
 * A balance whose owner has not signed in for DORMANT_WALLET_DAYS is flagged
 * once, so staff can reach them through the payout account on file before a
 * graduated student's university account disappears with money still in it.
 * The flag clears when they come back; a payout request clears it too.
 */
async function flagDormantWallets(deps, now) {
  const { db, lastSignInOf, notify, notifyStaff } = deps;
  const cutoff = new Date(now.getTime() - DORMANT_WALLET_DAYS * DAY);
  const wallets = await db.collection('wallets').where('available', '>', 0).limit(200).get();
  let flagged = 0;
  let cleared = 0;
  for (const doc of wallets.docs) {
    const wallet = doc.data();
    const lastSignIn = await lastSignInOf(doc.id);
    const dormant = lastSignIn === null || lastSignIn <= cutoff;
    const alreadyFlagged = !!wallet.dormantFlaggedAt;
    if (dormant === alreadyFlagged) continue;
    await doc.ref.update({
      dormantFlaggedAt: dormant ? stamp(deps) : null,
      updatedAt: stamp(deps),
    });
    if (!dormant) {
      cleared += 1;
      continue;
    }
    flagged += 1;
    if (notify) {
      await notify(doc.id, {
        type: 'wallet.dormant',
        title: `₱${wallet.available} is waiting in your balance. Request a payout before you lose access to your account.`,
      });
    }
    if (notifyStaff) {
      await notifyStaff({
        type: 'admin.dormant_wallet',
        title: `A balance of ₱${wallet.available} has had no sign-in for ${DORMANT_WALLET_DAYS} days`,
      });
    }
  }
  return { flagged, cleared };
}

/**
 * Moves releases whose clearance window has passed from `clearing` to
 * `available`. Runs on a schedule; each entry is its own transaction and is
 * marked so a second pass skips it.
 */
async function clearSettledFunds(deps, now) {
  const { db } = deps;
  const due = await db
    .collection('ledger')
    .where('type', '==', 'release')
    .where('cleared', '==', false)
    .where('clearsAt', '<=', now)
    .limit(200)
    .get();
  let moved = 0;
  for (const doc of due.docs) {
    const ok = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(doc.ref);
      const entry = fresh.data();
      if (!fresh.exists || entry.cleared) return false;
      const when = stamp(deps);
      tx.update(doc.ref, { cleared: true, clearedAt: when });
      tx.update(db.doc(`wallets/${entry.uid}`), {
        clearing: increment(deps, -entry.amount),
        available: increment(deps, entry.amount),
        updatedAt: when,
      });
      return true;
    });
    if (ok) moved += 1;
  }
  return moved;
}

/**
 * Returns a held payment to the client after a cancellation or a dispute
 * closed in their favour.
 *
 * The gateway call happens *before* the record changes: a refund we recorded
 * but never sent would be a lie in the client's favour, whereas a refund sent
 * twice is prevented by the gateway's own idempotency on the payment id and
 * by the `held` check on retry.
 */
async function refundHeldPayment(deps, orderId, reason) {
  const { db, refundImpl, logger = console } = deps;
  const paymentRef = db.doc(`payments/${orderId}`);
  const snap = await paymentRef.get();
  if (!snap.exists) return 'no-payment';
  const payment = snap.data() || {};
  if (payment.method !== GATEWAY_METHOD) return 'not-held';
  if (payment.status !== 'paid' || payment.holdStatus !== 'held') {
    return 'not-held';
  }
  if (typeof payment.gatewayPaymentId !== 'string' || !payment.gatewayPaymentId) {
    // Settled by a webhook that carried no payment id; staff must refund by
    // hand. Flagged rather than silently skipped.
    await paymentRef.update({
      refundStatus: 'manual-required',
      updatedAt: stamp(deps),
    });
    return 'manual-required';
  }

  let refund;
  try {
    refund = await refundImpl({
      paymentId: payment.gatewayPaymentId,
      amount: payment.amount,
      reason,
      // One reference per order: the gateway's idempotency key, so a retried
      // trigger cannot refund the same order twice even if our record lags.
      referenceId: `refund-${orderId}`,
    });
  } catch (error) {
    logger.error('gateway refund failed', { orderId, message: error.message });
    await paymentRef.update({
      refundStatus: 'failed',
      updatedAt: stamp(deps),
    });
    return 'refund-failed';
  }

  return db.runTransaction(async (tx) => {
    const current = await tx.get(paymentRef);
    const data = current.data() || {};
    if (data.holdStatus !== 'held') return 'not-held';
    const now = stamp(deps);
    tx.update(paymentRef, {
      status: 'refunded',
      holdStatus: 'refunded',
      refundStatus: 'sent',
      refundReference: refund.id,
      refundedAt: now,
      updatedAt: now,
    });
    tx.set(db.collection('ledger').doc(), {
      uid: payment.clientId,
      type: 'refund',
      amount: payment.amount,
      orderId,
      createdAt: now,
    });
    return 'refunded';
  });
}

/**
 * Staff record a refund they made outside the gateway (a bank transfer after
 * Xendit refused, say). Only a payment still `held` and flagged for
 * attention can be closed this way, and the reference is required.
 */
async function markRefundedManually(deps, { orderId, adminUid, reference }) {
  const { db } = deps;
  if (!DOC_ID.test(orderId)) throw new LedgerError('bad-request', 'valid orderId required');
  const paymentRef = db.doc(`payments/${orderId}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(paymentRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such payment.');
    const payment = snap.data();
    if (payment.holdStatus !== 'held') {
      throw new LedgerError('not-pending', 'This payment is not held.');
    }
    const now = stamp(deps);
    tx.update(paymentRef, {
      status: 'refunded',
      holdStatus: 'refunded',
      refundStatus: 'manual',
      refundReference: reference,
      refundedAt: now,
      updatedAt: now,
    });
    tx.set(db.collection('ledger').doc(), {
      uid: payment.clientId,
      type: 'refund',
      amount: payment.amount,
      orderId,
      note: reference,
      createdAt: now,
    });
    tx.set(db.collection('adminActions').doc(), {
      actorId: adminUid,
      action: 'refund.manual',
      targetType: 'payment',
      targetId: orderId,
      note: reference,
      createdAt: now,
    });
    return payment.clientId;
  });
}

// --- payouts ---------------------------------------------------------------

/**
 * Moves a freelancer's available balance into a payout request that staff
 * settle by hand (GCash or bank transfer). Automating this through Xendit's
 * Payouts API is a possible next step; until then the honest model is a
 * request queue and a ledger.
 */
async function requestPayout(deps, uid) {
  const { db } = deps;
  const now = deps.now ? deps.now() : new Date();
  const userSnap = await db.doc(`users/${uid}`).get();
  if (!isAdult(userSnap.exists ? userSnap.data().birthDate : null, now)) {
    throw new LedgerError(
      'not-adult',
      'Payouts are available to students aged 18 and over. Add your birth date to your profile.',
    );
  }
  const walletRef = db.doc(`wallets/${uid}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(walletRef);
    const wallet = snap.exists ? snap.data() : {};
    const available = Number.isInteger(wallet.available) ? wallet.available : 0;
    const account = wallet.payoutAccount;

    if ((wallet.pendingPayout || 0) > 0) {
      throw new LedgerError('pending', 'A payout is already on its way.');
    }
    if (!validPayoutAccount(account)) {
      throw new LedgerError('no-account', 'Add a payout account first.');
    }
    if (available < MINIMUM_PAYOUT) {
      throw new LedgerError(
        'below-minimum',
        `Payouts start at ₱${MINIMUM_PAYOUT}.`,
      );
    }

    const now = stamp(deps);
    const payoutRef = db.collection('payouts').doc();
    tx.set(payoutRef, {
      uid,
      amount: available,
      status: 'requested',
      account: {
        type: account.type,
        accountName: account.accountName,
        accountNumber: account.accountNumber,
        ...(account.type === 'bank' ? { bankCode: account.bankCode } : {}),
      },
      requestedAt: now,
      updatedAt: now,
    });
    tx.update(walletRef, {
      available: increment(deps, -available),
      pendingPayout: increment(deps, available),
      dormantFlaggedAt: null,
      updatedAt: now,
    });
    tx.set(db.collection('ledger').doc(), {
      uid,
      type: 'payout_requested',
      amount: -available,
      payoutId: payoutRef.id,
      createdAt: now,
    });
    return { payoutId: payoutRef.id, amount: available };
  });
}

/** Staff record that the transfer was made, with the transfer's reference. */
async function settlePayout(deps, { payoutId, adminUid, reference }) {
  const { db } = deps;
  const payoutRef = db.doc(`payouts/${payoutId}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(payoutRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such payout.');
    const payout = snap.data();
    if (payout.status !== 'requested') {
      throw new LedgerError('not-pending', 'This payout was already closed.');
    }
    const now = stamp(deps);
    tx.update(payoutRef, {
      status: 'paid',
      reference,
      settledAt: now,
      settledBy: adminUid,
      updatedAt: now,
    });
    tx.update(db.doc(`wallets/${payout.uid}`), {
      pendingPayout: increment(deps, -payout.amount),
      totalPaidOut: increment(deps, payout.amount),
      updatedAt: now,
    });
    tx.set(db.collection('ledger').doc(), {
      uid: payout.uid,
      type: 'payout_paid',
      amount: 0,
      payoutId,
      note: reference,
      createdAt: now,
    });
    tx.set(db.collection('adminActions').doc(), {
      actorId: adminUid,
      action: 'payout.paid',
      targetType: 'payout',
      targetId: payoutId,
      note: reference,
      createdAt: now,
    });
    return payout.uid;
  });
}

/** Staff refuse a payout (wrong account details, say); the money goes back. */
async function rejectPayout(deps, { payoutId, adminUid, note }) {
  const { db } = deps;
  const payoutRef = db.doc(`payouts/${payoutId}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(payoutRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such payout.');
    const payout = snap.data();
    if (payout.status !== 'requested') {
      throw new LedgerError('not-pending', 'This payout was already closed.');
    }
    const now = stamp(deps);
    tx.update(payoutRef, {
      status: 'rejected',
      note,
      settledAt: now,
      settledBy: adminUid,
      updatedAt: now,
    });
    tx.update(db.doc(`wallets/${payout.uid}`), {
      pendingPayout: increment(deps, -payout.amount),
      available: increment(deps, payout.amount),
      updatedAt: now,
    });
    tx.set(db.collection('ledger').doc(), {
      uid: payout.uid,
      type: 'payout_rejected',
      amount: payout.amount,
      payoutId,
      note,
      createdAt: now,
    });
    tx.set(db.collection('adminActions').doc(), {
      actorId: adminUid,
      action: 'payout.rejected',
      targetType: 'payout',
      targetId: payoutId,
      note,
      createdAt: now,
    });
    return payout.uid;
  });
}

function validPayoutAccount(account) {
  return (
    account &&
    ['gcash', 'maya', 'bank'].includes(account.type) &&
    typeof account.accountName === 'string' &&
    account.accountName.trim().length > 0 &&
    validAccountNumber(account.type, account.accountNumber) &&
    (account.type !== 'bank' || BANK_CHANNELS.includes(account.bankCode))
  );
}

// --- automated payouts ---------------------------------------------------

/**
 * Hands a requested payout to the gateway.
 *
 * The payout id is the gateway's idempotency key, so calling this twice for
 * one payout sends one transfer. Three outcomes:
 *   - accepted: the record moves to `processing` and waits for the callback;
 *   - refused outright (bad account, unsupported bank): the money goes back
 *     to the balance and the student is told why;
 *   - the gateway is unreachable: nothing changes, staff retry from the
 *     queue.
 */
async function submitPayout(deps, payoutId) {
  const { db, payoutImpl, logger = console } = deps;
  const payoutRef = db.doc(`payouts/${payoutId}`);
  const snap = await payoutRef.get();
  if (!snap.exists) throw new LedgerError('not-found', 'No such payout.');
  const payout = snap.data();
  if (payout.status !== 'requested') {
    throw new LedgerError('not-pending', 'This payout is not waiting to be sent.');
  }

  let result;
  try {
    result = await payoutImpl({
      referenceId: payoutId,
      amountPesos: payout.amount,
      account: payout.account,
      description: 'Student Freelance Services payout',
    });
  } catch (error) {
    if (error.permanent) {
      await returnPayout(deps, {
        payoutId,
        actorId: 'xendit',
        outcome: 'failed',
        note: `Gateway refused: ${error.code}`,
        ledgerType: 'payout_rejected',
      });
      return { outcome: 'refused', code: error.code };
    }
    logger.error('payout submit failed', { payoutId, message: error.message });
    await payoutRef.update({
      gatewayError: String(error.message).slice(0, 200),
      updatedAt: stamp(deps),
    });
    return { outcome: 'unreachable' };
  }

  await payoutRef.update({
    status: 'processing',
    gatewayPayoutId: result.id,
    gatewayError: null,
    submittedAt: stamp(deps),
    updatedAt: stamp(deps),
  });
  return { outcome: 'submitted', gatewayPayoutId: result.id };
}

/**
 * The gateway's verdict on a payout it accepted. Succeeded: money left the
 * platform, the wallet's pending balance becomes paid out. Failed: the money
 * is back with the platform, so it goes back to the student's balance.
 */
async function completeGatewayPayout(deps, { payoutId, gatewayPayoutId, outcome, failureCode }) {
  const { db } = deps;
  if (outcome === 'succeeded') {
    const payoutRef = db.doc(`payouts/${payoutId}`);
    return db.runTransaction(async (tx) => {
      const snap = await tx.get(payoutRef);
      if (!snap.exists) return 'no-payout';
      const payout = snap.data();
      if (payout.status === 'paid') return 'already';
      if (payout.status !== 'processing' && payout.status !== 'requested') return 'not-pending';
      const now = stamp(deps);
      tx.update(payoutRef, {
        status: 'paid',
        reference: gatewayPayoutId,
        gatewayPayoutId,
        settledAt: now,
        settledBy: 'xendit',
        updatedAt: now,
      });
      tx.update(db.doc(`wallets/${payout.uid}`), {
        pendingPayout: increment(deps, -payout.amount),
        totalPaidOut: increment(deps, payout.amount),
        updatedAt: now,
      });
      tx.set(db.collection('ledger').doc(), {
        uid: payout.uid,
        type: 'payout_paid',
        amount: 0,
        payoutId,
        note: gatewayPayoutId,
        createdAt: now,
      });
      return 'paid';
    });
  }
  if (outcome === 'failed') {
    try {
      await returnPayout(deps, {
        payoutId,
        actorId: 'xendit',
        outcome: 'failed',
        note: `Transfer failed: ${failureCode || 'unknown'}`,
        ledgerType: 'payout_rejected',
        allowFrom: ['processing', 'requested'],
      });
      return 'returned';
    } catch (error) {
      if (error instanceof LedgerError) return error.code;
      throw error;
    }
  }
  // Reversed after success: the money came back to the platform but the
  // record already says paid. Flag it; a human decides whether to re-send.
  const payoutRef = db.doc(`payouts/${payoutId}`);
  const snap = await payoutRef.get();
  if (!snap.exists) return 'no-payout';
  await payoutRef.update({
    reversedAt: stamp(deps),
    gatewayError: `Reversed by the gateway: ${failureCode || 'unknown'}`,
    updatedAt: stamp(deps),
  });
  return 'reversed';
}

/** Shared by staff rejection and gateway failure: the money goes back. */
async function returnPayout(deps, { payoutId, actorId, outcome, note, ledgerType, allowFrom = ['requested'] }) {
  const { db } = deps;
  const payoutRef = db.doc(`payouts/${payoutId}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(payoutRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such payout.');
    const payout = snap.data();
    if (!allowFrom.includes(payout.status)) {
      throw new LedgerError('not-pending', 'This payout was already closed.');
    }
    const now = stamp(deps);
    tx.update(payoutRef, {
      status: outcome,
      note,
      settledAt: now,
      settledBy: actorId,
      updatedAt: now,
    });
    tx.update(db.doc(`wallets/${payout.uid}`), {
      pendingPayout: increment(deps, -payout.amount),
      available: increment(deps, payout.amount),
      updatedAt: now,
    });
    tx.set(db.collection('ledger').doc(), {
      uid: payout.uid,
      type: ledgerType,
      amount: payout.amount,
      payoutId,
      note,
      createdAt: now,
    });
    return payout.uid;
  });
}

// --- Pro: subscription, featured listings, verified badge ------------------

/** Whether a profile's Pro period covers `now`. */
function isProActive(profile, now) {
  const until = toDate(profile?.proUntil);
  return !!until && until > now;
}

/**
 * Activates or extends Pro after the gateway confirmed the ₱99 payment, and
 * carries the seller's currently featured listings forward to the new end.
 */
async function activatePro(deps, { uid, sessionId, amount, now }) {
  const { db } = deps;
  const { proPeriodEnd } = require('./policy');
  const userRef = db.doc(`users/${uid}`);
  const subRef = db.doc(`subscriptions/${sessionId}`);

  const result = await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    if (!userSnap.exists) return null;
    const subSnap = await tx.get(subRef);
    if (subSnap.exists && subSnap.data().status === 'paid') return 'already';

    const periodEnd = proPeriodEnd(toDate(userSnap.data().proUntil), now);
    const when = stamp(deps);
    tx.update(userRef, { proUntil: periodEnd, updatedAt: when });
    tx.set(
      subRef,
      {
        uid,
        amount,
        status: 'paid',
        periodEnd,
        paidAt: when,
        updatedAt: when,
      },
      { merge: true },
    );
    return periodEnd;
  });

  if (result === null) return 'no-user';
  if (result === 'already') return 'already';

  // Featured listings expire with the subscription; a renewal keeps them up.
  const featured = await db
    .collection('services')
    .where('sellerId', '==', uid)
    .where('featuredUntil', '>', now)
    .get();
  const batch = db.batch();
  featured.docs.forEach((doc) => {
    batch.update(doc.ref, { featuredUntil: result, updatedAt: stamp(deps) });
  });
  if (featured.docs.length) await batch.commit();
  return 'activated';
}

/**
 * Pins or unpins one of the caller's own listings. Capped per seller so a
 * subscriber cannot feature their whole catalogue.
 */
async function setFeatured(deps, { uid, serviceId, featured, now }) {
  const { db } = deps;
  if (!DOC_ID.test(serviceId)) {
    throw new LedgerError('bad-request', 'valid serviceId required');
  }
  const userSnap = await db.doc(`users/${uid}`).get();
  const profile = userSnap.exists ? userSnap.data() : null;
  if (featured && !isProActive(profile, now)) {
    throw new LedgerError('not-pro', 'Featured listings need an active Pro subscription.');
  }

  const serviceRef = db.doc(`services/${serviceId}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(serviceRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such service.');
    const service = snap.data();
    if (service.sellerId !== uid) {
      throw new LedgerError('forbidden', 'Not your listing.');
    }
    if (!featured) {
      tx.update(serviceRef, { featuredUntil: null, updatedAt: stamp(deps) });
      return 'unfeatured';
    }
    if (service.status !== 'published') {
      throw new LedgerError('not-published', 'Only published listings can be featured.');
    }
    const others = await db
      .collection('services')
      .where('sellerId', '==', uid)
      .where('featuredUntil', '>', now)
      .get();
    const count = others.docs.filter((d) => d.id !== serviceId).length;
    if (count >= FEATURED_PER_SELLER) {
      throw new LedgerError(
        'limit',
        `You can feature up to ${FEATURED_PER_SELLER} listings at a time.`,
      );
    }
    tx.update(serviceRef, {
      featuredUntil: toDate(profile.proUntil),
      updatedAt: stamp(deps),
    });
    return 'featured';
  });
}

/**
 * Staff decide a student-identity check. Approval sets `identityVerified` on
 * the profile; the badge itself shows only while Pro is also active, which
 * the client derives — there is no separate badge flag to drift.
 */
async function decideVerification(deps, { adminUid, uid, approve, note }) {
  const { db, deleteFile, logger = console } = deps;
  if (!DOC_ID.test(uid)) throw new LedgerError('bad-request', 'valid uid required');
  const requestRef = db.doc(`verificationRequests/${uid}`);
  const outcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(requestRef);
    if (!snap.exists) throw new LedgerError('not-found', 'No such request.');
    if (snap.data().status !== 'pending') {
      throw new LedgerError('not-pending', 'This request was already decided.');
    }
    const now = stamp(deps);
    tx.update(requestRef, {
      status: approve ? 'approved' : 'rejected',
      note: note || '',
      decidedAt: now,
      decidedBy: adminUid,
      // The photo is deleted below; the record keeps only the fact that
      // one was checked. An ID image has no reason to outlive the decision.
      idImagePath: '',
      idImageDeleted: true,
      updatedAt: now,
    });
    tx.update(db.doc(`users/${uid}`), {
      identityVerified: !!approve,
      updatedAt: now,
    });
    tx.set(db.collection('adminActions').doc(), {
      actorId: adminUid,
      action: approve ? 'verification.approved' : 'verification.rejected',
      targetType: 'user',
      targetId: uid,
      note: note || '',
      createdAt: now,
    });
    return { result: approve ? 'approved' : 'rejected', path: snap.data().idImagePath };
  });

  if (deleteFile && outcome.path) {
    try {
      await deleteFile(outcome.path);
    } catch (error) {
      // The decision stands; a leftover file is a retention problem, not a
      // correctness one, and is logged so it gets cleaned up.
      logger.error('id photo delete failed', { uid, message: error.message });
    }
  }
  return outcome.result;
}

// --- auto-completion -------------------------------------------------------

/**
 * Completes deliveries the client has ignored for AUTO_COMPLETE_DAYS.
 *
 * The client keeps every right they had: they could have requested a revision
 * or raised a dispute at any point in that window. What they cannot do is
 * keep the freelancer unpaid by doing nothing.
 */
async function autoCompleteStaleOrders(deps, now) {
  const { db, notify } = deps;
  const cutoff = new Date(now.getTime() - AUTO_COMPLETE_DAYS * 24 * 60 * 60 * 1000);
  const stale = await db
    .collection('orders')
    .where('status', '==', 'submitted')
    .where('updatedAt', '<=', cutoff)
    .limit(100)
    .get();

  let completed = 0;
  for (const doc of stale.docs) {
    const outcome = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(doc.ref);
      if (!fresh.exists || fresh.data().status !== 'submitted') return false;
      tx.update(doc.ref, {
        status: 'completed',
        autoCompleted: true,
        updatedAt: stamp(deps),
      });
      return true;
    });
    if (!outcome) continue;
    completed += 1;
    const order = doc.data();
    if (notify) {
      const title = `${order.serviceTitle}: completed automatically`;
      await notify(order.clientId, { type: 'order.completed', title, orderId: doc.id });
      await notify(order.freelancerId, { type: 'order.completed', title, orderId: doc.id });
    }
  }

  // Warn the clients whose window closes within REMINDER_HOURS_BEFORE, once.
  // Completing first means nobody is reminded about an order that just
  // completed in the same pass.
  const reminderCutoff = new Date(cutoff.getTime() + REMINDER_HOURS_BEFORE * HOUR);
  const closing = await db
    .collection('orders')
    .where('status', '==', 'submitted')
    .where('updatedAt', '<=', reminderCutoff)
    .limit(100)
    .get();
  let reminded = 0;
  for (const doc of closing.docs) {
    const order = doc.data();
    if (order.autoCompleteReminderSent) continue;
    await doc.ref.update({ autoCompleteReminderSent: true });
    reminded += 1;
    if (notify) {
      await notify(order.clientId, {
        type: 'order.auto_complete_reminder',
        title: `${order.serviceTitle}: accept the delivery or request changes within a day`,
        orderId: doc.id,
      });
    }
  }
  return { completed, reminded };
}

function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === 'function') return value.toDate();
  return null;
}

module.exports = {
  LedgerError,
  releaseHeldPayment,
  clearSettledFunds,
  refundHeldPayment,
  recordChargeback,
  flagDormantWallets,
  markRefundedManually,
  requestPayout,
  submitPayout,
  completeGatewayPayout,
  settlePayout,
  rejectPayout,
  validPayoutAccount,
  isProActive,
  activatePro,
  setFeatured,
  decideVerification,
  autoCompleteStaleOrders,
  toDate,
};
