/**
 * Smoke tests for the payments backend.
 *
 * Runs on Node's built-in test runner against a real HTTP listener, with the
 * three outside-world dependencies substituted: Firestore, Firebase token
 * verification, and the HTTP call to Xendit. That keeps the suite offline
 * and deterministic while still exercising the actual Express routing, body
 * parsing, signature check, and status codes.
 *
 *   npm test
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const { publicIdentityKey } = require('./public-identity');
const crypto = require('node:crypto');

const {
  createApp,
  breakdownOf,
  validateOrderForPayment,
  reconcilePendingPayments,
} = require('./server');
const { fakeDb, increment, silentLogger } = require('./test-helpers');

// --- test doubles ----------------------------------------------------------

const CONFIG = {
  secretKey: 'xnd_development_fake',
  callbackToken: 'cb_token_fake',
  successUrl: 'https://app.example.com/paid',
  cancelUrl: 'https://app.example.com/cancelled',
  liveMode: false,
  allowedOrigins: ['https://app.example.com'],
};

/** A decoded token for a verified UM student account. */
const UM = (uid) => ({
  uid,
  email: `a.${uid.replace(/[^a-z]/g, '')}.123456@umindanao.edu.ph`,
  email_verified: true,
});

const PAYABLE_ORDER = {
  serviceId: 'svc1',
  clientId: 'buyer-uid',
  freelancerId: 'seller-uid',
  serviceTitle: 'Calculus tutoring',
  price: 500,
  currency: 'PHP',
  status: 'accepted',
};

/** The listing PAYABLE_ORDER was placed against: fixed, direct, ₱500. */
const FIXED_LISTING = {
  sellerId: 'seller-uid',
  startingPrice: 500,
  status: 'published',
  pricingMode: 'fixed',
  requiresContact: false,
};

test('dispute chat snapshot requires dispute permission and a disputed order', async (t) => {
  const db = fakeDb({ 'orders/order1': { ...PAYABLE_ORDER, status: 'disputed', disputeReason: 'Wrong delivery' } });
  const app = await boot({ db });
  t.after(app.close);
  assert.equal((await app.post('/admin/orders/order1/chat-snapshot', {}, null)).status, 401);
  assert.equal((await app.post('/admin/orders/order1/chat-snapshot', {})).status, 403);
  await db.doc('admins/buyer-uid').set({ role: 'staff', permissions: ['orders.manage'] });
  assert.equal((await app.post('/admin/orders/order1/chat-snapshot', {})).status, 403);
  assert.equal(db.docs.has('disputeChatSnapshots/order1'), false);
  await db.doc('admins/buyer-uid').set({ role: 'staff', permissions: ['disputes.resolve'] });
  await db.doc('orders/order2').set(PAYABLE_ORDER);
  assert.equal((await app.post('/admin/orders/order2/chat-snapshot', {})).status, 409);
  assert.equal((await app.post('/admin/orders/missing/chat-snapshot', {})).status, 404);
  assert.equal((await app.post('/admin/orders/order1/chat-snapshot', { afterId: '../other' })).status, 400);
});

test('chat evidence is copied once, freezes later messages, and pages without gaps', async (t) => {
  const records = {
    'admins/buyer-uid': { role: 'staff', permissions: ['disputes.resolve'] },
    'orders/order1': { ...PAYABLE_ORDER, status: 'disputed', disputeReason: 'Wrong delivery' },
    'conversations/unrelated/messages/secret': { senderId: 'other', text: 'private', sentAt: new Date('2026-05-01') },
  };
  for (let index = 0; index < 55; index++) records[`conversations/buyer-uid_seller-uid/messages/m${String(index).padStart(2, '0')}`] = {
    senderId: index % 2 ? 'seller-uid' : 'buyer-uid', text: `Message ${index}`,
    sentAt: new Date(Date.UTC(2026, 4, 31, 0, index)),
  };
  records['conversations/buyer-uid_seller-uid/messages/m54'].serviceId = 'debug-code';
  records['conversations/buyer-uid_seller-uid/messages/m54'].serviceTitle = 'Debug my code';
  const db = fakeDb(records);
  const app = await boot({ db });
  t.after(app.close);
  const first = await (await app.post('/admin/orders/order1/chat-snapshot', {})).json();
  assert.equal(first.messages.length, 50);
  assert.equal(first.messages[0].id, 'm54');
  assert.ok(first.nextCursor);
  await db.doc('conversations/buyer-uid_seller-uid/messages/new-backdated').set({
    senderId: 'buyer-uid', text: 'Added after snapshot', sentAt: new Date('2026-05-30'),
  });
  await db.doc('conversations/buyer-uid_seller-uid/messages/m54').update({ text: 'Changed later by backend' });
  const second = await (await app.post('/admin/orders/order1/chat-snapshot', { afterId: first.nextCursor })).json();
  assert.equal(second.capturedAt, first.capturedAt);
  assert.equal(second.messages.length, 5);
  assert.equal(second.nextCursor, null);
  assert.equal(new Set([...first.messages, ...second.messages].map((message) => message.id)).size, 55);
  assert.ok([...first.messages, ...second.messages].every((message) => message.id !== 'secret' && message.id !== 'new-backdated'));
  const repeated = await (await app.post('/admin/orders/order1/chat-snapshot', {})).json();
  assert.equal(repeated.messages[0].text, 'Message 54');
  assert.equal(repeated.messages[0].serviceId, 'debug-code');
  assert.equal(repeated.messages[0].serviceTitle, 'Debug my code');
  assert.equal(db.docs.get('disputeChatSnapshots/order1').status, 'ready');
  assert.equal(db.docs.get('disputeChatSnapshots/order1').messageCount, 55);
});

function gatewayOk() {
  return async () => ({
    ok: true,
    json: async () => ({
      id: 'inv_test_123',
      invoice_url: 'https://checkout.xendit.co/web/inv_test_123',
      status: 'PENDING',
    }),
  });
}

/** Boots the app on an ephemeral port and returns a fetch helper. */
async function boot(overrides = {}) {
  const db = overrides.db || fakeDb({
    'orders/order1': { ...PAYABLE_ORDER },
    'services/svc1': { ...FIXED_LISTING },
  });
  const app = createApp({
    db,
    verifyIdToken: overrides.verifyIdToken || (async (t) =>
      t === 'good-token' ? UM('buyer-uid') : Promise.reject(new Error('bad'))),
    fetchImpl: overrides.fetchImpl || gatewayOk(),
    config: { ...CONFIG, ...(overrides.config || {}) },
    serverTimestamp: () => 'TS',
    increment,
    now: () => new Date('2026-06-01T00:00:00Z'),
    logger: silentLogger,
  });

  const server = await new Promise((resolve) => {
    const s = app.listen(0, () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;

  return {
    db,
    base,
    close: () => new Promise((r) => server.close(r)),
    post: (path, body, token = 'good-token') =>
      fetch(`${base}${path}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body ?? {}),
      }),
    checkout: (body, headers = {}) =>
      fetch(`${base}/checkout`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer good-token',
          ...headers,
        },
        body: typeof body === 'string' ? body : JSON.stringify(body),
      }),
    webhook: (payload, { token = CONFIG.callbackToken } = {}) => {
      const raw = typeof payload === 'string' ? payload : JSON.stringify(payload);
      return fetch(`${base}/webhook`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token === null ? {} : { 'x-callback-token': token }),
        },
        body: raw,
      });
    },
  };
}

/** An invoice callback from Xendit. Amounts are whole pesos. */
const paidEvent = (orderId, pesos, { status = 'PAID', id = 'inv_evt_1' } = {}) => ({
  id,
  external_id: orderId === undefined ? undefined : `order:${orderId}`,
  status,
  amount: pesos,
  paid_amount: pesos,
  currency: 'PHP',
  payment_method: 'EWALLET',
  payment_channel: 'GCASH',
});

// --- pure logic ------------------------------------------------------------

test('commission split matches the Dart implementation', () => {
  assert.deepEqual(breakdownOf(500), { gross: 500, commission: 25, netToFreelancer: 475 });
  assert.equal(breakdownOf(1750).commission, 88);
  assert.equal(breakdownOf(1749).commission, 87);
  assert.equal(breakdownOf(175).commission, 9);
  assert.equal(breakdownOf(150).netToFreelancer, 142);
  assert.deepEqual(breakdownOf(10), { gross: 10, commission: 1, netToFreelancer: 9 });
  for (let gross = 0; gross <= 2000; gross++) {
    const s = breakdownOf(gross);
    assert.equal(s.commission + s.netToFreelancer, gross);
    assert.ok(s.commission >= 0 && s.netToFreelancer >= 0);
  }
});

test('order validation rejects what would reach the gateway as NaN', () => {
  assert.equal(validateOrderForPayment(PAYABLE_ORDER), null);
  assert.match(validateOrderForPayment({ ...PAYABLE_ORDER, price: undefined }), /integer/);
  assert.match(validateOrderForPayment({ ...PAYABLE_ORDER, price: 1.5 }), /integer/);
  assert.match(validateOrderForPayment({ ...PAYABLE_ORDER, price: 0 }), /range/);
  assert.match(validateOrderForPayment({ ...PAYABLE_ORDER, price: 9e9 }), /range/);
  assert.match(validateOrderForPayment({ ...PAYABLE_ORDER, currency: 'USD' }), /currency/);
  assert.match(validateOrderForPayment({ ...PAYABLE_ORDER, clientId: '' }), /client/);
});

// --- health + routing ------------------------------------------------------

test('health probe reports the key mode', async (t) => {
  const app = await boot();
  t.after(app.close);
  const res = await fetch(`${app.base}/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'ok', mode: 'test', payouts: 'manual' });
});

test('people search returns bounded public fields and excludes suspended users', async (t) => {
  const db = fakeDb({
    'publicUserSearch/u1': {
      displayName: 'Alex Rivera', nameLower: 'alex rivera', program: 'BS Computer Science',
      programLower: 'bs computer science', department: 'College of Computing Education',
      departmentLower: 'college of computing education', departmentCodeLower: 'cce',
      photoUrl: 'https://example.test/p.png',
      publicRole: 'Moderator', createdAt: new Date('2026-01-01T00:00:00Z'), suspended: false,
      identityKey: 'same-school-account',
      email: 'private@umindanao.edu.ph', studentId: '123456',
    },
    'publicUserSearch/u3': {
      displayName: 'Alex Rivera', nameLower: 'alex rivera', program: 'BS Computer Science',
      programLower: 'bs computer science', department: 'College of Computing Education',
      departmentLower: 'college of computing education', departmentCodeLower: 'cce',
      identityKey: 'same-school-account', suspended: false,
    },
    'publicUserSearch/u4': {
      displayName: 'Alex Rivera', nameLower: 'alex rivera', program: 'BS Computer Science',
      programLower: 'bs computer science', department: 'College of Computing Education',
      departmentLower: 'college of computing education', departmentCodeLower: 'cce',
      identityKey: 'different-school-account', suspended: false,
    },
    'publicUserSearch/u2': {
      displayName: 'Alex Hidden', nameLower: 'alex hidden', program: '', programLower: '',
      department: '', departmentLower: '', suspended: true,
    },
  });
  const app = await boot({ db });
  t.after(app.close);

  const response = await app.post('/users/search', { query: 'alex' });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.users.length, 2);
  assert.equal(body.users[0].uid, 'u1');
  assert.equal(body.users[0].publicRole, 'Moderator');
  assert.equal('email' in body.users[0], false);
  assert.equal('studentId' in body.users[0], false);
});

test('public identity keys merge email aliases by student id without merging namesakes', () => {
  const first = publicIdentityKey({ studentId: '123456', email: 'first@umindanao.edu.ph' }, 'u1');
  const alias = publicIdentityKey({ studentId: '123456', email: 'second@umindanao.edu.ph' }, 'u2');
  const namesake = publicIdentityKey({ studentId: '654321', email: 'third@umindanao.edu.ph' }, 'u3');
  assert.equal(first, alias);
  assert.notEqual(first, namesake);
});

test('people search validates its query and requires a verified school token', async (t) => {
  const app = await boot();
  t.after(app.close);
  assert.equal((await app.post('/users/search', { query: 'a' })).status, 400);
  assert.equal((await app.post('/users/search', { query: 'alex' }, null)).status, 401);
});

test('people search limits repeated lookups by one account', async (t) => {
  const app = await boot();
  t.after(app.close);
  for (let i = 0; i < 30; i++) {
    assert.equal((await app.post('/users/search', { query: `alex${i}` })).status, 200);
  }
  assert.equal((await app.post('/users/search', { query: 'alex31' })).status, 429);
});

test('unknown routes 404 as json, not an html stack trace', async (t) => {
  const app = await boot();
  t.after(app.close);
  const res = await fetch(`${app.base}/nope`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'not found' });
});

test('browser preflight is answered for an allowed origin only', async (t) => {
  const app = await boot();
  t.after(app.close);

  const allowed = await fetch(`${app.base}/checkout`, {
    method: 'OPTIONS',
    headers: { Origin: 'https://app.example.com' },
  });
  assert.equal(allowed.status, 204);
  assert.equal(
    allowed.headers.get('access-control-allow-origin'),
    'https://app.example.com',
  );

  const denied = await fetch(`${app.base}/checkout`, {
    method: 'OPTIONS',
    headers: { Origin: 'https://evil.example.com' },
  });
  assert.equal(denied.headers.get('access-control-allow-origin'), null);
});

// --- /checkout -------------------------------------------------------------

test('checkout happy path creates a session and a pending record', async (t) => {
  const app = await boot();
  t.after(app.close);

  const res = await app.checkout({ orderId: 'order1' });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), {
    checkoutUrl: 'https://checkout.xendit.co/web/inv_test_123',
    reference: 'inv_test_123',
  });

  const record = app.db.docs.get('payments/order1');
  assert.equal(record.status, 'pending');
  assert.equal(record.verified, false, 'only the webhook may verify');
  assert.equal(record.amount, 500);
  assert.equal(record.commission, 25);
  assert.equal(record.netToFreelancer, 475);
  assert.deepEqual(record.participantIds, ['buyer-uid', 'seller-uid']);
});

test('concurrent checkout requests reserve one invoice before calling the gateway', async (t) => {
  let calls = 0;
  let markStarted;
  let releaseFirst;
  const started = new Promise((resolve) => { markStarted = resolve; });
  const firstMayFinish = new Promise((resolve) => { releaseFirst = resolve; });
  const app = await boot({
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) {
        markStarted();
        await firstMayFinish;
      }
      return {
        ok: true,
        json: async () => ({
          id: 'inv_one',
          invoice_url: 'https://checkout.xendit.co/web/inv_one',
          status: 'PENDING',
        }),
      };
    },
  });
  t.after(app.close);

  const first = app.checkout({ orderId: 'order1' });
  await started;
  const second = await app.checkout({ orderId: 'order1' });
  assert.equal(second.status, 409);
  assert.equal(calls, 1, 'the second request must not mint another invoice');

  releaseFirst();
  assert.equal((await first).status, 200);
  assert.equal(calls, 1);
});

test('checkout rejects a missing or unverifiable token', async (t) => {
  const app = await boot();
  t.after(app.close);

  const none = await fetch(`${app.base}/checkout`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ orderId: 'order1' }),
  });
  assert.equal(none.status, 401);

  const bad = await app.checkout(
    { orderId: 'order1' },
    { Authorization: 'Bearer forged' },
  );
  assert.equal(bad.status, 401);
});

test('a token from outside the university domain is refused everywhere', async (t) => {
  const app = await boot({
    verifyIdToken: async (tk) => {
      if (tk === 'gmail') return { uid: 'x', email: 'someone@gmail.com', email_verified: true };
      if (tk === 'unverified') return { uid: 'y', email: 'a.b.123456@umindanao.edu.ph', email_verified: false };
      if (tk === 'good-token') return UM('buyer-uid');
      throw new Error('bad');
    },
  });
  t.after(app.close);
  for (const tk of ['gmail', 'unverified']) {
    assert.equal((await app.post('/checkout', { orderId: 'order1' }, tk)).status, 403);
    assert.equal((await app.post('/pro/checkout', {}, tk)).status, 403);
    assert.equal((await app.post('/wallet/payout', {}, tk)).status, 403);
  }
  assert.equal((await app.post('/checkout', { orderId: 'order1' })).status, 200);
});

test('checkout refuses a path-traversing order id', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'orders/a/evil/b': { ...PAYABLE_ORDER, clientId: 'buyer-uid' },
    }),
  });
  t.after(app.close);

  // `orders/${'a/evil/b'}` would address a different document entirely.
  const res = await app.checkout({ orderId: 'a/evil/b' });
  assert.equal(res.status, 400);
  assert.equal(app.db.docs.has('payments/a/evil/b'), false);
});

test('checkout validates the request body', async (t) => {
  const app = await boot();
  t.after(app.close);

  assert.equal((await app.checkout({})).status, 400);
  assert.equal((await app.checkout({ orderId: 42 })).status, 400);
  assert.equal((await app.checkout('{not json')).status, 400);
  assert.equal((await app.checkout({ orderId: 'order1', method: 'bitcoin' })).status, 400);
});

test('checkout passes the chosen payment method to the gateway', async (t) => {
  const calls = [];
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'users/buyer-uid': { displayName: 'Buyer' },
    }),
    fetchImpl: async (url, init) => {
      calls.push(JSON.parse(init.body));
      return gatewayOk()();
    },
  });
  t.after(app.close);

  assert.equal((await app.checkout({ orderId: 'order1', method: 'gcash' })).status, 200);
  assert.deepEqual(calls[0].payment_methods, ['GCASH']);
  assert.equal((await app.checkout({ orderId: 'order1', method: 'card' })).status, 200);
  assert.deepEqual(calls[1].payment_methods, ['CREDIT_CARD']);
  // No choice: every channel, so an old client keeps working.
  assert.equal((await app.checkout({ orderId: 'order1' })).status, 200);
  assert.ok(calls[2].payment_methods.length > 3);
  assert.equal((await app.post('/pro/checkout', { method: 'maya' })).status, 200);
  assert.deepEqual(calls[3].payment_methods, ['PAYMAYA']);
});

test('a local development origin is allowed through CORS on any port', async (t) => {
  const app = await boot();
  t.after(app.close);

  const res = await fetch(`${app.base}/checkout`, {
    method: 'OPTIONS',
    headers: { Origin: 'http://localhost:53112' },
  });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), 'http://localhost:53112');
  const other = await fetch(`${app.base}/checkout`, {
    method: 'OPTIONS',
    headers: { Origin: 'http://evil.example' },
  });
  assert.equal(other.headers.get('access-control-allow-origin'), null);
});

test('only the buyer of a live order may pay', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER, clientId: 'someone-else' },
      'orders/pending1': { ...PAYABLE_ORDER, status: 'pending' },
      'orders/done1': { ...PAYABLE_ORDER, status: 'completed' },
    }),
  });
  t.after(app.close);

  assert.equal((await app.checkout({ orderId: 'order1' })).status, 403);
  assert.equal((await app.checkout({ orderId: 'pending1' })).status, 409);
  assert.equal((await app.checkout({ orderId: 'done1' })).status, 409);
  assert.equal((await app.checkout({ orderId: 'ghost' })).status, 404);
});

test('a malformed order is refused before it reaches the gateway', async (t) => {
  let called = false;
  const app = await boot({
    db: fakeDb({ 'orders/bad1': { ...PAYABLE_ORDER, price: 'free' } }),
    fetchImpl: async () => {
      called = true;
      throw new Error('should not be called');
    },
  });
  t.after(app.close);

  const res = await app.checkout({ orderId: 'bad1' });
  assert.equal(res.status, 422);
  assert.equal(called, false, 'gateway must not see a NaN amount');
});

test('an already-settled order cannot be charged twice', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': { status: 'paid', amount: 500 },
    }),
  });
  t.after(app.close);

  const res = await app.checkout({ orderId: 'order1' });
  assert.equal(res.status, 409);
});

test('gateway failures map to 502, and timeouts to 504', async (t) => {
  const failing = await boot({
    fetchImpl: async () => ({ ok: false, status: 500, json: async () => ({}) }),
  });
  t.after(failing.close);
  assert.equal((await failing.checkout({ orderId: 'order1' })).status, 502);

  const malformed = await boot({
    fetchImpl: async () => ({ ok: true, json: async () => ({ data: {} }) }),
  });
  t.after(malformed.close);
  assert.equal((await malformed.checkout({ orderId: 'order1' })).status, 502);

  const timingOut = await boot({
    fetchImpl: async () => {
      const error = new Error('aborted');
      error.name = 'AbortError';
      throw error;
    },
  });
  t.after(timingOut.close);
  assert.equal((await timingOut.checkout({ orderId: 'order1' })).status, 504);
});

test('a non-https checkout url is refused', async (t) => {
  const app = await boot({
    fetchImpl: async () => ({
      ok: true,
      json: async () => ({ id: 'inv_1', invoice_url: 'http://insecure' }),
    }),
  });
  t.after(app.close);
  assert.equal((await app.checkout({ orderId: 'order1' })).status, 502);
});

test('storage failures surface as 503 rather than a hung request', async (t) => {
  const app = await boot();
  t.after(app.close);
  app.db.failNext = 'orders/order1';
  const res = await app.checkout({ orderId: 'order1' });
  assert.equal(res.status, 503);
});

test('an oversized body is rejected', async (t) => {
  const app = await boot();
  t.after(app.close);
  const res = await app.checkout({ orderId: 'order1', pad: 'x'.repeat(70000) });
  assert.equal(res.status, 413);
});

// --- /webhook --------------------------------------------------------------

test('webhook settles a pending payment exactly once', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': { status: 'pending', amount: 500, verified: false },
    }),
  });
  t.after(app.close);

  const first = await app.webhook(paidEvent('order1', 500));
  assert.equal(first.status, 200);
  assert.equal(await first.text(), 'settled');

  const record = app.db.docs.get('payments/order1');
  assert.equal(record.status, 'paid');
  assert.equal(record.verified, true, 'the webhook is the only verifier');
  assert.equal(record.holdStatus, 'held', 'money is held, not handed over');
  assert.equal(record.gatewayPaymentId, 'inv_evt_1', 'the invoice id, needed for a refund');
  // Both parties are told the money landed.
  const inbox = [...app.db.docs.keys()].filter((k) => k.includes('/notifications/'));
  assert.equal(inbox.length, 2);

  // Retries are expected; a second settle would double-count commission.
  const second = await app.webhook(paidEvent('order1', 500));
  assert.equal(second.status, 200);
  assert.equal(await second.text(), 'already-settled');
});

test('the reconciler settles a stale pending checkout the callback missed', async () => {
  const now = new Date('2026-06-01T12:00:00Z');
  const hourAgo = new Date(now.getTime() - 60 * 60 * 1000);
  const db = fakeDb({
    'orders/order1': { ...PAYABLE_ORDER },
    'services/svc1': { ...FIXED_LISTING },
    // Paid at the gateway an hour ago; our record never heard.
    'payments/order1': {
      status: 'pending', method: 'xendit', amount: 500, verified: false,
      gatewayReference: 'inv_lost', createdAt: hourAgo,
    },
    // Opened a minute ago: the student may still be typing a GCash PIN.
    'payments/order2': {
      status: 'pending', method: 'xendit', amount: 500, verified: false,
      gatewayReference: 'inv_fresh', createdAt: new Date(now.getTime() - 60 * 1000),
    },
    // Never paid and the invoice lapsed: closed so the order stops waiting.
    'payments/order3': {
      status: 'pending', method: 'xendit', amount: 500, verified: false,
      gatewayReference: 'inv_dead', createdAt: hourAgo,
    },
    // A manual settlement has no invoice to ask about.
    'payments/order4': {
      status: 'pending', method: 'manual', amount: 500, verified: false, createdAt: hourAgo,
    },
  });
  const asked = [];
  const fetchImpl = async (url, init) => {
    asked.push(`${init.method} ${url}`);
    const id = url.split('/').pop();
    const body = id === 'inv_lost'
      ? paidEvent('order1', 500, { id })
      : { id, external_id: 'order:order3', status: 'EXPIRED', amount: 500 };
    return { ok: true, json: async () => body };
  };

  const counts = await reconcilePendingPayments(
    { db, fetchImpl, config: CONFIG, serverTimestamp: () => 'TS', increment, now: () => now, logger: silentLogger },
    now,
  );

  assert.deepEqual(asked, [
    'GET https://api.xendit.co/v2/invoices/inv_lost',
    'GET https://api.xendit.co/v2/invoices/inv_dead',
  ], 'only stale gateway checkouts are looked up');
  assert.deepEqual(counts, { checked: 2, applied: 2, unreachable: 0 });
  const settled = db.docs.get('payments/order1');
  assert.equal(settled.status, 'paid');
  assert.equal(settled.verified, true, 'the reconciler settles the same way the callback does');
  assert.equal(settled.holdStatus, 'held');
  assert.equal(db.docs.get('payments/order2').status, 'pending', 'a fresh checkout is left alone');
  assert.equal(db.docs.get('payments/order3').status, 'failed', 'an expired invoice closes the record');
  assert.equal(db.docs.get('payments/order4').status, 'pending');
});

test('a party can sync a pending payment with the gateway on demand', async (t) => {
  const asked = [];
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': {
        status: 'pending', method: 'xendit', amount: 500, verified: false,
        participantIds: ['buyer-uid', 'seller-uid'],
        gatewayReference: 'inv_lost', createdAt: new Date('2026-06-01T00:00:00Z'),
      },
      'payments/order9': {
        status: 'pending', method: 'xendit', amount: 500, verified: false,
        participantIds: ['someone-else', 'seller-uid'],
        gatewayReference: 'inv_other', createdAt: new Date('2026-06-01T00:00:00Z'),
      },
    }),
    fetchImpl: async (url, init) => {
      asked.push(`${init.method} ${url}`);
      return { ok: true, json: async () => paidEvent('order1', 500, { id: 'inv_lost' }) };
    },
  });
  t.after(app.close);

  // Not a party: refused before the gateway is asked.
  assert.equal((await app.post('/payments/order9/sync', {})).status, 403);
  assert.equal((await app.post('/payments/nope/sync', {})).status, 404);
  assert.deepEqual(asked, []);

  const res = await app.post('/payments/order1/sync', {});
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, 'paid');
  assert.equal(body.outcome, 'settled');
  assert.deepEqual(asked, ['GET https://api.xendit.co/v2/invoices/inv_lost']);
  assert.equal(app.db.docs.get('payments/order1').holdStatus, 'held');

  // Already settled: answered from the record, no gateway call.
  const again = await app.post('/payments/order1/sync', {});
  assert.deepEqual(await again.json(), { status: 'paid', outcome: 'unchanged' });
  assert.equal(asked.length, 1);
});

test('reopening a checkout hands back the invoice that is still open', async (t) => {
  const asked = [];
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': {
        status: 'pending', method: 'xendit', amount: 500, verified: false,
        participantIds: ['buyer-uid', 'seller-uid'], gatewayReference: 'inv_open',
      },
    }),
    fetchImpl: async (url, init) => {
      asked.push(`${init.method} ${url}`);
      if (init.method === 'GET') {
        return { ok: true, json: async () => ({ id: 'inv_open', external_id: 'order:order1', status: 'PENDING', invoice_url: 'https://checkout.xendit.co/web/inv_open' }) };
      }
      return gatewayOk()();
    },
  });
  t.after(app.close);

  const res = await app.checkout({ orderId: 'order1' });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), {
    checkoutUrl: 'https://checkout.xendit.co/web/inv_open',
    reference: 'inv_open',
    reused: true,
  });
  assert.deepEqual(asked, ['GET https://api.xendit.co/v2/invoices/inv_open'], 'no second invoice is created');
});

test('an expired invoice is replaced by a fresh checkout', async (t) => {
  const asked = [];
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': {
        status: 'pending', method: 'xendit', amount: 500, verified: false,
        participantIds: ['buyer-uid', 'seller-uid'], gatewayReference: 'inv_old',
      },
    }),
    fetchImpl: async (url, init) => {
      asked.push(`${init.method} ${url}`);
      if (init.method === 'GET') {
        return { ok: true, json: async () => ({ id: 'inv_old', external_id: 'order:order1', status: 'EXPIRED' }) };
      }
      return gatewayOk()();
    },
  });
  t.after(app.close);

  const res = await app.checkout({ orderId: 'order1' });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).reference, 'inv_test_123');
  assert.equal(asked.length, 2);
  assert.equal(app.db.docs.get('payments/order1').gatewayReference, 'inv_test_123');
});

test('a second paid invoice for a settled order is refunded, not kept', async (t) => {
  const calls = [];
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': {
        status: 'paid', verified: true, holdStatus: 'held', amount: 500,
        clientId: 'buyer-uid', freelancerId: 'seller-uid',
        participantIds: ['buyer-uid', 'seller-uid'], gatewayPaymentId: 'inv_first',
      },
    }),
    fetchImpl: async (url, init) => {
      calls.push({ url, body: JSON.parse(init.body) });
      return { ok: true, json: async () => ({ id: 'rfd_1', status: 'SUCCEEDED' }) };
    },
  });
  t.after(app.close);

  // The same invoice again is a retry: nothing happens.
  const retry = await app.webhook(paidEvent('order1', 500, { id: 'inv_first' }));
  assert.equal(await retry.text(), 'already-settled');
  assert.equal(calls.length, 0);

  // A different invoice that also got paid is a double charge.
  const dup = await app.webhook(paidEvent('order1', 500, { id: 'inv_second' }));
  assert.equal(dup.status, 200);
  assert.equal(await dup.text(), 'duplicate');
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.endsWith('/refunds'));
  assert.equal(calls[0].body.invoice_id, 'inv_second');
  assert.equal(calls[0].body.reference_id, 'dup-inv_second');
  const audit = [...app.db.docs.entries()].find(([k, v]) => k.startsWith('auditLog/') && v.action === 'payment.duplicate');
  assert.ok(audit, 'the double charge is on the record');
  assert.equal(audit[1].details.refunded, true);
  // The original settlement is untouched.
  assert.equal(app.db.docs.get('payments/order1').gatewayPaymentId, 'inv_first');
});

test('sync asks the gateway at most once per cooldown per record', async (t) => {
  const asked = [];
  const db = fakeDb({
    'orders/order1': { ...PAYABLE_ORDER },
    'services/svc1': { ...FIXED_LISTING },
    'payments/order1': {
      status: 'pending', method: 'xendit', amount: 500, verified: false,
      participantIds: ['buyer-uid', 'seller-uid'],
      gatewayReference: 'inv_open', createdAt: new Date('2026-06-01T00:00:00Z'),
    },
  });
  const app = await boot({
    db,
    fetchImpl: async (url, init) => {
      asked.push(`${init.method} ${url}`);
      // Still open at the gateway.
      return { ok: true, json: async () => ({ id: 'inv_open', external_id: 'order:order1', status: 'PENDING', amount: 500 }) };
    },
  });
  t.after(app.close);
  const first = await app.post('/payments/order1/sync', {});
  assert.deepEqual(await first.json(), { status: 'pending', outcome: 'ignored', gatewayStatus: 'PENDING' });
  assert.equal(asked.length, 1);

  // Stamp the record as just synced and ask again: no second lookup.
  app.db.docs.set('payments/order1', { ...app.db.docs.get('payments/order1'), lastSyncAt: new Date('2026-06-01T00:00:00Z') });
  const second = await app.post('/payments/order1/sync', {});
  assert.deepEqual(await second.json(), { status: 'pending', outcome: 'throttled' });
  assert.equal(asked.length, 1);

  // Once the cooldown has passed the gateway is asked again.
  app.db.docs.set('payments/order1', { ...app.db.docs.get('payments/order1'), lastSyncAt: new Date('2026-05-31T23:59:00Z') });
  const third = await app.post('/payments/order1/sync', {});
  assert.equal((await third.json()).outcome, 'ignored');
  assert.equal(asked.length, 2);
});

test('the reconciler leaves a record alone when the gateway cannot be reached', async () => {
  const now = new Date('2026-06-01T12:00:00Z');
  const db = fakeDb({
    'payments/order1': {
      status: 'pending', method: 'xendit', amount: 500, verified: false,
      gatewayReference: 'inv_lost', createdAt: new Date(now.getTime() - 60 * 60 * 1000),
    },
  });
  const counts = await reconcilePendingPayments(
    {
      db,
      fetchImpl: async () => ({ ok: false, status: 503, json: async () => ({}) }),
      config: CONFIG, serverTimestamp: () => 'TS', increment, now: () => now, logger: silentLogger,
    },
    now,
  );
  assert.deepEqual(counts, { checked: 1, applied: 0, unreachable: 1 });
  assert.equal(db.docs.get('payments/order1').status, 'pending', 'the next run asks again');
});

test('webhook reads a body the functions runtime already parsed', async (t) => {
  // firebase-functions parses a JSON body before the handler runs and keeps
  // the bytes on req.rawBody; the route's own raw parser then sees a consumed
  // stream. Every real Xendit delivery was answered "malformed payload" while
  // the bare-Express tests stayed green. Mount the app behind a wrapper that
  // does what the runtime does.
  const express = require('express');
  const db = fakeDb({
    'orders/order1': { ...PAYABLE_ORDER },
    'services/svc1': { ...FIXED_LISTING },
    'payments/order1': { status: 'pending', amount: 500, verified: false },
  });
  const app = createApp({
    db,
    verifyIdToken: async () => { throw new Error('unused'); },
    fetchImpl: gatewayOk(),
    config: CONFIG,
    serverTimestamp: () => 'TS',
    increment,
    now: () => new Date('2026-06-01T00:00:00Z'),
    logger: silentLogger,
  });
  const wrapped = express();
  wrapped.use(express.json({ verify: (req, _res, buf) => { req.rawBody = buf; } }));
  wrapped.use(app);
  const server = await new Promise((resolve) => { const s = wrapped.listen(0, () => resolve(s)); });
  t.after(() => new Promise((r) => server.close(r)));
  const url = `http://127.0.0.1:${server.address().port}/webhook`;
  const headers = { 'Content-Type': 'application/json', 'x-callback-token': CONFIG.callbackToken };

  const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(paidEvent('order1', 500)) });
  assert.equal(res.status, 200);
  assert.equal(await res.text(), 'settled');
  assert.equal(db.docs.get('payments/order1').status, 'paid');

  // An empty delivery is still refused rather than crashing.
  const empty = await fetch(url, { method: 'POST', headers, body: '' });
  assert.equal(empty.status, 400);
});

test('webhook rejects a missing or wrong callback token', async (t) => {
  const app = await boot({
    db: fakeDb({ 'payments/order1': { status: 'pending', amount: 500 } }),
  });
  t.after(app.close);

  const missing = await app.webhook(paidEvent('order1', 500), { token: null });
  assert.equal(missing.status, 401);

  const wrong = await app.webhook(paidEvent('order1', 500), { token: 'cb_token_fakE' });
  assert.equal(wrong.status, 401);

  // A prefix of the real token: same start, different length.
  const shorter = await app.webhook(paidEvent('order1', 500), { token: 'cb_token_fak' });
  assert.equal(shorter.status, 401);

  assert.equal(app.db.docs.get('payments/order1').status, 'pending');
});

test('an expired invoice closes a pending record and nothing else', async (t) => {
  const app = await boot({
    db: fakeDb({
      'payments/order1': { status: 'pending', amount: 500 },
      'payments/order2': { status: 'paid', amount: 500, holdStatus: 'held' },
    }),
  });
  t.after(app.close);

  const pending = await app.webhook(paidEvent('order1', 500, { status: 'EXPIRED' }));
  assert.equal(await pending.text(), 'expired');
  assert.equal(app.db.docs.get('payments/order1').status, 'failed');

  const paid = await app.webhook(paidEvent('order2', 500, { status: 'EXPIRED' }));
  assert.equal(paid.status, 200);
  assert.equal(app.db.docs.get('payments/order2').status, 'paid', 'a settled record is left alone');
});

test('SETTLED after PAID is the same money, settled once', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'payments/order1': { status: 'pending', amount: 500 },
    }),
  });
  t.after(app.close);
  assert.equal(await (await app.webhook(paidEvent('order1', 500))).text(), 'settled');
  const settled = await app.webhook(paidEvent('order1', 500, { status: 'SETTLED' }));
  assert.equal(await settled.text(), 'already-settled');
});

test('underpayment marks the record failed and is not retried', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'payments/order1': { status: 'pending', amount: 500 },
    }),
  });
  t.after(app.close);

  const res = await app.webhook(paidEvent('order1', 1)); // ₱1 for a ₱500 order
  assert.equal(res.status, 200, '200 stops Xendit retrying a permanent problem');
  assert.equal(await res.text(), 'underpaid');
  assert.equal(app.db.docs.get('payments/order1').status, 'failed');
});

test('a payment record with no usable amount is not settled', async (t) => {
  const app = await boot({
    db: fakeDb({ 'payments/order1': { status: 'pending' } }),
  });
  t.after(app.close);

  // `undefined * 100` is NaN, and every comparison against NaN is false — the
  // underpayment guard would silently pass.
  const res = await app.webhook(paidEvent('order1', 1));
  assert.equal(await res.text(), 'invalid-record');
  assert.notEqual(app.db.docs.get('payments/order1').status, 'paid');
});

test('a missing payment record is rebuilt from the order', async (t) => {
  const app = await boot({
    db: fakeDb({ 'orders/order1': { ...PAYABLE_ORDER }, 'services/svc1': { ...FIXED_LISTING } }),
  });
  t.after(app.close);

  const res = await app.webhook(paidEvent('order1', 500));
  assert.equal(await res.text(), 'settled-recovered');

  const record = app.db.docs.get('payments/order1');
  assert.equal(record.status, 'paid');
  assert.equal(record.verified, true);
  assert.equal(record.commission, 25);
});

test('irrelevant events and unusable references are acknowledged, not retried', async (t) => {
  const app = await boot();
  t.after(app.close);

  const other = await app.webhook(paidEvent('order1', 500, { status: 'PENDING' }));
  assert.equal(other.status, 200);
  assert.equal(await other.text(), 'ignored');

  const foreign = await app.webhook({ id: 'x', external_id: 'somebody-elses-ref', status: 'PAID', paid_amount: 500 });
  assert.equal(foreign.status, 200);
  assert.equal(await foreign.text(), 'no reference');

  const noRef = await app.webhook(paidEvent(undefined, 500));
  assert.equal(noRef.status, 200);

  const traversal = await app.webhook(paidEvent('a/evil/b', 500));
  assert.equal(traversal.status, 200);
  assert.equal(app.db.docs.has('payments/a/evil/b'), false);

  const ghost = await app.webhook(paidEvent('ghost', 500));
  assert.equal(await ghost.text(), 'no-order');
});

test('malformed webhook json is a 400, not a crash', async (t) => {
  const app = await boot();
  t.after(app.close);
  const res = await app.webhook('{not json');
  assert.equal(res.status, 400);
});

test('a transient storage failure asks Xendit to retry', async (t) => {
  const db = fakeDb({ 'payments/order1': { status: 'pending', amount: 500 } });
  db.runTransaction = async () => {
    throw new Error('firestore unavailable');
  };
  const app = await boot({ db });
  t.after(app.close);

  const res = await app.webhook(paidEvent('order1', 500));
  assert.equal(res.status, 500, '5xx is what triggers a Xendit retry');
});

// --- Pro subscription ------------------------------------------------------

const proEvent = (uid, pesos, invoiceId = 'inv_pro_1') => ({
  id: invoiceId,
  external_id: `pro:${uid}:n0nce`,
  status: 'PAID',
  amount: pesos,
  paid_amount: pesos,
  currency: 'PHP',
});

test('pro checkout creates a session for the caller only', async (t) => {
  const app = await boot({
    db: fakeDb({ 'users/buyer-uid': { displayName: 'Buyer' } }),
  });
  t.after(app.close);

  const res = await app.post('/pro/checkout', {});
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.reference, 'inv_test_123');
  const record = app.db.docs.get('subscriptions/inv_test_123');
  assert.equal(record.uid, 'buyer-uid');
  assert.equal(record.amount, 99);
  assert.equal(record.status, 'pending');

  const anon = await app.post('/pro/checkout', {}, null);
  assert.equal(anon.status, 401);
});

test('pro webhook activates 30 days and extends an unexpired period', async (t) => {
  const app = await boot({
    db: fakeDb({
      'users/seller-uid': { displayName: 'Seller' },
      'subscriptions/inv_pro_1': { uid: 'seller-uid', status: 'pending' },
    }),
  });
  t.after(app.close);

  const first = await app.webhook(proEvent('seller-uid', 99));
  assert.equal(await first.text(), 'activated');
  const user = app.db.docs.get('users/seller-uid');
  assert.equal(user.proUntil.toISOString(), '2026-07-01T00:00:00.000Z');
  assert.equal(app.db.docs.get('subscriptions/inv_pro_1').status, 'paid');

  // Retry of the same session is a no-op.
  const again = await app.webhook(proEvent('seller-uid', 99));
  assert.equal(await again.text(), 'already');

  // A second month bought early stacks on the end, not on today.
  const second = await app.webhook(proEvent('seller-uid', 99, 'inv_pro_2'));
  assert.equal(await second.text(), 'activated');
  assert.equal(
    app.db.docs.get('users/seller-uid').proUntil.toISOString(),
    '2026-07-31T00:00:00.000Z',
  );
});

test('pro webhook refuses an underpayment or an unknown user', async (t) => {
  const app = await boot({ db: fakeDb({ 'users/seller-uid': {} }) });
  t.after(app.close);
  assert.equal(await (await app.webhook(proEvent('seller-uid', 50))).text(), 'underpaid');
  assert.equal(await (await app.webhook(proEvent('ghost', 99))).text(), 'no-user');
  assert.equal(app.db.docs.get('users/seller-uid').proUntil, undefined);
});

// --- featured listings -----------------------------------------------------

function proSeller(overrides = {}) {
  return fakeDb({
    'users/buyer-uid': { proUntil: new Date('2026-07-01T00:00:00Z') },
    'services/s1': { sellerId: 'buyer-uid', status: 'published' },
    'services/s2': { sellerId: 'buyer-uid', status: 'published' },
    'services/s3': { sellerId: 'buyer-uid', status: 'published' },
    'services/s4': { sellerId: 'buyer-uid', status: 'draft' },
    'services/other': { sellerId: 'someone-else', status: 'published' },
    ...overrides,
  });
}

test('a Pro seller can feature two published listings of their own', async (t) => {
  const app = await boot({ db: proSeller() });
  t.after(app.close);

  assert.equal((await app.post('/services/s1/featured', { featured: true })).status, 200);
  assert.equal((await app.post('/services/s2/featured', { featured: true })).status, 200);
  assert.equal(
    app.db.docs.get('services/s1').featuredUntil.toISOString(),
    '2026-07-01T00:00:00.000Z',
    'featured lapses with the subscription',
  );

  const third = await app.post('/services/s3/featured', { featured: true });
  assert.equal(third.status, 409);
  assert.equal((await third.json()).code, 'limit');

  // Unpinning one frees the slot.
  assert.equal((await app.post('/services/s1/featured', { featured: false })).status, 200);
  assert.equal(app.db.docs.get('services/s1').featuredUntil, null);
  assert.equal((await app.post('/services/s3/featured', { featured: true })).status, 200);
});

test('featured refuses drafts, other sellers, and lapsed Pro', async (t) => {
  const app = await boot({ db: proSeller() });
  t.after(app.close);

  assert.equal((await app.post('/services/s4/featured', { featured: true })).status, 409);
  assert.equal((await app.post('/services/other/featured', { featured: true })).status, 403);
  assert.equal((await app.post('/services/s1/featured', { featured: 'yes' })).status, 400);
  assert.equal((await app.post('/services/ghost/featured', { featured: true })).status, 404);

  app.db.docs.set('users/buyer-uid', { proUntil: new Date('2026-01-01T00:00:00Z') });
  const lapsed = await app.post('/services/s1/featured', { featured: true });
  assert.equal(lapsed.status, 402);
  // Unpinning is always allowed, Pro or not.
  assert.equal((await app.post('/services/s1/featured', { featured: false })).status, 200);
});

// --- payouts ---------------------------------------------------------------

const ACCOUNT = { type: 'gcash', accountName: 'Maya R', accountNumber: '09171234567' };

const ADULT = { birthDate: new Date('2000-01-01T00:00:00Z') };
const MINOR = { birthDate: new Date('2012-01-01T00:00:00Z') };

test('a freelancer can request their balance once it clears the minimum', async (t) => {
  const app = await boot({
    db: fakeDb({
      'users/buyer-uid': ADULT,
      'wallets/buyer-uid': { available: 450, pendingPayout: 0, payoutAccount: ACCOUNT },
    }),
  });
  t.after(app.close);

  const res = await app.post('/wallet/payout', {});
  assert.equal(res.status, 200);
  const { payoutId, amount } = await res.json();
  assert.equal(amount, 450);
  const wallet = app.db.docs.get('wallets/buyer-uid');
  assert.equal(wallet.available, 0);
  assert.equal(wallet.pendingPayout, 450);
  const payout = app.db.docs.get(`payouts/${payoutId}`);
  assert.equal(payout.status, 'requested');
  assert.deepEqual(payout.account, ACCOUNT);

  const twice = await app.post('/wallet/payout', {});
  assert.equal(twice.status, 409, 'one payout in flight at a time');
});

test('payout requests below the minimum or without an account are refused', async (t) => {
  const app = await boot({
    db: fakeDb({
      'users/buyer-uid': ADULT,
      'wallets/buyer-uid': { available: 120, payoutAccount: ACCOUNT },
    }),
  });
  t.after(app.close);
  const low = await app.post('/wallet/payout', {});
  assert.equal(low.status, 422);
  assert.equal((await low.json()).code, 'below-minimum');

  app.db.docs.set('wallets/buyer-uid', { available: 900 });
  const none = await app.post('/wallet/payout', {});
  assert.equal((await none.json()).code, 'no-account');
  assert.equal(app.db.docs.get('wallets/buyer-uid').available, 900, 'nothing moved');

  app.db.docs.set('wallets/buyer-uid', {
    available: 900,
    payoutAccount: { ...ACCOUNT, accountNumber: '0917' },
  });
  const typo = await app.post('/wallet/payout', {});
  assert.equal((await typo.json()).code, 'no-account', 'a malformed number is no account');
});

test('minors and students without a birth date cannot request payouts', async (t) => {
  const app = await boot({
    db: fakeDb({
      'users/buyer-uid': MINOR,
      'wallets/buyer-uid': { available: 900, payoutAccount: ACCOUNT },
    }),
  });
  t.after(app.close);
  const minor = await app.post('/wallet/payout', {});
  assert.equal(minor.status, 422);
  assert.equal((await minor.json()).code, 'not-adult');

  app.db.docs.set('users/buyer-uid', { displayName: 'No DOB' });
  const unknown = await app.post('/wallet/payout', {});
  assert.equal((await unknown.json()).code, 'not-adult');
  assert.equal(app.db.docs.get('wallets/buyer-uid').available, 900, 'nothing moved');
});

// --- refunds needing staff -------------------------------------------------

const STUCK = {
  clientId: 'seller-uid',
  freelancerId: 'someone',
  amount: 500,
  commission: 50,
  netToFreelancer: 450,
  status: 'paid',
  method: 'xendit',
  verified: true,
  holdStatus: 'held',
  gatewayPaymentId: 'pay_1',
  refundStatus: 'failed',
};

test('staff can retry a refund through the gateway', async (t) => {
  const calls = [];
  const app = await boot({
    db: fakeDb({ 'admins/buyer-uid': { role: 'admin' }, 'payments/o1': { ...STUCK } }),
    fetchImpl: async (url, init) => {
      calls.push({ url, body: JSON.parse(init.body), idem: init.headers['idempotency-key'] });
      return { ok: true, json: async () => ({ id: 'ref_9', status: 'SUCCEEDED' }) };
    },
  });
  t.after(app.close);

  const res = await app.post('/admin/payments/o1/refund', {});
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { result: 'refunded' });
  assert.ok(calls[0].url.endsWith('/refunds'));
  assert.equal(calls[0].body.invoice_id, 'pay_1');
  assert.equal(calls[0].body.amount, 500, 'whole pesos, not centavos');
  assert.equal(calls[0].idem, 'refund-o1', 'idempotent per order at the gateway');
  assert.equal(app.db.docs.get('payments/o1').status, 'refunded');
  assert.equal(app.db.docs.get('payments/o1').refundReference, 'ref_9');

  const again = await app.post('/admin/payments/o1/refund', {});
  assert.equal(again.status, 409, 'nothing left to refund');
});

test('staff can record a refund made outside the gateway', async (t) => {
  const app = await boot({
    db: fakeDb({ 'admins/buyer-uid': { role: 'admin' }, 'payments/o1': { ...STUCK } }),
  });
  t.after(app.close);

  const noRef = await app.post('/admin/payments/o1/refund-manual', {});
  assert.equal(noRef.status, 400);
  const ok = await app.post('/admin/payments/o1/refund-manual', { reference: 'INSTAPAY-77' });
  assert.equal(ok.status, 200);
  assert.equal(app.db.docs.get('payments/o1').refundStatus, 'manual');
  const inbox = [...app.db.docs.keys()].filter((k) => k.startsWith('users/seller-uid/notifications/'));
  assert.equal(inbox.length, 1, 'the client is told');

  const notStaff = await app.post('/admin/payments/o1/refund-manual', { reference: 'x' }, 'user');
  assert.equal(notStaff.status, 401);
});

test('staff can pass a chargeback on to the seller, once, with a reason', async (t) => {
  const app = await boot({
    db: fakeDb({
      'admins/buyer-uid': { role: 'admin' },
      'payments/o1': { ...STUCK, refundStatus: undefined, holdStatus: 'released' },
      'wallets/someone': { available: 100, clearing: 0, releaseCount: 5 },
    }),
  });
  t.after(app.close);

  const noReason = await app.post('/admin/payments/o1/chargeback', { reason: 'short' });
  assert.equal(noReason.status, 400);

  const ok = await app.post('/admin/payments/o1/chargeback', {
    reason: 'Issuing bank reversed the card payment (case CB-1001).',
  });
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), {
    result: 'recorded', freelancerId: 'someone', net: 450, recovered: 100, owed: 350,
  });
  assert.equal(app.db.docs.get('wallets/someone').owed, 350);
  const inbox = [...app.db.docs.keys()].filter((k) => k.startsWith('users/someone/notifications/'));
  assert.equal(inbox.length, 1, 'the seller is told what will be deducted');

  const again = await app.post('/admin/payments/o1/chargeback', {
    reason: 'Issuing bank reversed the card payment (case CB-1001).',
  });
  assert.equal(again.status, 409, 'recorded once');

  const notStaff = await app.post('/admin/payments/o1/chargeback', { reason: 'x'.repeat(20) }, 'user');
  assert.equal(notStaff.status, 401);
});

test('only staff can settle or reject a payout, and the ledger balances', async (t) => {
  const app = await boot({
    db: fakeDb({
      'admins/buyer-uid': { role: 'admin' },
      'wallets/seller-uid': { available: 0, pendingPayout: 1000, totalPaidOut: 0 },
      'payouts/p1': { uid: 'seller-uid', amount: 500, status: 'requested' },
      'payouts/p2': { uid: 'seller-uid', amount: 500, status: 'requested' },
    }),
    verifyIdToken: async (tk) => {
      if (tk === 'good-token') return UM('buyer-uid');
      if (tk === 'user') return UM('seller-uid');
      throw new Error('bad');
    },
  });
  t.after(app.close);

  const notStaff = await app.post('/admin/payouts/p1/settle', { reference: 'GC123' }, 'user');
  assert.equal(notStaff.status, 403);

  const noRef = await app.post('/admin/payouts/p1/settle', {});
  assert.equal(noRef.status, 400);

  const settled = await app.post('/admin/payouts/p1/settle', { reference: 'GC123' });
  assert.equal(settled.status, 200);
  assert.equal(app.db.docs.get('payouts/p1').status, 'paid');
  assert.equal(app.db.docs.get('wallets/seller-uid').pendingPayout, 500);
  assert.equal(app.db.docs.get('wallets/seller-uid').totalPaidOut, 500);

  const again = await app.post('/admin/payouts/p1/settle', { reference: 'GC123' });
  assert.equal(again.status, 409);

  const rejected = await app.post('/admin/payouts/p2/reject', {
    note: 'Account number does not exist',
  });
  assert.equal(rejected.status, 200);
  assert.equal(app.db.docs.get('wallets/seller-uid').available, 500, 'money returned');
  assert.equal(app.db.docs.get('wallets/seller-uid').pendingPayout, 0);

  const actions = [...app.db.docs.keys()].filter((k) => k.startsWith('adminActions/'));
  assert.equal(actions.length, 2, 'every staff action is logged');
  const inbox = [...app.db.docs.keys()].filter((k) => k.startsWith('users/seller-uid/notifications/'));
  assert.equal(inbox.length, 2, 'the freelancer is told both times');
});

// --- verification ----------------------------------------------------------

test('staff decide a verification request and the profile follows', async (t) => {
  const app = await boot({
    db: fakeDb({
      'admins/buyer-uid': { role: 'admin' },
      'users/seller-uid': { displayName: 'Seller' },
      'verificationRequests/seller-uid': { uid: 'seller-uid', status: 'pending' },
    }),
  });
  t.after(app.close);

  const bad = await app.post('/admin/verification/seller-uid', { approve: 'yes' });
  assert.equal(bad.status, 400);

  const ok = await app.post('/admin/verification/seller-uid', { approve: true });
  assert.equal(ok.status, 200);
  assert.equal(app.db.docs.get('users/seller-uid').identityVerified, true);
  assert.equal(app.db.docs.get('verificationRequests/seller-uid').status, 'approved');
  assert.equal(app.db.docs.get('verificationRequests/seller-uid').idImagePath, '');
  assert.equal(app.db.docs.get('verificationRequests/seller-uid').idImageDeleted, true);

  const again = await app.post('/admin/verification/seller-uid', { approve: false });
  assert.equal(again.status, 409, 'a decided request stays decided');
  assert.equal(app.db.docs.get('users/seller-uid').identityVerified, true);
});

test('only the main admin may approve their own verification request', async (t) => {
  const app = await boot({
    db: fakeDb({
      'admins/buyer-uid': {
        role: 'staff',
        permissions: ['verification.decide'],
      },
      'users/buyer-uid': { displayName: 'Staff member' },
      'verificationRequests/buyer-uid': { uid: 'buyer-uid', status: 'pending' },
    }),
  });
  t.after(app.close);

  const denied = await app.post('/admin/verification/buyer-uid', { approve: true });
  assert.equal(denied.status, 403);
  assert.equal(app.db.docs.get('verificationRequests/buyer-uid').status, 'pending');

  app.db.docs.set('admins/buyer-uid', { role: 'admin' });
  const approved = await app.post('/admin/verification/buyer-uid', { approve: true });
  assert.equal(approved.status, 200);
  assert.equal(app.db.docs.get('users/buyer-uid').identityVerified, true);
});

// --- pricing model at checkout ---------------------------------------------

test('checkout refuses a direct order on a negotiable or contact-first listing', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING, pricingMode: 'negotiable' },
      'orders/order2': { ...PAYABLE_ORDER, serviceId: 'svc2' },
      'services/svc2': { ...FIXED_LISTING, requiresContact: true },
      'orders/order3': { ...PAYABLE_ORDER, serviceId: 'svc3', price: 450 },
      'services/svc3': { ...FIXED_LISTING },
    }),
  });
  t.after(app.close);
  for (const orderId of ['order1', 'order2', 'order3']) {
    const res = await app.checkout({ orderId });
    assert.equal(res.status, 422, orderId);
    assert.equal(app.db.docs.has(`payments/${orderId}`), false, 'nothing recorded');
  }
});

test('checkout accepts an order created from a spent offer at the offer price', async (t) => {
  const offered = { ...PAYABLE_ORDER, price: 1200, offerId: 'off1' };
  const app = await boot({
    db: fakeDb({
      'services/svc1': { ...FIXED_LISTING, pricingMode: 'negotiable' },
      'orders/order1': { ...offered },
      'offers/off1': {
        status: 'ordered',
        orderId: 'order1',
        price: 1200,
        clientId: 'buyer-uid',
        freelancerId: 'seller-uid',
        serviceId: 'svc1',
      },
      'orders/order2': { ...offered, offerId: 'off2' },
      'offers/off2': {
        status: 'accepted',
        price: 1200,
        clientId: 'buyer-uid',
        freelancerId: 'seller-uid',
        serviceId: 'svc1',
      },
      'orders/order3': { ...offered, price: 900 },
    }),
  });
  t.after(app.close);

  const ok = await app.checkout({ orderId: 'order1' });
  assert.equal(ok.status, 200);
  assert.equal(app.db.docs.get('payments/order1').amount, 1200, 'the offer price, not the listing');

  const unspent = await app.checkout({ orderId: 'order2' });
  assert.equal(unspent.status, 422, 'an offer not spent on this order');
  const wrong = await app.checkout({ orderId: 'order3' });
  assert.equal(wrong.status, 422, 'price differs from the offer');
});

// --- permissions ------------------------------------------------------------

test('staff routes need the specific permission, not just a staff document', async (t) => {
  const app = await boot({
    db: fakeDb({
      'admins/buyer-uid': { role: 'staff', permissions: ['verification.decide'] },
      'users/seller-uid': { displayName: 'Seller' },
      'verificationRequests/seller-uid': { uid: 'seller-uid', status: 'pending' },
      'payouts/p1': { uid: 'seller-uid', amount: 500, status: 'requested' },
      'wallets/seller-uid': { pendingPayout: 500 },
    }),
  });
  t.after(app.close);

  // Has verification.decide: allowed.
  assert.equal((await app.post('/admin/verification/seller-uid', { approve: true })).status, 200);
  // Lacks payouts.settle and refunds.handle: refused, and nothing moves.
  assert.equal((await app.post('/admin/payouts/p1/settle', { reference: 'GC1' })).status, 403);
  assert.equal(app.db.docs.get('payouts/p1').status, 'requested');
  assert.equal((await app.post('/admin/payments/o1/refund-manual', { reference: 'x' })).status, 403);

  // An audit entry was written for the decision, with the staff member as actor.
  const audit = [...app.db.docs.entries()].filter(([k]) => k.startsWith('auditLog/'));
  assert.equal(audit.length, 1);
  assert.equal(audit[0][1].action, 'verification.decided');
  assert.equal(audit[0][1].actorId, 'buyer-uid');
});

test('money routes leave an audit trail with the acting user', async (t) => {
  const app = await boot({
    db: fakeDb({
      'orders/order1': { ...PAYABLE_ORDER },
      'services/svc1': { ...FIXED_LISTING },
      'users/buyer-uid': { birthDate: new Date('2000-01-01T00:00:00Z') },
      'wallets/buyer-uid': {
        available: 450,
        pendingPayout: 0,
        payoutAccount: { type: 'gcash', accountName: 'B', accountNumber: '09171234567' },
      },
    }),
  });
  t.after(app.close);
  await app.post('/checkout', { orderId: 'order1' });
  await app.post('/wallet/payout', {});
  const actions = [...app.db.docs.entries()]
    .filter(([k]) => k.startsWith('auditLog/'))
    .map(([, v]) => [v.action, v.actorId]);
  assert.deepEqual(actions.sort(), [
    ['payment.checkout_started', 'buyer-uid'],
    ['payout.requested', 'buyer-uid'],
  ]);
});

// --- automated payouts (Xendit Payouts) ------------------------------------

const AUTO = { payoutsAutomated: true };
const GCASH = { type: 'gcash', accountName: 'Maya R', accountNumber: '09171234567' };
const BANK = { type: 'bank', accountName: 'Maya R', accountNumber: '123456789012', bankCode: 'PH_BDO' };

/** A Xendit Payouts responder that records what was sent. */
function payoutGateway(reply = { ok: true, body: { id: 'disb_1', status: 'ACCEPTED' } }) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body), idem: init.headers['idempotency-key'] });
    if (reply.throws) throw reply.throws;
    return { ok: reply.ok, status: reply.status ?? (reply.ok ? 200 : 400), json: async () => reply.body };
  };
  return { calls, fetchImpl };
}

function walletWith(account, available = 450) {
  return {
    'users/buyer-uid': { birthDate: new Date('2000-01-01T00:00:00Z') },
    'wallets/buyer-uid': { available, pendingPayout: 0, totalPaidOut: 0, payoutAccount: account },
  };
}

const payoutEvent = (referenceId, status, extra = {}) => ({
  event: `payout.${status.toLowerCase()}`,
  data: { id: 'disb_1', reference_id: referenceId, status, amount: 450, channel_code: 'PH_GCASH', ...extra },
});

test('with payouts automated, a request is sent to Xendit at once', async (t) => {
  const gw = payoutGateway();
  const app = await boot({ db: fakeDb(walletWith(GCASH)), fetchImpl: gw.fetchImpl, config: AUTO });
  t.after(app.close);

  const res = await app.post('/wallet/payout', {});
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.delivery, 'submitted');

  assert.equal(gw.calls.length, 1);
  assert.ok(gw.calls[0].url.endsWith('/v2/payouts'));
  assert.equal(gw.calls[0].body.channel_code, 'PH_GCASH');
  assert.equal(gw.calls[0].body.channel_properties.account_number, '09171234567');
  assert.equal(gw.calls[0].body.amount, 450, 'whole pesos');
  assert.equal(gw.calls[0].idem, body.payoutId, 'the payout id is the idempotency key');

  const payout = app.db.docs.get(`payouts/${body.payoutId}`);
  assert.equal(payout.status, 'processing');
  assert.equal(payout.gatewayPayoutId, 'disb_1');
  assert.equal(app.db.docs.get('wallets/buyer-uid').pendingPayout, 450, 'still pending until the callback');
});

test('a bank payout carries its bank channel', async (t) => {
  const gw = payoutGateway();
  const app = await boot({ db: fakeDb(walletWith(BANK)), fetchImpl: gw.fetchImpl, config: AUTO });
  t.after(app.close);
  await app.post('/wallet/payout', {});
  assert.equal(gw.calls[0].body.channel_code, 'PH_BDO');
});

test('a bank account without a bank code is not a payout account', async (t) => {
  const app = await boot({
    db: fakeDb(walletWith({ ...BANK, bankCode: undefined })),
    config: AUTO,
  });
  t.after(app.close);
  const res = await app.post('/wallet/payout', {});
  assert.equal(res.status, 422);
  assert.equal((await res.json()).code, 'no-account');
});

test('a refusal from Xendit returns the money and tells the student', async (t) => {
  const gw = payoutGateway({ ok: false, status: 400, body: { error_code: 'INVALID_DESTINATION' } });
  const app = await boot({ db: fakeDb(walletWith(GCASH)), fetchImpl: gw.fetchImpl, config: AUTO });
  t.after(app.close);

  const res = await app.post('/wallet/payout', {});
  const body = await res.json();
  assert.equal(body.delivery, 'refused');
  const payout = app.db.docs.get(`payouts/${body.payoutId}`);
  assert.equal(payout.status, 'failed');
  assert.match(payout.note, /INVALID_DESTINATION/);
  const wallet = app.db.docs.get('wallets/buyer-uid');
  assert.equal(wallet.available, 450, 'money back');
  assert.equal(wallet.pendingPayout, 0);
  const inbox = [...app.db.docs.keys()].filter((k) => k.startsWith('users/buyer-uid/notifications/'));
  assert.equal(inbox.length, 1);
});

test('an unreachable gateway leaves the payout in the queue for staff', async (t) => {
  const gw = payoutGateway({ throws: new Error('ECONNRESET') });
  const app = await boot({ db: fakeDb(walletWith(GCASH)), fetchImpl: gw.fetchImpl, config: AUTO });
  t.after(app.close);

  const body = await (await app.post('/wallet/payout', {})).json();
  assert.equal(body.delivery, 'unreachable');
  const payout = app.db.docs.get(`payouts/${body.payoutId}`);
  assert.equal(payout.status, 'requested', 'still waiting, not lost');
  assert.match(payout.gatewayError, /ECONNRESET/);
  assert.equal(app.db.docs.get('wallets/buyer-uid').pendingPayout, 450);
});

test('the payout callback settles or returns, exactly once', async (t) => {
  const app = await boot({
    db: fakeDb({
      'payouts/p1': { uid: 'seller-uid', amount: 450, status: 'processing', gatewayPayoutId: 'disb_1' },
      'payouts/p2': { uid: 'seller-uid', amount: 300, status: 'processing', gatewayPayoutId: 'disb_2' },
      'wallets/seller-uid': { available: 0, pendingPayout: 750, totalPaidOut: 0 },
    }),
    config: AUTO,
  });
  t.after(app.close);

  const ok = await app.webhook(payoutEvent('p1', 'SUCCEEDED'));
  assert.equal(await ok.text(), 'paid');
  assert.equal(app.db.docs.get('payouts/p1').status, 'paid');
  assert.equal(app.db.docs.get('payouts/p1').settledBy, 'xendit');
  let wallet = app.db.docs.get('wallets/seller-uid');
  assert.equal(wallet.pendingPayout, 300);
  assert.equal(wallet.totalPaidOut, 450);

  const again = await app.webhook(payoutEvent('p1', 'SUCCEEDED'));
  assert.equal(await again.text(), 'already');
  assert.equal(app.db.docs.get('wallets/seller-uid').totalPaidOut, 450, 'not double-counted');

  const failed = await app.webhook(payoutEvent('p2', 'FAILED', { failure_code: 'INVALID_DESTINATION' }));
  assert.equal(await failed.text(), 'returned');
  wallet = app.db.docs.get('wallets/seller-uid');
  assert.equal(wallet.pendingPayout, 0);
  assert.equal(wallet.available, 300, 'failed transfer back in the balance');
  assert.equal(app.db.docs.get('payouts/p2').status, 'failed');

  const inbox = [...app.db.docs.keys()].filter((k) => k.startsWith('users/seller-uid/notifications/'));
  assert.equal(inbox.length, 2, 'told about both');
  const audit = [...app.db.docs.values()].filter((v) => v.action && v.action.startsWith('payout.')).map((v) => v.action).sort();
  assert.deepEqual(audit, ['payout.rejected', 'payout.settled']);
});

test('payout callbacks with no usable reference or an unknown status are acknowledged', async (t) => {
  const app = await boot({ config: AUTO });
  t.after(app.close);
  assert.equal(await (await app.webhook({ event: 'payout.succeeded', data: { id: 'x' } })).text(), 'no reference');
  assert.equal(await (await app.webhook(payoutEvent('a/b', 'SUCCEEDED'))).text(), 'no reference');
  assert.equal(await (await app.webhook(payoutEvent('p9', 'ACCEPTED'))).text(), 'ignored');
  assert.equal(await (await app.webhook(payoutEvent('p9', 'SUCCEEDED'))).text(), 'no-payout');
  assert.equal((await app.webhook(payoutEvent('p1', 'SUCCEEDED'), { token: null })).status, 401);
});

test('staff can (re)send a waiting payout, with the right permission', async (t) => {
  const gw = payoutGateway();
  const app = await boot({
    db: fakeDb({
      'admins/buyer-uid': { role: 'staff', permissions: ['payouts.settle'] },
      'payouts/p1': { uid: 'seller-uid', amount: 450, status: 'requested', account: GCASH },
      'payouts/p2': { uid: 'seller-uid', amount: 450, status: 'processing', account: GCASH },
    }),
    fetchImpl: gw.fetchImpl,
    config: AUTO,
  });
  t.after(app.close);

  const sent = await app.post('/admin/payouts/p1/submit', {});
  assert.equal(sent.status, 200);
  assert.equal((await sent.json()).outcome, 'submitted');
  assert.equal(app.db.docs.get('payouts/p1').status, 'processing');

  const twice = await app.post('/admin/payouts/p2/submit', {});
  assert.equal(twice.status, 409, 'already with the gateway');

  app.db.docs.set('admins/buyer-uid', { role: 'staff', permissions: ['reports.view'] });
  assert.equal((await app.post('/admin/payouts/p1/submit', {})).status, 403);
});

test('with payouts manual, a request stays in the staff queue and Xendit is not called', async (t) => {
  const gw = payoutGateway();
  const app = await boot({ db: fakeDb(walletWith(GCASH)), fetchImpl: gw.fetchImpl });
  t.after(app.close);
  const body = await (await app.post('/wallet/payout', {})).json();
  assert.equal(body.delivery, 'manual');
  assert.equal(gw.calls.length, 0);
  assert.equal(app.db.docs.get(`payouts/${body.payoutId}`).status, 'requested');
});
