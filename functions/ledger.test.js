/**
 * The money-moving operations the triggers call, run against the in-memory
 * Firestore. These are the paths a route test cannot reach: an order flipping
 * to completed or cancelled, the nightly auto-completion, and the push fan-out.
 *
 *   npm test
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const ledger = require('./ledger');
const { pushNotification } = require('./push');
const { proPeriodEnd, AUTO_COMPLETE_DAYS, isAdult, validAccountNumber } = require('./policy');
const { fakeDb, increment, silentLogger } = require('./test-helpers');

const NOW = new Date('2026-06-10T00:00:00Z');

function deps(db, extra = {}) {
  return {
    db,
    increment,
    serverTimestamp: () => NOW,
    now: () => NOW,
    logger: silentLogger,
    ...extra,
  };
}

const HELD = {
  clientId: 'buyer',
  freelancerId: 'seller',
  amount: 500,
  commission: 50,
  netToFreelancer: 450,
  status: 'paid',
  method: 'xendit',
  verified: true,
  holdStatus: 'held',
  gatewayPaymentId: 'pay_1',
};

// --- release ---------------------------------------------------------------

test('a new seller\'s first releases clear after a week, exactly once', async () => {
  const db = fakeDb({ 'payments/o1': { ...HELD } });
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'o1'), 'released-clearing');

  const wallet = db.docs.get('wallets/seller');
  assert.equal(wallet.available, 0, 'nothing spendable yet');
  assert.equal(wallet.clearing, 450, 'net, not gross');
  assert.equal(wallet.totalReleased, 450);
  assert.equal(wallet.releaseCount, 1);
  assert.equal(db.docs.get('payments/o1').holdStatus, 'released');

  const entries = [...db.docs.entries()].filter(([k]) => k.startsWith('ledger/'));
  assert.equal(entries.length, 1);
  assert.equal(entries[0][1].type, 'release');
  assert.equal(entries[0][1].amount, 450);
  assert.equal(entries[0][1].cleared, false);
  assert.equal(entries[0][1].clearsAt.toISOString(), '2026-06-17T00:00:00.000Z');

  // Firestore may deliver the trigger twice; the second run finds nothing held.
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'o1'), 'not-held');
  assert.equal(db.docs.get('wallets/seller').clearing, 450);

  // Too early: nothing moves. On the day: it clears, once.
  const early = new Date('2026-06-16T00:00:00Z');
  assert.equal(await ledger.clearSettledFunds(deps(db), early), 0);
  const due = new Date('2026-06-17T00:00:00Z');
  assert.equal(await ledger.clearSettledFunds(deps(db), due), 1);
  assert.equal(db.docs.get('wallets/seller').available, 450);
  assert.equal(db.docs.get('wallets/seller').clearing, 0);
  assert.equal(await ledger.clearSettledFunds(deps(db), due), 0, 'already cleared');
  assert.equal(db.docs.get(entries[0][0]).cleared, true);
});

test('an established seller\'s release is available immediately', async () => {
  const db = fakeDb({
    'payments/o1': { ...HELD },
    'wallets/seller': {
      available: 100,
      clearing: 0,
      pendingPayout: 300,
      totalReleased: 400,
      totalPaidOut: 0,
      releaseCount: 3,
    },
  });
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'o1'), 'released');
  const wallet = db.docs.get('wallets/seller');
  assert.equal(wallet.available, 550);
  assert.equal(wallet.clearing, 0);
  assert.equal(wallet.pendingPayout, 300, 'untouched');
  assert.equal(wallet.totalReleased, 850);
  assert.equal(wallet.releaseCount, 4);
});

// --- chargebacks -----------------------------------------------------------

test("a chargeback takes the seller's share from the balance, then from clearing, then as debt", async () => {
  const db = fakeDb({
    'payments/o1': { ...HELD, holdStatus: 'released' },
    'wallets/seller': { available: 100, clearing: 200, releaseCount: 5 },
  });
  const outcome = await ledger.recordChargeback(deps(db), {
    orderId: 'o1', adminUid: 'staff', reason: 'Cardholder disputed the charge with the issuer.',
  });
  assert.deepEqual(outcome, { freelancerId: 'seller', net: 450, recovered: 300, owed: 150 });

  const wallet = db.docs.get('wallets/seller');
  assert.equal(wallet.available, 0);
  assert.equal(wallet.clearing, 0);
  assert.equal(wallet.owed, 150, 'what the balance could not cover');
  assert.equal(db.docs.get('payments/o1').chargebackStatus, 'recorded');
  const entries = [...db.docs.values()].filter((d) => d.type === 'chargeback');
  assert.equal(entries.length, 1);
  assert.equal(entries[0].amount, -450, "the seller's net, never the gross: commission is the platform's loss");

  // Recording it twice would charge the seller twice.
  await assert.rejects(
    ledger.recordChargeback(deps(db), { orderId: 'o1', adminUid: 'staff', reason: 'Duplicate attempt here.' }),
    (e) => e.code === 'already',
  );
});

test('a chargeback on money still held is refused; that is a refund', async () => {
  const db = fakeDb({ 'payments/o1': { ...HELD } });
  await assert.rejects(
    ledger.recordChargeback(deps(db), { orderId: 'o1', adminUid: 'staff', reason: 'Issuer reversed it.' }),
    (e) => e.code === 'not-released',
  );
  assert.equal(db.docs.get('wallets/seller'), undefined, 'nothing was touched');
});

test('an owed chargeback is repaid from the next release before anything is credited', async () => {
  const db = fakeDb({
    'payments/o2': { ...HELD },
    'wallets/seller': { available: 0, clearing: 0, owed: 150, releaseCount: 5 },
  });
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'o2'), 'released');
  const wallet = db.docs.get('wallets/seller');
  assert.equal(wallet.owed, 0);
  assert.equal(wallet.available, 300, '450 released, 150 repaid');
  assert.equal(wallet.totalReleased, 450, 'lifetime earnings count the whole release');
  const types = [...db.docs.values()].filter((d) => d.type).map((d) => [d.type, d.amount]).sort();
  assert.deepEqual(types, [['chargeback_recovery', -150], ['release', 300]]);
});

// --- dormant balances ------------------------------------------------------

test('a balance whose owner stopped signing in is flagged once, and unflagged when they return', async () => {
  const db = fakeDb({
    'wallets/gone': { available: 800 },
    'wallets/active': { available: 500 },
    'wallets/back': { available: 200, dormantFlaggedAt: new Date('2026-01-01') },
    'wallets/empty': { available: 0 },
  });
  const lastSeen = {
    gone: new Date('2026-01-01T00:00:00Z'),
    active: new Date('2026-06-09T00:00:00Z'),
    back: new Date('2026-06-08T00:00:00Z'),
  };
  const told = [];
  const staffTold = [];
  const d = deps(db, {
    lastSignInOf: async (uid) => lastSeen[uid] ?? null,
    notify: async (uid, payload) => told.push([uid, payload.type]),
    notifyStaff: async (payload) => staffTold.push(payload.type),
  });

  assert.deepEqual(await ledger.flagDormantWallets(d, NOW), { flagged: 1, cleared: 1 });
  assert.ok(db.docs.get('wallets/gone').dormantFlaggedAt);
  assert.equal(db.docs.get('wallets/active').dormantFlaggedAt, undefined);
  assert.equal(db.docs.get('wallets/back').dormantFlaggedAt, null, 'signed in again');
  assert.deepEqual(told, [['gone', 'wallet.dormant']]);
  assert.deepEqual(staffTold, ['admin.dormant_wallet']);

  // The next run finds nothing new: no second nag.
  assert.deepEqual(await ledger.flagDormantWallets(d, NOW), { flagged: 0, cleared: 0 });
  assert.equal(told.length, 1);
});

test('staff can close a stuck refund by hand, with a reference', async () => {
  const db = fakeDb({ 'payments/o1': { ...HELD, refundStatus: 'failed' } });
  const clientId = await ledger.markRefundedManually(deps(db), {
    orderId: 'o1',
    adminUid: 'staff',
    reference: 'BANK-123',
  });
  assert.equal(clientId, 'buyer');
  const payment = db.docs.get('payments/o1');
  assert.equal(payment.status, 'refunded');
  assert.equal(payment.holdStatus, 'refunded');
  assert.equal(payment.refundStatus, 'manual');
  assert.equal(payment.refundReference, 'BANK-123');
  const actions = [...db.docs.keys()].filter((k) => k.startsWith('adminActions/'));
  assert.equal(actions.length, 1);
  await assert.rejects(
    ledger.markRefundedManually(deps(db), { orderId: 'o1', adminUid: 'staff', reference: 'x' }),
    /not held/,
  );
});

test('manual and unpaid settlements are never released', async () => {
  const db = fakeDb({
    'payments/manual': { ...HELD, method: 'manual', verified: false, holdStatus: undefined },
    'payments/legacy': { ...HELD, method: 'payMongo' },
    'payments/pending': { ...HELD, status: 'pending', holdStatus: undefined },
  });
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'manual'), 'not-held');
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'pending'), 'not-held');
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'legacy'), 'not-held', 'only the current gateway');
  assert.equal(await ledger.releaseHeldPayment(deps(db), 'ghost'), 'no-payment');
  assert.equal(db.docs.has('wallets/seller'), false);
});

// --- refund ----------------------------------------------------------------

test('cancelling a held order refunds through the gateway before recording it', async () => {
  const db = fakeDb({ 'payments/o1': { ...HELD } });
  const calls = [];
  const refundImpl = async (args) => {
    calls.push(args);
    return { id: 'ref_1' };
  };
  const outcome = await ledger.refundHeldPayment(deps(db, { refundImpl }), 'o1', 'cancelled');
  assert.equal(outcome, 'refunded');
  assert.deepEqual(calls, [
    { paymentId: 'pay_1', amount: 500, reason: 'cancelled', referenceId: 'refund-o1' },
  ]);

  const payment = db.docs.get('payments/o1');
  assert.equal(payment.status, 'refunded');
  assert.equal(payment.holdStatus, 'refunded');
  assert.equal(payment.refundReference, 'ref_1');
  assert.equal(db.docs.has('wallets/seller'), false, 'the freelancer never saw the money');

  // A retry must not refund twice.
  assert.equal(await ledger.refundHeldPayment(deps(db, { refundImpl }), 'o1'), 'not-held');
  assert.equal(calls.length, 1);
});

test('a gateway refund failure is flagged for staff, not swallowed', async () => {
  const db = fakeDb({ 'payments/o1': { ...HELD } });
  const refundImpl = async () => {
    throw new Error('xendit responded 500');
  };
  assert.equal(await ledger.refundHeldPayment(deps(db, { refundImpl }), 'o1'), 'refund-failed');
  const payment = db.docs.get('payments/o1');
  assert.equal(payment.refundStatus, 'failed');
  assert.equal(payment.holdStatus, 'held', 'still held: nothing was returned');
});

test('a payment with no gateway id needs a manual refund', async () => {
  const db = fakeDb({ 'payments/o1': { ...HELD, gatewayPaymentId: undefined } });
  const refundImpl = async () => assert.fail('must not call the gateway');
  assert.equal(await ledger.refundHeldPayment(deps(db, { refundImpl }), 'o1'), 'manual-required');
  assert.equal(db.docs.get('payments/o1').refundStatus, 'manual-required');
});

// --- auto-completion -------------------------------------------------------

const day = 24 * 60 * 60 * 1000;

function submittedOrder(ageDays) {
  return {
    serviceTitle: 'Poster',
    clientId: 'buyer',
    freelancerId: 'seller',
    status: 'submitted',
    updatedAt: new Date(NOW.getTime() - ageDays * day),
  };
}

test('deliveries ignored past the window complete; fresh ones wait', async () => {
  const db = fakeDb({
    'orders/old': submittedOrder(AUTO_COMPLETE_DAYS + 1),
    'orders/exact': submittedOrder(AUTO_COMPLETE_DAYS),
    'orders/fresh': submittedOrder(AUTO_COMPLETE_DAYS - 2),
    'orders/inProgress': { ...submittedOrder(10), status: 'inProgress' },
  });
  const told = [];
  const notify = async (uid, payload) => told.push([uid, payload.type]);

  const { completed, reminded } = await ledger.autoCompleteStaleOrders(
    deps(db, { notify }),
    NOW,
  );
  assert.equal(completed, 2);
  assert.equal(reminded, 0);
  assert.equal(db.docs.get('orders/old').status, 'completed');
  assert.equal(db.docs.get('orders/old').autoCompleted, true);
  assert.equal(db.docs.get('orders/exact').status, 'completed');
  assert.equal(db.docs.get('orders/fresh').status, 'submitted');
  assert.equal(db.docs.get('orders/inProgress').status, 'inProgress');
  assert.deepEqual(told.sort(), [
    ['buyer', 'order.completed'],
    ['buyer', 'order.completed'],
    ['seller', 'order.completed'],
    ['seller', 'order.completed'],
  ]);
});

test('a client is reminded once, a day before the window closes', async () => {
  const db = fakeDb({
    'orders/closing': submittedOrder(AUTO_COMPLETE_DAYS - 0.5),
    'orders/fresh': submittedOrder(AUTO_COMPLETE_DAYS - 1.5),
  });
  const told = [];
  const notify = async (uid, payload) => told.push([uid, payload.type]);

  const first = await ledger.autoCompleteStaleOrders(deps(db, { notify }), NOW);
  assert.deepEqual(first, { completed: 0, reminded: 1 });
  assert.deepEqual(told, [['buyer', 'order.auto_complete_reminder']]);
  assert.equal(db.docs.get('orders/closing').autoCompleteReminderSent, true);
  assert.equal(db.docs.get('orders/fresh').autoCompleteReminderSent, undefined);

  // The next pass, six hours later, does not nag again.
  const later = new Date(NOW.getTime() + 6 * 60 * 60 * 1000);
  const second = await ledger.autoCompleteStaleOrders(deps(db, { notify }), later);
  assert.equal(second.reminded, 0);
  assert.equal(told.length, 1);
});

// --- age and account shape -------------------------------------------------

test('adulthood is checked by date, never assumed', () => {
  const today = new Date('2026-06-10T00:00:00Z');
  assert.equal(isAdult(new Date('2008-06-10T00:00:00Z'), today), true, '18 today');
  assert.equal(isAdult(new Date('2008-06-11T00:00:00Z'), today), false, '18 tomorrow');
  assert.equal(isAdult(null, today), false);
  assert.equal(isAdult(undefined, today), false);
  assert.equal(isAdult({ toDate: () => new Date('1999-01-01') }, today), true, 'Timestamp');
});

test('payout account numbers must look like the thing they claim to be', () => {
  assert.equal(validAccountNumber('gcash', '09171234567'), true);
  assert.equal(validAccountNumber('maya', '09171234567'), true);
  assert.equal(validAccountNumber('gcash', '0917123456'), false, 'ten digits');
  assert.equal(validAccountNumber('gcash', '08171234567'), false, 'not a PH mobile');
  assert.equal(validAccountNumber('gcash', '+639171234567'), false, 'no country code form');
  assert.equal(validAccountNumber('bank', '1234567890'), true);
  assert.equal(validAccountNumber('bank', '12345'), false);
  assert.equal(validAccountNumber('paypal', '09171234567'), false);
});

// --- Pro period ------------------------------------------------------------

test('a Pro period extends from its end when renewed early, from now otherwise', () => {
  const end = proPeriodEnd(null, NOW);
  assert.equal(end.toISOString(), '2026-07-10T00:00:00.000Z');
  const early = proPeriodEnd(new Date('2026-07-01T00:00:00Z'), NOW);
  assert.equal(early.toISOString(), '2026-07-31T00:00:00.000Z');
  const lapsed = proPeriodEnd(new Date('2026-01-01T00:00:00Z'), NOW);
  assert.equal(lapsed.toISOString(), '2026-07-10T00:00:00.000Z');
});

test('renewing Pro carries featured listings to the new end date', async () => {
  const db = fakeDb({
    'users/seller': { proUntil: new Date('2026-07-01T00:00:00Z') },
    'services/a': { sellerId: 'seller', status: 'published', featuredUntil: new Date('2026-07-01T00:00:00Z') },
    'services/b': { sellerId: 'seller', status: 'published', featuredUntil: null },
    'services/c': { sellerId: 'other', status: 'published', featuredUntil: new Date('2026-07-01T00:00:00Z') },
  });
  const outcome = await ledger.activatePro(deps(db), {
    uid: 'seller',
    sessionId: 'cs_1',
    amount: 99,
    now: NOW,
  });
  assert.equal(outcome, 'activated');
  const newEnd = '2026-07-31T00:00:00.000Z';
  assert.equal(db.docs.get('users/seller').proUntil.toISOString(), newEnd);
  assert.equal(db.docs.get('services/a').featuredUntil.toISOString(), newEnd);
  assert.equal(db.docs.get('services/b').featuredUntil, null, 'not featured, stays so');
  assert.equal(
    db.docs.get('services/c').featuredUntil.toISOString(),
    '2026-07-01T00:00:00.000Z',
    'another seller is untouched',
  );
});

// --- push ------------------------------------------------------------------

test('push fans out to every device and forgets the dead ones', async () => {
  const db = fakeDb({
    'users/u1/devices/tokA': { token: 'tokA' },
    'users/u1/devices/tokB': { token: 'tokB' },
    'users/u1/devices/tokC': { token: 'tokC' },
  });
  let sent;
  const messaging = {
    async sendEachForMulticast(message) {
      sent = message;
      return {
        successCount: 1,
        responses: [
          { success: true },
          { success: false, error: { code: 'messaging/registration-token-not-registered' } },
          { success: false, error: { code: 'messaging/internal-error' } },
        ],
      };
    },
  };
  const result = await pushNotification(
    { db, messaging, logger: silentLogger },
    {
      uid: 'u1',
      notificationId: 'n1',
      notification: { type: 'chat.message', title: 'New message', conversationId: 'a_b' },
    },
  );
  assert.deepEqual(result, { sent: 1, pruned: 1 });
  assert.deepEqual(sent.tokens, ['tokA', 'tokB', 'tokC']);
  assert.deepEqual(sent.data, {
    type: 'chat.message',
    notificationId: 'n1',
    conversationId: 'a_b',
  });
  assert.equal(sent.notification.title, 'New message');
  assert.equal(db.docs.has('users/u1/devices/tokB'), false, 'unregistered token pruned');
  assert.equal(db.docs.has('users/u1/devices/tokC'), true, 'transient failure kept');
});

test('push with no registered devices sends nothing', async () => {
  const db = fakeDb({});
  const messaging = {
    async sendEachForMulticast() {
      assert.fail('must not send');
    },
  };
  const result = await pushNotification(
    { db, messaging, logger: silentLogger },
    { uid: 'u1', notificationId: 'n1', notification: { type: 'x', title: 't' } },
  );
  assert.deepEqual(result, { sent: 0, pruned: 0 });
});

// --- audit -----------------------------------------------------------------

const auditModule = require('./audit');

test('listing writes audit creation, pricing changes, status and featuring', () => {
  const created = auditModule.serviceAuditEntries('s1', undefined, {
    sellerId: 'seller', startingPrice: 500, status: 'draft',
  });
  assert.equal(created.length, 1);
  assert.equal(created[0].action, 'service.created');
  assert.equal(created[0].details.pricingMode, 'fixed');

  const before = { sellerId: 'seller', startingPrice: 500, pricingMode: 'fixed', status: 'draft' };
  const after = { ...before, startingPrice: 800, pricingMode: 'negotiable', status: 'published' };
  const changed = auditModule.serviceAuditEntries('s1', before, after).map((e) => e.action);
  assert.deepEqual(changed, ['service.pricing_changed', 'service.status_changed']);

  const pricing = auditModule.serviceAuditEntries('s1', before, after)[0].details;
  assert.equal(pricing.startingPriceBefore, 500);
  assert.equal(pricing.startingPriceAfter, 800);
  assert.equal(pricing.pricingModeAfter, 'negotiable');

  assert.deepEqual(auditModule.serviceAuditEntries('s1', before, { ...before, description: 'x' }), []);
});

test('profile and offer changes name the party that made them', () => {
  const [created] = auditModule.userAuditEntries('u1', undefined, {
    email: 'a.b.123456@umindanao.edu.ph', studentId: '123456', identityVerified: true,
  });
  assert.equal(created.action, 'user.created');
  assert.equal(created.details.studentId, '123456');

  const [suspended] = auditModule.userAuditEntries('u1', { suspended: false }, { suspended: true });
  assert.equal(suspended.action, 'user.suspended');

  const sent = auditModule.offerAuditEntries('o1', undefined, {
    freelancerId: 'f', clientId: 'c', price: 1200, serviceId: 's',
  })[0];
  assert.equal(sent.action, 'offer.sent');
  assert.equal(sent.actorId, 'f');

  const accepted = auditModule.offerAuditEntries('o1', { status: 'pending' }, {
    status: 'accepted', freelancerId: 'f', clientId: 'c', price: 1200,
  })[0];
  assert.equal(accepted.actorId, 'c', 'the client accepts');
  const withdrawn = auditModule.offerAuditEntries('o1', { status: 'pending' }, {
    status: 'withdrawn', freelancerId: 'f', clientId: 'c', price: 1200,
  })[0];
  assert.equal(withdrawn.actorId, 'f', 'the freelancer withdraws');
});

test('audit writes never throw and truncate long detail strings', async () => {
  const db = fakeDb({});
  await auditModule.writeAudit({ db, logger: silentLogger }, {
    actorId: 'u', action: 'x', details: { note: 'y'.repeat(500), n: 1, skip: undefined },
  });
  const [entry] = [...db.docs.values()];
  assert.equal(entry.details.note.length, 200);
  assert.equal(entry.details.n, 1);
  assert.equal('skip' in entry.details, false);

  const broken = { collection: () => ({ add: async () => { throw new Error('down'); } }) };
  await auditModule.writeAudit({ db: broken, logger: silentLogger }, { actorId: 'u', action: 'x' });
});
