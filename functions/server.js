/**
 * Trusted backend for Student Freelance Services.
 *
 * This is the only place the Xendit secret key may live. The Flutter app
 * never sees it: an APK can be decompiled and a web build ships readable
 * JavaScript, so an embedded `sk_` would let anyone refund payments and read
 * every transaction on the account.
 *
 * Routes:
 *   GET  /health                          liveness probe
 *   POST /checkout                        buyer pays an order (held by the platform)
 *   POST /payments/:orderId/sync          either party asks the gateway about a pending payment
 *   POST /webhook                         Xendit settles a payment or a Pro month
 *   POST /pro/checkout                    seller buys a Pro month
 *   POST /pro/sync                        owner asks the gateway about pending Pro checkouts
 *   POST /services/:id/featured           Pro seller pins or unpins a listing
 *   POST /wallet/payout                   freelancer requests their balance
 *   POST /admin/payouts/:id/settle        staff record a transfer
 *   POST /admin/payouts/:id/reject        staff refuse one
 *   POST /admin/verification/:uid         staff decide a student-ID check
 *
 * Every authenticated route takes only ids. Amounts, participants, and
 * entitlements are re-derived here from Firestore — a client-supplied amount
 * would let a buyer pay ₱1 for a ₱5000 order.
 *
 * Built as a factory so the dependencies that reach the outside world —
 * Firestore, token verification, and the HTTP calls to Xendit — can be
 * substituted in tests. `npm test` exercises every route this way.
 *
 * Deliberately plain Express so it runs unchanged as a Cloud Function
 * (index.js) or standalone on any container host (`node server.js`).
 */

const express = require('express');
const crypto = require('crypto');

const policy = require('./policy');
const ledger = require('./ledger');
const xendit = require('./xendit');
const { writeNotification } = require('./push');
const { writeAudit, ACTIONS } = require('./audit');

const {
  DOC_ID,
  SUPPORTED_CURRENCY,
  PAYABLE_ORDER_STATUSES,
  PRO_PRICE,
  GATEWAY_METHOD,
  breakdownOf,
  validateOrderForPayment,
  isUmEmail,
  hasPermission,
} = policy;

const MAX_BODY_BYTES = 64 * 1024;

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

/** Reads configuration from the environment, failing fast and loudly. */
function configFromEnv() {
  const secretKey = requiredEnv('XENDIT_SECRET_KEY');
  return {
    secretKey,
    // Shown once in the Xendit dashboard (Settings → Developers → Callbacks)
    // and sent back on every delivery as x-callback-token.
    callbackToken: requiredEnv('XENDIT_CALLBACK_TOKEN'),
    successUrl: requiredEnv('APP_SUCCESS_URL'),
    cancelUrl: requiredEnv('APP_CANCEL_URL'),
    // Test and live are separate keys; reported by /health so a tester
    // always knows which one a deployment holds.
    liveMode: secretKey.startsWith('xnd_production_'),
    // Send payouts through Xendit Payouts as soon as a student requests
    // one. Off means the staff queue and a hand-made transfer, as before.
    // Needs the Payouts product enabled and a funded Xendit balance.
    payoutsAutomated: process.env.XENDIT_PAYOUTS === 'auto',
    // Browsers block a cross-origin call unless the server opts in, so the
    // Flutter *web* build cannot reach this service without an allowlist.
    // Comma-separated; empty means non-browser clients only.
    allowedOrigins: (process.env.APP_ALLOWED_ORIGINS || '')
      .split(',')
      .map((o) => o.trim())
      .filter(Boolean),
  };
}

/** Wraps an async handler so a rejected promise becomes a 500 rather than an
 *  unhandled rejection that leaves the request hanging until it times out.
 *  Express 4 does not await handlers, so this is not optional. */
const wrap = (handler) => (req, res, next) =>
  Promise.resolve(handler(req, res, next)).catch(next);

/** Maps a LedgerError code onto an HTTP status. */
const LEDGER_STATUS = {
  'bad-request': 400,
  forbidden: 403,
  'not-found': 404,
  'not-pro': 402,
  'not-published': 409,
  'not-pending': 409,
  'not-released': 409,
  'not-gateway': 409,
  already: 409,
  'invalid-record': 409,
  pending: 409,
  limit: 409,
  'no-account': 422,
  'below-minimum': 422,
  'not-adult': 422,
};

/**
 * Builds the Express app.
 *
 * @param {object} deps
 * @param {FirebaseFirestore.Firestore} deps.db
 * @param {(token: string) => Promise<{uid: string}>} deps.verifyIdToken
 * @param {typeof fetch} [deps.fetchImpl]
 * @param {object} [deps.config]
 * @param {() => any} [deps.serverTimestamp]
 * @param {(n: number) => any} [deps.increment]
 * @param {() => Date} [deps.now]
 */
function createApp({
  db,
  verifyIdToken,
  fetchImpl = globalThis.fetch,
  config = configFromEnv(),
  serverTimestamp,
  increment,
  now = () => new Date(),
  logger = console,
}) {
  if (!db) throw new Error('createApp requires a Firestore instance');
  if (typeof verifyIdToken !== 'function') {
    throw new Error('createApp requires verifyIdToken');
  }

  const deps = { db, verifyIdToken, fetchImpl, config, serverTimestamp, increment, now, logger };
  deps.payoutImpl = (args) => xendit.createPayout(args, deps);

  const app = express();
  app.disable('x-powered-by');
  // Behind a proxy on Cloud Run/Render, so req.ip reflects the client.
  app.set('trust proxy', true);

  app.use((req, res, next) => applyCors(req, res, next, config));

  app.get('/health', (_req, res) =>
    res.json({
      status: 'ok',
      mode: config.liveMode ? 'live' : 'test',
      payouts: config.payoutsAutomated ? 'auto' : 'manual',
    }),
  );

  // The webhook needs the byte-exact body to verify its signature, so it is
  // registered before the JSON parser and uses express.raw().
  app.post(
    '/webhook',
    express.raw({ type: '*/*', limit: MAX_BODY_BYTES }),
    wrap((req, res) => handleWebhook(req, res, deps)),
  );

  app.use(express.json({ limit: MAX_BODY_BYTES }));

  // Per-route rather than app-wide so an unknown path still answers 404
  // rather than demanding a token for a route that does not exist.
  const authed = wrap((req, res, next) => authenticate(req, res, next, deps));
  const route = (path, handler) =>
    app.post(path, authed, wrap((req, res) => handler(req, res, deps)));

  route('/checkout', handleCheckout);
  route('/payments/:orderId/sync', handlePaymentSync);
  route('/pro/checkout', handleProCheckout);
  route('/pro/sync', handleProSync);
  route('/services/:id/featured', handleFeatured);
  route('/users/search', handlePublicUserSearch);
  route('/wallet/payout', handlePayoutRequest);
  route('/admin/payouts/:id/settle', handlePayoutSettle);
  route('/admin/payouts/:id/submit', handlePayoutSubmit);
  route('/admin/payouts/:id/reject', handlePayoutReject);
  route('/admin/verification/:uid', handleVerification);
  route('/admin/payments/:orderId/refund', handleRefundRetry);
  route('/admin/payments/:orderId/refund-manual', handleRefundManual);
  route('/admin/payments/:orderId/chargeback', handleChargeback);
  route('/admin/orders/:id/chat-snapshot', async (req, res) => {
    if (!(await requirePermission(req, res, deps, 'disputes.resolve'))) return;
    return require('./dispute-chat').reviewChat(req, res, deps);
  });

  app.use((_req, res) => res.status(404).json({ error: 'not found' }));

  // Final safety net. Without it Express would render a stack trace, which
  // leaks paths and dependency versions to whoever provoked the error.
  // eslint-disable-next-line no-unused-vars
  app.use((error, _req, res, _next) => {
    if (error?.type === 'entity.too.large') {
      return res.status(413).json({ error: 'payload too large' });
    }
    if (error?.type === 'entity.parse.failed') {
      return res.status(400).json({ error: 'malformed json' });
    }
    if (error instanceof ledger.LedgerError) {
      return res
        .status(LEDGER_STATUS[error.code] || 400)
        .json({ error: error.message, code: error.code });
    }
    logger.error('unhandled error', { message: error?.message });
    return res.status(500).json({ error: 'internal error' });
  });

  return app;
}

async function handlePublicUserSearch(req, res, { db, now }) {
  const query = typeof req.body.query === 'string'
    ? req.body.query.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').trim().toLowerCase()
    : '';
  if (query.length < 2 || query.length > 80) {
    return res.status(400).json({ error: 'Search text must be 2 to 80 characters.' });
  }
  const rateRef = db.doc(`userSearchRateLimits/${req.uid}`);
  const allowed = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(rateRef);
    const current = snapshot.data() || {};
    const startedAt = current.startedAt?.toDate?.() || current.startedAt;
    const activeWindow = startedAt instanceof Date && now() - startedAt < 10 * 60 * 1000;
    if (activeWindow && current.count >= 30) return false;
    transaction.set(rateRef, {
      startedAt: activeWindow ? current.startedAt : now(),
      count: activeWindow ? current.count + 1 : 1,
    });
    return true;
  });
  if (!allowed) return res.status(429).json({ error: 'Too many searches. Try again in a few minutes.' });
  const end = `${query}\uf8ff`;
  const fields = ['nameLower', 'programLower', 'departmentLower', 'departmentCodeLower'];
  const pages = await Promise.all(fields.map((field) => db.collection('publicUserSearch')
    .where(field, '>=', query).where(field, '<=', end).limit(10).get()));
  const matches = new Map();
  for (const page of pages) {
    for (const doc of page.docs) {
      const data = doc.data();
      if (data.suspended === true) continue;
      const identityKey = typeof data.identityKey === 'string' && data.identityKey
        ? data.identityKey
        : doc.id;
      const previous = matches.get(identityKey);
      if (previous && previous.sourceId.localeCompare(doc.id) <= 0) continue;
      matches.set(identityKey, { sourceId: doc.id, user: {
        uid: doc.id,
        displayName: data.displayName,
        photoUrl: data.photoUrl || null,
        program: data.program || null,
        department: data.department || null,
        joinedAt: data.createdAt?.toDate?.().toISOString?.() || null,
        publicRole: data.publicRole || null,
      } });
    }
  }
  return res.json({ users: [...matches.values()].map((match) => match.user).slice(0, 20) });
}

/** `flutter run -d chrome` picks a fresh port every launch; a developer's own
 *  machine is allowed on any port. The token check still applies, so this
 *  opens nothing a browser could not already do from the listed origins. */
const LOCAL_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function applyCors(req, res, next, config) {
  const origin = req.get('Origin');
  if (origin && (config.allowedOrigins.includes(origin) || LOCAL_ORIGIN.test(origin))) {
    res.set('Access-Control-Allow-Origin', origin);
    res.set('Vary', 'Origin');
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.set('Access-Control-Max-Age', '600');
  }
  // Preflight is answered whether or not the origin is allowed; a disallowed
  // one simply arrives without the headers the browser needs.
  if (req.method === 'OPTIONS') return res.status(204).end();
  return next();
}

/**
 * Every route past the webhook needs a Firebase ID token from a verified
 * University of Mindanao account. The rules already refuse such a token
 * everything else; this keeps the backend from being the one door that does
 * not check.
 */
async function authenticate(req, res, next, { verifyIdToken }) {
  const header = req.get('Authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : null;
  if (!token) return res.status(401).json({ error: 'unauthenticated' });
  let decoded;
  try {
    decoded = (await verifyIdToken(token)) || {};
  } catch {
    return res.status(401).json({ error: 'unauthenticated' });
  }
  if (!decoded.uid) return res.status(401).json({ error: 'unauthenticated' });
  if (!isUmEmail(decoded.email) || decoded.email_verified !== true) {
    return res.status(403).json({ error: 'a verified UM account is required' });
  }
  req.uid = decoded.uid;
  req.email = decoded.email;
  return next();
}

/**
 * Staff routes: the caller must hold `permission` in `admins/{uid}`, either
 * as the main admin (role 'admin') or as staff with it in their list. A
 * staff member who moderates listings cannot settle a payout by calling the
 * route directly. The access record is returned so a route can apply a
 * narrower rule when its action has one.
 */
async function requirePermission(req, res, { db }, permission) {
  let snap;
  try {
    snap = await db.doc(`admins/${req.uid}`).get();
  } catch {
    res.status(503).json({ error: 'storage unavailable' });
    return false;
  }
  if (!snap.exists || !hasPermission(snap.data(), permission)) {
    res.status(403).json({ error: 'forbidden' });
    return false;
  }
  return snap.data();
}

// --- order checkout --------------------------------------------------------

/**
 * Creates a checkout session for one order.
 *
 * The client sends only an order id. Amount, participants, and the commission
 * split are all re-derived here from the trusted order document.
 */
async function handleCheckout(req, res, deps) {
  const { db, config, logger } = deps;
  const uid = req.uid;

  const orderId = req.body?.orderId;
  // Rejecting anything but a plain id also closes a path-traversal hole:
  // `orders/${'x/sub/y'}` addresses a different document entirely.
  if (typeof orderId !== 'string' || !DOC_ID.test(orderId)) {
    return res.status(400).json({ error: 'valid orderId required' });
  }
  const method = paymentMethodOf(req.body);
  if (!method) return res.status(400).json({ error: 'unknown payment method' });

  let orderSnap;
  try {
    orderSnap = await db.doc(`orders/${orderId}`).get();
  } catch (error) {
    logger.error('order lookup failed', { orderId, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  if (!orderSnap.exists) return res.status(404).json({ error: 'no such order' });

  const order = orderSnap.data() || {};

  // Only the buyer may pay, and only while the order is live.
  if (order.clientId !== uid) return res.status(403).json({ error: 'forbidden' });
  if (!PAYABLE_ORDER_STATUSES.includes(order.status)) {
    return res.status(409).json({ error: 'order is not payable' });
  }

  const invalid = validateOrderForPayment(order);
  if (invalid) {
    // A malformed order would otherwise reach the gateway as NaN.
    logger.error('order failed validation', { orderId, reason: invalid });
    return res.status(422).json({ error: invalid });
  }

  // The rules already refuse an order whose price is not the listing's fixed
  // price or an accepted offer's price. Re-derive that here so the backend
  // never charges an amount the pricing model does not justify, whatever
  // produced the order document.
  let mismatch;
  try {
    mismatch = await pricingMismatch(db, orderId, order);
  } catch (error) {
    logger.error('pricing lookup failed', { orderId, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  if (mismatch) {
    logger.error('order price not justified', { orderId, reason: mismatch });
    return res.status(422).json({ error: mismatch });
  }

  const paymentRef = db.doc(`payments/${orderId}`);
  let existing;
  try {
    existing = await paymentRef.get();
  } catch (error) {
    logger.error('payment lookup failed', { orderId, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  if (existing.exists && existing.data()?.status === 'paid') {
    return res.status(409).json({ error: 'already paid' });
  }

  // "Reopen checkout" must hand back the invoice that is already open, not
  // mint a second one: two live invoices for one order is how a buyer gets
  // charged twice. Only an invoice the gateway no longer accepts (expired,
  // or one we cannot ask about) is replaced.
  const openInvoice = await reusableInvoice(existing, deps);
  if (openInvoice) {
    return res.json({ checkoutUrl: openInvoice.checkoutUrl, reference: openInvoice.id, reused: true });
  }

  const split = breakdownOf(order.price);
  let reservation;
  try {
    reservation = await reserveCheckout(paymentRef, { orderId, order, split, deps });
  } catch (error) {
    logger.error('checkout reservation failed', { orderId, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  if (reservation.state === 'paid') {
    return res.status(409).json({ error: 'already paid' });
  }
  if (reservation.state === 'creating') {
    return res.status(409).json({ error: 'checkout is being created; retry shortly' });
  }

  let session;
  try {
    session = await xendit.createInvoice(
      {
        // Echoed on every callback; how settlement finds the order.
        externalId: orderExternalId(orderId),
        amountPesos: split.gross,
        description: order.serviceTitle || 'Freelance service',
        payerEmail: req.email,
        metadata: { kind: 'order', orderId },
        successUrl: `${config.successUrl}?order=${encodeURIComponent(orderId)}`,
        failureUrl: `${config.cancelUrl}?order=${encodeURIComponent(orderId)}`,
        method,
      },
      { ...deps, idempotencyKey: reservation.attempt },
    );
  } catch (error) {
    await releaseCheckoutReservation(paymentRef, reservation.attempt, deps);
    logger.error('xendit invoice failed', { orderId, message: error.message });
    return res
      .status(error.name === 'AbortError' ? 504 : 502)
      .json({ error: 'gateway error' });
  }

  // Record the pending payment server-side too, so a client that closes the
  // app mid-checkout still has a record the webhook can settle.
  try {
    await paymentRef.set(
      {
        ...buildPaymentRecord({ orderId, order, split, deps, session }),
        checkoutAttempt: null,
        checkoutReservedAt: null,
      },
      { merge: true },
    );
  } catch (error) {
    // The invoice exists at Xendit but we could not record it. Failing the
    // request is right: the webhook can still self-heal from the order if the
    // buyer goes on to pay.
    logger.error('payment record write failed', { orderId, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }

  await writeAudit(deps, {
    actorId: uid,
    action: 'payment.checkout_started',
    targetType: 'order',
    targetId: orderId,
    details: {
      amount: split.gross,
      commission: split.commission,
      offerId: order.offerId ?? null,
      method,
    },
  });
  return res.json({ checkoutUrl: session.checkoutUrl, reference: session.id });
}

// A second tap, browser retry, or duplicate HTTP request must not create a
// second invoice. Reserve the payment document before the external call; a
// short lease keeps a crashed request recoverable without allowing a race.
const CHECKOUT_RESERVATION_MS = 65 * 1000;

async function reserveCheckout(paymentRef, { orderId, order, split, deps }) {
  const { db } = deps;
  let result;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(paymentRef);
    const existing = snap.exists ? snap.data() || {} : {};
    if (existing.status === 'paid') {
      result = { state: 'paid' };
      return;
    }
    const reservedAt = toMillis(existing.checkoutReservedAt);
    if (
      existing.status === 'creating' &&
      reservedAt &&
      deps.now().getTime() - reservedAt < CHECKOUT_RESERVATION_MS
    ) {
      result = { state: 'creating' };
      return;
    }
    const attempt = crypto.randomUUID();
    const stamp = deps.serverTimestamp ? deps.serverTimestamp() : new Date();
    tx.set(
      paymentRef,
      {
        ...buildPaymentRecord({ orderId, order, split, deps, session: { id: null } }),
        status: 'creating',
        checkoutAttempt: attempt,
        // This needs a readable value in the next transaction; a server
        // timestamp is still pending at that point and cannot express a lease.
        checkoutReservedAt: deps.now(),
        updatedAt: stamp,
      },
      { merge: true },
    );
    result = { state: 'reserved', attempt };
  });
  return result;
}

async function releaseCheckoutReservation(paymentRef, attempt, deps) {
  try {
    await deps.db.runTransaction(async (tx) => {
      const snap = await tx.get(paymentRef);
      if (!snap.exists) return;
      const record = snap.data() || {};
      if (record.status !== 'creating' || record.checkoutAttempt !== attempt) return;
      tx.update(paymentRef, {
        status: 'failed',
        checkoutAttempt: null,
        checkoutReservedAt: null,
        updatedAt: deps.serverTimestamp ? deps.serverTimestamp() : new Date(),
      });
    });
  } catch (error) {
    deps.logger.error('checkout reservation release failed', { message: error.message });
  }
}

/**
 * The pending record's invoice, when the gateway still shows it open. Null
 * when there is none, it has lapsed, or the gateway could not be asked (a
 * fresh invoice is then the safer path than a stuck buyer).
 */
async function reusableInvoice(existingSnap, deps) {
  const { logger } = deps;
  if (!existingSnap.exists) return null;
  const record = existingSnap.data() || {};
  const invoiceId = record.gatewayReference;
  if (record.status !== 'pending' || typeof invoiceId !== 'string' || !invoiceId) return null;
  let invoice;
  try {
    invoice = await xendit.getInvoice(invoiceId, deps);
  } catch (error) {
    logger.error('open invoice lookup failed', { invoiceId, message: error.message });
    return null;
  }
  const status = String(invoice?.status || '').toUpperCase();
  const url = invoice?.invoice_url;
  if (status !== 'PENDING' || typeof url !== 'string' || !url.startsWith('https://')) return null;
  return { id: invoiceId, checkoutUrl: url };
}

/**
 * Asks the gateway about one order's payment right now, on behalf of either
 * party, and applies the answer through the same path the callback uses.
 *
 * A buyer who comes back from GCash sees "paid" at once instead of waiting
 * for a callback that may be misconfigured, delayed, or lost; the
 * half-hourly reconciler remains the safety net. Nothing here trusts the
 * caller: the gateway's own record of the invoice is what settles it.
 */
async function handlePaymentSync(req, res, deps) {
  const { db, logger } = deps;
  const orderId = req.params.orderId;
  if (!DOC_ID.test(orderId)) return res.status(400).json({ error: 'invalid order id' });

  let snap;
  try {
    snap = await db.doc(`payments/${orderId}`).get();
  } catch (error) {
    logger.error('payment lookup failed', { orderId, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  if (!snap.exists) return res.status(404).json({ error: 'no payment' });
  const payment = snap.data() || {};
  if (!(payment.participantIds || []).includes(req.uid)) {
    return res.status(403).json({ error: 'forbidden' });
  }
  if (payment.status !== 'pending' || payment.method !== GATEWAY_METHOD) {
    return res.json({ status: payment.status, outcome: 'unchanged' });
  }
  const invoiceId = payment.gatewayReference;
  if (typeof invoiceId !== 'string' || !invoiceId) {
    return res.json({ status: payment.status, outcome: 'no-invoice' });
  }
  // One gateway lookup per record per SYNC_COOLDOWN_MS: a tap-happy buyer
  // (or a script) cannot turn the app into a request generator against
  // Xendit. The record is re-read for the answer either way.
  const lastSync = toMillis(payment.lastSyncAt);
  if (lastSync && deps.now().getTime() - lastSync < SYNC_COOLDOWN_MS) {
    return res.json({ status: payment.status, outcome: 'throttled' });
  }
  try {
    await snap.ref.update({ lastSyncAt: deps.serverTimestamp ? deps.serverTimestamp() : new Date() });
  } catch (error) {
    logger.error('sync stamp failed', { orderId, message: error.message });
  }
  return syncInvoice(res, deps, invoiceId, `payments/${orderId}`);
}

const SYNC_COOLDOWN_MS = 10 * 1000;

/**
 * Money that arrived for an order that was already paid goes straight back.
 * Refunded at the gateway on our own reference (idempotent), recorded in the
 * audit log, and handed to staff if the gateway refuses, so a double charge
 * is never silently kept.
 */
async function refundDuplicate(deps, { orderId, invoiceId, paidPesos }) {
  const { logger } = deps;
  let refunded = false;
  try {
    await xendit.createRefund(
      { invoiceId, amountPesos: paidPesos, reason: 'DUPLICATE', referenceId: `dup-${invoiceId}` },
      deps,
    );
    refunded = true;
  } catch (error) {
    logger.error('duplicate refund failed', { orderId, invoiceId, message: error.message });
  }
  await writeAudit(deps, {
    actorId: 'system',
    action: ACTIONS.paymentDuplicate,
    targetType: 'payment',
    targetId: orderId,
    details: { invoiceId, amount: paidPesos, refunded },
  });
  if (!refunded) {
    await notifyAdminsSafe(deps, {
      type: 'admin.refund_attention',
      title: 'A second payment for an order needs a manual refund',
      orderId,
    });
  }
}

/** Milliseconds from a Firestore Timestamp, a Date, or nothing. */
function toMillis(value) {
  if (!value) return 0;
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return 0;
}

/** The same check for the caller's own pending Pro checkouts. */
async function handleProSync(req, res, deps) {
  const { db, logger } = deps;
  let pending;
  try {
    pending = await db
      .collection('subscriptions')
      .where('uid', '==', req.uid)
      .where('status', '==', 'pending')
      .limit(5)
      .get();
  } catch (error) {
    logger.error('subscription lookup failed', { uid: req.uid, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  const outcomes = [];
  for (const doc of pending.docs) {
    const invoiceId = doc.data().gatewayReference;
    if (typeof invoiceId !== 'string' || !invoiceId) continue;
    let invoice;
    try {
      invoice = await xendit.getInvoice(invoiceId, deps);
    } catch (error) {
      logger.error('pro sync lookup failed', { invoiceId, message: error.message });
      return res.status(error.name === 'AbortError' ? 504 : 502).json({ error: 'gateway error' });
    }
    outcomes.push(await applyInvoice(deps, invoice));
  }
  return res.json({ checked: outcomes.length, outcomes });
}

async function syncInvoice(res, deps, invoiceId, recordPath) {
  const { db, logger } = deps;
  let invoice;
  try {
    invoice = await xendit.getInvoice(invoiceId, deps);
  } catch (error) {
    logger.error('payment sync lookup failed', { invoiceId, message: error.message });
    return res.status(error.name === 'AbortError' ? 504 : 502).json({ error: 'gateway error' });
  }
  const outcome = await applyInvoice(deps, invoice);
  let status = 'pending';
  try {
    const after = await db.doc(recordPath).get();
    status = after.exists ? after.data().status : 'pending';
  } catch (error) {
    logger.error('payment re-read failed', { recordPath, message: error.message });
  }
  return res.json({ status, outcome, gatewayStatus: String(invoice?.status || '') });
}

/**
 * The payment method the buyer chose in the app: one of the names in
 * `xendit.PAYMENT_METHODS`, `any` when absent. Null for anything else, so a
 * typo does not silently become "every channel".
 */
function paymentMethodOf(body) {
  const method = body?.method;
  if (method === undefined || method === null) return 'any';
  if (typeof method !== 'string' || !(method in xendit.PAYMENT_METHODS)) return null;
  return method;
}

/**
 * Why this order costs what it says. Either the listing is fixed-price with
 * direct ordering allowed and the price is the listed one, or the order was
 * created from an offer that was spent on exactly this order and carries the
 * same price and parties. Anything else is refused before checkout.
 */
async function pricingMismatch(db, orderId, order) {
  if (order.offerId) {
    if (!DOC_ID.test(String(order.offerId))) return 'order references an invalid offer';
    const offerSnap = await db.doc(`offers/${order.offerId}`).get();
    if (!offerSnap.exists) return 'order references a missing offer';
    const offer = offerSnap.data() || {};
    if (offer.status !== 'ordered' || offer.orderId !== orderId) {
      return 'offer was not spent on this order';
    }
    if (
      offer.price !== order.price ||
      offer.clientId !== order.clientId ||
      offer.freelancerId !== order.freelancerId ||
      offer.serviceId !== order.serviceId
    ) {
      return 'order does not match its offer';
    }
    return null;
  }
  if (typeof order.serviceId !== 'string' || !DOC_ID.test(order.serviceId)) {
    return 'order references an invalid service';
  }
  const serviceSnap = await db.doc(`services/${order.serviceId}`).get();
  if (!serviceSnap.exists) return 'order references a missing service';
  const service = serviceSnap.data() || {};
  if ((service.pricingMode || 'fixed') !== 'fixed' || service.requiresContact === true) {
    return 'this listing is ordered through an offer, not directly';
  }
  if (service.sellerId !== order.freelancerId) return 'order freelancer is not the seller';
  if (service.startingPrice !== order.price) return 'order price differs from the listing';
  return null;
}

function buildPaymentRecord({ orderId, order, split, deps, session }) {
  const stamp = deps.serverTimestamp ? deps.serverTimestamp() : new Date();
  return {
    orderId,
    clientId: order.clientId,
    freelancerId: order.freelancerId,
    participantIds: [order.clientId, order.freelancerId].sort(),
    amount: split.gross,
    currency: SUPPORTED_CURRENCY,
    commission: split.commission,
    netToFreelancer: split.netToFreelancer,
    status: 'pending',
    method: GATEWAY_METHOD,
    verified: false,
    gatewayReference: session?.id ?? null,
    createdAt: stamp,
    updatedAt: stamp,
  };
}

// --- Pro checkout ----------------------------------------------------------

/** A prepaid Pro month for the caller. No recurring mandate: e-wallet
 *  recurring is poorly supported, and a forgotten subscription is a complaint. */
async function handleProCheckout(req, res, deps) {
  const { db, config, logger } = deps;
  const uid = req.uid;

  let userSnap;
  try {
    userSnap = await db.doc(`users/${uid}`).get();
  } catch (error) {
    logger.error('user lookup failed', { uid, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }
  if (!userSnap.exists) return res.status(404).json({ error: 'no such user' });
  const method = paymentMethodOf(req.body);
  if (!method) return res.status(400).json({ error: 'unknown payment method' });

  let session;
  try {
    session = await xendit.createInvoice(
      {
        // The nonce keeps every Pro invoice's external_id unique; the uid in
        // it is what the callback trusts.
        externalId: proExternalId(uid, deps.now().getTime().toString(36)),
        amountPesos: PRO_PRICE,
        description: 'Pro subscription (30 days)',
        payerEmail: req.email,
        metadata: { kind: 'pro', uid },
        successUrl: `${config.successUrl}?pro=1`,
        failureUrl: `${config.cancelUrl}?pro=1`,
        method,
      },
      deps,
    );
  } catch (error) {
    logger.error('xendit pro invoice failed', { uid, message: error.message });
    return res
      .status(error.name === 'AbortError' ? 504 : 502)
      .json({ error: 'gateway error' });
  }

  const stamp = deps.serverTimestamp ? deps.serverTimestamp() : new Date();
  try {
    await db.doc(`subscriptions/${session.id}`).set({
      uid,
      amount: PRO_PRICE,
      currency: SUPPORTED_CURRENCY,
      status: 'pending',
      gatewayReference: session.id,
      createdAt: stamp,
      updatedAt: stamp,
    });
  } catch (error) {
    logger.error('subscription record write failed', { uid, message: error.message });
    return res.status(503).json({ error: 'storage unavailable' });
  }

  return res.json({ checkoutUrl: session.checkoutUrl, reference: session.id });
}

// --- featured, payouts, verification --------------------------------------

async function handleFeatured(req, res, deps) {
  const featured = req.body?.featured;
  if (typeof featured !== 'boolean') {
    return res.status(400).json({ error: 'featured must be a boolean' });
  }
  const result = await ledger.setFeatured(deps, {
    uid: req.uid,
    serviceId: req.params.id,
    featured,
    now: deps.now(),
  });
  return res.json({ result });
}

async function handlePayoutRequest(req, res, deps) {
  const result = await ledger.requestPayout(deps, req.uid);
  await writeAudit(deps, {
    actorId: req.uid,
    action: ACTIONS.payoutRequested,
    targetType: 'payout',
    targetId: result.payoutId,
    details: { amount: result.amount },
  });
  if (!deps.config.payoutsAutomated) return res.json({ ...result, delivery: 'manual' });

  // Hand it to the gateway at once. Whatever happens next is recorded on
  // the payout and the student is told; the request itself already
  // succeeded.
  const submitted = await ledger.submitPayout(deps, result.payoutId);
  await writeAudit(deps, {
    actorId: 'xendit',
    action: 'payout.submitted',
    targetType: 'payout',
    targetId: result.payoutId,
    details: { outcome: submitted.outcome, code: submitted.code ?? null, gatewayPayoutId: submitted.gatewayPayoutId ?? null },
  });
  if (submitted.outcome === 'refused') {
    await safeNotify(deps, req.uid, {
      type: 'payout.rejected',
      title: 'Your payout could not be sent; the money is back in your balance',
    });
  }
  return res.json({ ...result, delivery: submitted.outcome });
}

/** Staff (re)send a waiting payout through the gateway. */
async function handlePayoutSubmit(req, res, deps) {
  if (!(await requirePermission(req, res, deps, 'payouts.settle'))) return undefined;
  if (!DOC_ID.test(req.params.id)) {
    return res.status(400).json({ error: 'valid payout id required' });
  }
  const submitted = await ledger.submitPayout(deps, req.params.id);
  await writeAudit(deps, {
    actorId: req.uid,
    action: 'payout.submitted',
    targetType: 'payout',
    targetId: req.params.id,
    details: { outcome: submitted.outcome, code: submitted.code ?? null },
  });
  if (submitted.outcome === 'refused') {
    const snap = await deps.db.doc(`payouts/${req.params.id}`).get();
    await safeNotify(deps, snap.data().uid, {
      type: 'payout.rejected',
      title: 'Your payout could not be sent; the money is back in your balance',
    });
  }
  return res.status(submitted.outcome === 'unreachable' ? 502 : 200).json(submitted);
}

async function handlePayoutSettle(req, res, deps) {
  if (!(await requirePermission(req, res, deps, 'payouts.settle'))) return undefined;
  const reference = String(req.body?.reference ?? '').trim();
  if (!reference || reference.length > 120) {
    return res.status(400).json({ error: 'reference required (1-120 chars)' });
  }
  if (!DOC_ID.test(req.params.id)) {
    return res.status(400).json({ error: 'valid payout id required' });
  }
  const uid = await ledger.settlePayout(deps, {
    payoutId: req.params.id,
    adminUid: req.uid,
    reference,
  });
  await safeNotify(deps, uid, { type: 'payout.paid', title: 'Your payout was sent' });
  await writeAudit(deps, {
    actorId: req.uid,
    action: ACTIONS.payoutSettled,
    targetType: 'payout',
    targetId: req.params.id,
    details: { uid, reference },
  });
  return res.json({ result: 'paid' });
}

async function handlePayoutReject(req, res, deps) {
  if (!(await requirePermission(req, res, deps, 'payouts.settle'))) return undefined;
  const note = String(req.body?.note ?? '').trim();
  if (note.length < 10 || note.length > 500) {
    return res.status(400).json({ error: 'note required (10-500 chars)' });
  }
  if (!DOC_ID.test(req.params.id)) {
    return res.status(400).json({ error: 'valid payout id required' });
  }
  const uid = await ledger.rejectPayout(deps, {
    payoutId: req.params.id,
    adminUid: req.uid,
    note,
  });
  await safeNotify(deps, uid, {
    type: 'payout.rejected',
    title: 'Your payout was returned to your balance',
  });
  await writeAudit(deps, {
    actorId: req.uid,
    action: ACTIONS.payoutRejected,
    targetType: 'payout',
    targetId: req.params.id,
    details: { uid, note },
  });
  return res.json({ result: 'rejected' });
}

async function handleVerification(req, res, deps) {
  const access = await requirePermission(req, res, deps, 'verification.decide');
  if (!access) return undefined;
  // A staff member can review other students when granted the permission, but
  // cannot manufacture their own verification by targeting their own uid.
  // The single main admin is the explicitly authorised exception.
  if (req.uid === req.params.uid && access.role !== 'admin') {
    return res.status(403).json({ error: 'staff cannot approve their own verification' });
  }
  const approve = req.body?.approve;
  if (typeof approve !== 'boolean') {
    return res.status(400).json({ error: 'approve must be a boolean' });
  }
  const note = String(req.body?.note ?? '').trim().slice(0, 500);
  const result = await ledger.decideVerification(deps, {
    adminUid: req.uid,
    uid: req.params.uid,
    approve,
    note,
  });
  await safeNotify(deps, req.params.uid, {
    type: approve ? 'verification.approved' : 'verification.rejected',
    title: approve
      ? 'Your student identity is verified'
      : 'Your verification request was not approved',
  });
  await writeAudit(deps, {
    actorId: req.uid,
    action: ACTIONS.verificationDecided,
    targetType: 'user',
    targetId: req.params.uid,
    details: { approve, note },
  });
  return res.json({ result });
}

/** Staff retry a refund the gateway refused earlier. */
async function handleRefundRetry(req, res, deps) {
  if (!(await requirePermission(req, res, deps, 'refunds.handle'))) return undefined;
  if (!DOC_ID.test(req.params.orderId)) {
    return res.status(400).json({ error: 'valid orderId required' });
  }
  const outcome = await ledger.refundHeldPayment(
    {
      ...deps,
      refundImpl: ({ paymentId, amount, reason, referenceId }) =>
        xendit.createRefund(
          { invoiceId: paymentId, amountPesos: amount, reason, referenceId },
          deps,
        ),
    },
    req.params.orderId,
    'requested_by_customer',
  );
  if (outcome === 'refunded') {
    const snap = await deps.db.doc(`payments/${req.params.orderId}`).get();
    await safeNotify(deps, snap.data().clientId, {
      type: 'payment.refunded',
      title: 'Your payment was refunded',
      orderId: req.params.orderId,
    });
    await writeAudit(deps, {
      actorId: req.uid,
      action: ACTIONS.paymentRefunded,
      targetType: 'payment',
      targetId: req.params.orderId,
      details: { via: 'gateway-retry' },
    });
  }
  return res.status(outcome === 'refunded' ? 200 : 409).json({ result: outcome });
}

/** Staff record a refund made outside the gateway. */
async function handleRefundManual(req, res, deps) {
  if (!(await requirePermission(req, res, deps, 'refunds.handle'))) return undefined;
  const reference = String(req.body?.reference ?? '').trim();
  if (!reference || reference.length > 120) {
    return res.status(400).json({ error: 'reference required (1-120 chars)' });
  }
  const clientId = await ledger.markRefundedManually(deps, {
    orderId: req.params.orderId,
    adminUid: req.uid,
    reference,
  });
  await safeNotify(deps, clientId, {
    type: 'payment.refunded',
    title: 'Your payment was refunded',
    orderId: req.params.orderId,
  });
  await writeAudit(deps, {
    actorId: req.uid,
    action: ACTIONS.paymentRefunded,
    targetType: 'payment',
    targetId: req.params.orderId,
    details: { via: 'manual', reference },
  });
  return res.json({ result: 'refunded' });
}

/** Staff pass on a chargeback the card network took from the platform. */
async function handleChargeback(req, res, deps) {
  if (!(await requirePermission(req, res, deps, 'refunds.handle'))) return undefined;
  const reason = String(req.body?.reason ?? '').trim();
  if (reason.length < 10 || reason.length > 500) {
    return res.status(400).json({ error: 'reason required (10-500 chars)' });
  }
  const outcome = await ledger.recordChargeback(deps, {
    orderId: req.params.orderId,
    adminUid: req.uid,
    reason,
  });
  await safeNotify(deps, outcome.freelancerId, {
    type: 'payment.charged_back',
    title: outcome.owed > 0
      ? `A payment was charged back; ₱${outcome.owed} will be deducted from your next releases`
      : 'A payment was charged back and deducted from your balance',
    orderId: req.params.orderId,
  });
  await writeAudit(deps, {
    actorId: req.uid,
    action: ACTIONS.paymentChargedBack,
    targetType: 'payment',
    targetId: req.params.orderId,
    details: { ...outcome, reason },
  });
  return res.json({ result: 'recorded', ...outcome });
}

/** A notification failure must never undo the action it reports. */
async function safeNotify(deps, uid, payload) {
  try {
    await writeNotification(deps, uid, payload);
  } catch (error) {
    deps.logger.error('notification write failed', { uid, message: error.message });
  }
}

// --- webhook ---------------------------------------------------------------

/** Our reference on a gateway invoice. `external_id` is ours to choose and
 *  is echoed on every callback, so it carries what settlement needs. */
const orderExternalId = (orderId) => `order:${orderId}`;
const proExternalId = (uid, nonce) => `pro:${uid}:${nonce}`;

function parseExternalId(value) {
  if (typeof value !== 'string') return null;
  const [kind, ...rest] = value.split(':');
  if (kind === 'order' && rest.length === 1 && DOC_ID.test(rest[0])) {
    return { kind, orderId: rest[0] };
  }
  if (kind === 'pro' && rest.length === 2 && DOC_ID.test(rest[0])) {
    return { kind, uid: rest[0], nonce: rest[1] };
  }
  return null;
}

/**
 * The callback body as an object, wherever the runtime left it.
 *
 * Under `firebase-functions` the request has already been read: the wrapper
 * parses a JSON body into `req.body` and keeps the bytes in `req.rawBody`,
 * so the `express.raw` on the route sees a consumed stream and leaves
 * `req.body` as that object. Calling `toString()` on it gave
 * "[object Object]", and every real delivery from Xendit was answered
 * "malformed payload" while the tests, which run the bare Express app,
 * stayed green. The bare app still hands over a Buffer, which is parsed.
 */
function webhookPayload(req) {
  const raw = Buffer.isBuffer(req.rawBody)
    ? req.rawBody
    : Buffer.isBuffer(req.body)
    ? req.body
    : null;
  if (raw) return JSON.parse(raw.toString('utf8'));
  if (req.body && typeof req.body === 'object' && Object.keys(req.body).length) {
    return req.body;
  }
  throw new Error('no body');
}

/**
 * Settles money once Xendit says it arrived.
 *
 * This is the only path that may write `verified: true`. It runs with the
 * Admin SDK, which bypasses security rules — which is precisely why those
 * rules can forbid every client from touching that field.
 *
 * Status codes matter here: Xendit retries on non-2xx, so anything permanent
 * must answer 200 or the delivery is retried forever.
 */
async function handleWebhook(req, res, deps) {
  const { config, logger } = deps;

  if (!xendit.verifyCallback(req.get('x-callback-token'), config)) {
    // Without this check anyone who learns the URL could mark orders paid.
    return res.status(401).send('invalid callback token');
  }

  let invoice;
  try {
    invoice = webhookPayload(req);
  } catch {
    return res.status(400).send('malformed payload');
  }

  // Payout callbacks arrive on the same URL wrapped in an event envelope
  // (`{event: 'payout.succeeded', data: {...}}`); invoices arrive flat.
  if (typeof invoice?.event === 'string' && invoice.event.startsWith('payout.')) {
    return handlePayoutCallback(res, deps, invoice);
  }

  let outcome;
  try {
    outcome = await applyInvoice(deps, invoice);
  } catch (error) {
    logger.error('webhook settlement failed', { message: error.message });
    // Transient (contention, Firestore down): 500 asks Xendit to retry.
    return res.status(500).send('settlement failed');
  }
  // Every other outcome is permanent; 200 stops the retry loop.
  return res.status(200).send(outcome);
}

/** A retry will not change these; the reconciler counts them as done. */
const FINAL_INVOICE_OUTCOMES = new Set([
  'settled', 'settled-recovered', 'already-settled', 'duplicate', 'activated', 'already',
  'expired', 'underpaid', 'no-order', 'invalid-order', 'invalid-record',
]);

/** Pending checkouts asked about per reconciliation run. */
const RECONCILE_BATCH = 50;

/**
 * Applies what the gateway says about an invoice to our records. Shared by
 * the callback and the reconciler, so a payment settles the same way
 * whichever of them saw it first. Throws only when the write itself failed
 * and should be retried; every other case returns an outcome string.
 */
async function applyInvoice(deps, invoice) {
  const { db, logger } = deps;
  const ref = parseExternalId(invoice?.external_id);
  if (!ref) {
    logger.error('invoice without a usable external_id');
    return 'no reference';
  }

  const status = String(invoice?.status || '').toUpperCase();
  const invoiceId = typeof invoice?.id === 'string' ? invoice.id : null;

  if (status === 'EXPIRED') {
    // The student never paid. A pending record is closed so the order screen
    // stops saying "waiting for the gateway"; anything else is left alone.
    if (ref.kind === 'order') await expirePendingPayment(deps, ref.orderId);
    return 'expired';
  }
  if (!xendit.PAID_STATUSES.includes(status)) {
    // Still open at the gateway, or in a state we do not act on.
    return 'ignored';
  }

  // Xendit amounts are whole pesos. `paid_amount` is what actually arrived;
  // `amount` is what was asked. Never settle for less than the order.
  const paidPesos = Number(invoice.paid_amount ?? invoice.amount);
  if (!Number.isInteger(paidPesos) || paidPesos <= 0) {
    logger.error('invoice with no usable amount', { externalId: invoice.external_id });
    return 'no amount';
  }

  if (ref.kind === 'pro') {
    return settlePro(deps, { uid: ref.uid, paidPesos, invoiceId });
  }

  const { orderId } = ref;
  // The refund path needs the invoice id, which is also the checkout
  // reference we stored, so one field serves both.
  const gatewayPaymentId = invoiceId;
  const sessionId = invoiceId;
  const paymentRef = db.doc(`payments/${orderId}`);
  const stamp = deps.serverTimestamp ? deps.serverTimestamp() : new Date();

  let settledPayment = null;
  const outcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(paymentRef);

    // No record: the checkout write may have failed, or this is a session
    // created out of band. Rebuild from the order rather than dropping a
    // real payment on the floor.
    if (!snap.exists) {
      const orderSnap = await tx.get(db.doc(`orders/${orderId}`));
      if (!orderSnap.exists) return 'no-order';
      const order = orderSnap.data() || {};
      if (validateOrderForPayment(order)) return 'invalid-order';
      const split = breakdownOf(order.price);
      if (paidPesos < split.gross) return 'underpaid';
      const record = {
        ...buildPaymentRecord({ orderId, order, split, deps, session: { id: sessionId } }),
        status: 'paid',
        verified: true,
        holdStatus: 'held',
        gatewayPaymentId,
        paidAt: stamp,
      };
      tx.set(paymentRef, record);
      settledPayment = record;
      return 'settled-recovered';
    }

    const payment = snap.data() || {};

    // Idempotency: Xendit retries callbacks, and a double-settle would
    // double-count commission in the earnings figures. The same invoice
    // again is a retry; a *different* paid invoice is a second charge.
    if (payment.status === 'paid') {
      return payment.gatewayPaymentId && payment.gatewayPaymentId !== invoiceId
        ? 'duplicate'
        : 'already-settled';
    }

    // A record with no usable amount cannot be checked against the payment,
    // and a comparison against `undefined` would silently pass.
    if (!Number.isInteger(payment.amount) || payment.amount < policy.MIN_PRICE) {
      return 'invalid-record';
    }

    // Never settle for less than the order is worth.
    if (paidPesos < payment.amount) {
      tx.update(paymentRef, { status: 'failed', updatedAt: stamp });
      return 'underpaid';
    }

    tx.update(paymentRef, {
      status: 'paid',
      verified: true,
      holdStatus: 'held',
      gatewayPaymentId,
      gatewayReference: sessionId ?? payment.gatewayReference ?? null,
      paidAt: stamp,
      updatedAt: stamp,
    });
    settledPayment = payment;
    return 'settled';
  });

  if (outcome === 'settled' || outcome === 'settled-recovered') {
    // Both parties learn the money is in. The freelancer's copy is what
    // unlocks "Start working" in their head; the app unlocks it from the
    // payment document itself.
    const title = 'Payment received and held by the platform';
    await safeNotify(deps, settledPayment.freelancerId, { type: 'payment.confirmed', title, orderId });
    await safeNotify(deps, settledPayment.clientId, { type: 'payment.confirmed', title, orderId });
    await writeAudit(deps, {
      actorId: settledPayment.clientId,
      action: ACTIONS.paymentSettled,
      targetType: 'payment',
      targetId: orderId,
      details: { amount: settledPayment.amount, gatewayPaymentId, outcome },
    });
  } else if (outcome === 'duplicate') {
    await refundDuplicate(deps, { orderId, invoiceId, paidPesos });
  } else {
    logger.error('invoice not settled', { orderId, outcome });
  }
  return outcome;
}

/**
 * Asks the gateway about every checkout that has sat `pending` for longer
 * than a payer needs, and applies the answer. Xendit retries callbacks, but
 * not forever, and a function that was down for an afternoon would
 * otherwise leave a paid order saying "awaiting payment" until staff
 * noticed. Runs on a schedule; each invoice is applied exactly as a callback
 * would be, so the two paths cannot disagree.
 */
async function reconcilePendingPayments(deps, now) {
  const { db, logger } = deps;
  const cutoff = new Date(now.getTime() - policy.RECONCILE_PENDING_AFTER_MINUTES * 60 * 1000);
  const [payments, subscriptions] = await Promise.all([
    db
      .collection('payments')
      .where('status', '==', 'pending')
      .where('method', '==', GATEWAY_METHOD)
      .where('createdAt', '<=', cutoff)
      .limit(RECONCILE_BATCH)
      .get(),
    db
      .collection('subscriptions')
      .where('status', '==', 'pending')
      .where('createdAt', '<=', cutoff)
      .limit(RECONCILE_BATCH)
      .get(),
  ]);
  const counts = { checked: 0, applied: 0, unreachable: 0 };
  for (const doc of [...payments.docs, ...subscriptions.docs]) {
    const invoiceId = doc.data().gatewayReference;
    if (typeof invoiceId !== 'string' || !invoiceId) continue;
    counts.checked += 1;
    let invoice;
    try {
      invoice = await xendit.getInvoice(invoiceId, deps);
    } catch (error) {
      // The gateway, not the record, is the problem; the next run asks again.
      counts.unreachable += 1;
      logger.error('reconcile lookup failed', { invoiceId, message: error.message });
      continue;
    }
    try {
      const outcome = await applyInvoice(deps, invoice);
      if (FINAL_INVOICE_OUTCOMES.has(outcome)) counts.applied += 1;
    } catch (error) {
      logger.error('reconcile apply failed', { invoiceId, message: error.message });
    }
  }
  return counts;
}

/**
 * Xendit's verdict on a payout it accepted. `reference_id` is our payout id.
 * Every outcome answers 200: none of them is fixed by a retry.
 */
async function handlePayoutCallback(res, deps, envelope) {
  const { logger } = deps;
  const data = envelope.data || {};
  const payoutId = data.reference_id;
  if (typeof payoutId !== 'string' || !DOC_ID.test(payoutId)) {
    logger.error('payout callback without a usable reference');
    return res.status(200).send('no reference');
  }
  const outcome = xendit.PAYOUT_OUTCOMES[String(data.status || '').toUpperCase()];
  if (!outcome) return res.status(200).send('ignored');

  let result;
  try {
    result = await ledger.completeGatewayPayout(deps, {
      payoutId,
      gatewayPayoutId: typeof data.id === 'string' ? data.id : null,
      outcome,
      failureCode: data.failure_code ?? null,
    });
  } catch (error) {
    logger.error('payout callback failed', { payoutId, message: error.message });
    return res.status(500).send('settlement failed');
  }

  const snap = await deps.db.doc(`payouts/${payoutId}`).get();
  const uid = snap.exists ? snap.data().uid : null;
  if (result === 'paid' && uid) {
    await safeNotify(deps, uid, { type: 'payout.paid', title: 'Your payout was sent' });
  } else if (result === 'returned' && uid) {
    await safeNotify(deps, uid, {
      type: 'payout.rejected',
      title: 'Your payout failed and is back in your balance',
    });
  } else if (result === 'reversed') {
    await notifyAdminsSafe(deps, {
      type: 'admin.payout_requested',
      title: 'A payout was reversed by the gateway and needs a decision',
    });
  }
  // A repeat delivery or an unknown payout changes nothing and is not an
  // event worth recording.
  const action = { paid: ACTIONS.payoutSettled, returned: ACTIONS.payoutRejected, reversed: 'payout.reversed' }[result];
  if (action) {
    await writeAudit(deps, {
      actorId: 'xendit',
      action,
      targetType: 'payout',
      targetId: payoutId,
      details: { outcome, failureCode: data.failure_code ?? null, gatewayPayoutId: data.id ?? null },
    });
  }
  return res.status(200).send(result);
}

async function notifyAdminsSafe(deps, payload) {
  try {
    const { notifyAdmins } = require('./push');
    await notifyAdmins(deps, payload);
  } catch (error) {
    deps.logger.error('admin notify failed', { message: error.message });
  }
}

async function settlePro(deps, { uid, paidPesos, invoiceId }) {
  const { logger } = deps;
  if (paidPesos < PRO_PRICE) {
    logger.error('pro invoice underpaid', { uid, paidPesos });
    return 'underpaid';
  }
  if (typeof invoiceId !== 'string' || !invoiceId) return 'no invoice';
  const outcome = await ledger.activatePro(deps, {
    uid,
    sessionId: invoiceId,
    amount: PRO_PRICE,
    now: deps.now(),
  });
  if (outcome === 'activated') {
    await safeNotify(deps, uid, { type: 'pro.activated', title: 'Pro is active for 30 days' });
    await writeAudit(deps, {
      actorId: uid,
      action: ACTIONS.proActivated,
      targetType: 'user',
      targetId: uid,
      details: { invoiceId, amount: PRO_PRICE },
    });
  }
  return outcome;
}

/** An invoice the student never paid: close the pending record, once. */
async function expirePendingPayment(deps, orderId) {
  const { db, logger } = deps;
  try {
    await db.runTransaction(async (tx) => {
      const ref = db.doc(`payments/${orderId}`);
      const snap = await tx.get(ref);
      if (!snap.exists || snap.data().status !== 'pending') return;
      tx.update(ref, {
        status: 'failed',
        updatedAt: deps.serverTimestamp ? deps.serverTimestamp() : new Date(),
      });
    });
  } catch (error) {
    logger.error('expire failed', { orderId, message: error.message });
  }
}

module.exports = {
  createApp,
  configFromEnv,
  reconcilePendingPayments,
  breakdownOf,
  validateOrderForPayment,
  verifyCallback: xendit.verifyCallback,
  parseExternalId,
  DOC_ID,
};

// Standalone hosts (Render, Railway, Fly.io, a container) start a listener.
// Cloud Functions instead imports the app from index.js.
if (require.main === module) {
  const admin = require('firebase-admin');
  if (!admin.apps.length) admin.initializeApp();

  const app = createApp({
    db: admin.firestore(),
    verifyIdToken: (token) => admin.auth().verifyIdToken(token),
    serverTimestamp: () => admin.firestore.FieldValue.serverTimestamp(),
    increment: (n) => admin.firestore.FieldValue.increment(n),
  });

  // A crash here would otherwise take the process down mid-payment.
  process.on('unhandledRejection', (reason) =>
    console.error('unhandled rejection', reason),
  );

  const port = Number(process.env.PORT) || 8080;
  const server = app.listen(port, () =>
    console.log(`backend listening on ${port}`),
  );
  // Hosts send SIGTERM on deploy; finish in-flight requests first.
  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => server.close(() => process.exit(0)));
  }
}
