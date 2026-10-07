/**
 * The only module that talks to Xendit.
 *
 * Both calls take the secret key from `config`, never from a request, and
 * both time out: without a deadline a stalled gateway holds a function
 * instance open until the platform kills it.
 *
 * Xendit facts this code depends on:
 *   - HTTP Basic auth: the secret key as the username, empty password.
 *   - Amounts are whole currency units (₱500 is `500`), not centavos.
 *   - A hosted checkout is an Invoice. We choose its `external_id`, and every
 *     callback echoes it back, so settlement never trusts anything the
 *     browser round-tripped.
 *   - Callbacks carry the account's verification token in `x-callback-token`;
 *     there is no per-delivery signature, so the token is the whole secret
 *     and is compared in constant time.
 *   - Test and live are separate keys (`xnd_development_…` / `xnd_production_…`),
 *     never separate signatures.
 */

const crypto = require('crypto');

const GATEWAY_TIMEOUT_MS = 15000;
const BASE_URL = 'https://api.xendit.co';

/** How long an unpaid invoice stays open, in seconds. Long enough for a
 *  student to find their GCash balance; short enough that a stale link does
 *  not settle an order that was cancelled last week. */
const INVOICE_DURATION_SECONDS = 24 * 60 * 60;

/**
 * What the buyer picks in the app, mapped to the Xendit invoice channels the
 * hosted page will offer. One channel means the page opens straight on it,
 * the way a food-delivery checkout does; `any` shows the whole PH set.
 * Twinned with `PaymentChannel` on the Dart side.
 */
const PAYMENT_METHODS = Object.freeze({
  gcash: ['GCASH'],
  maya: ['PAYMAYA'],
  card: ['CREDIT_CARD'],
  any: ['GCASH', 'PAYMAYA', 'CREDIT_CARD', 'GRABPAY', 'SHOPEEPAY'],
});

/** The channel list for a method name; unknown or missing names get every channel. */
function paymentMethodsFor(method) {
  return PAYMENT_METHODS[method] || PAYMENT_METHODS.any;
}

/** A gateway refusal that retrying will not fix (bad account number, an
 *  unsupported channel, insufficient balance). Carries Xendit's error code so
 *  the record can say why. */
class GatewayRejection extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.permanent = true;
  }
}

async function call(path, body, { fetchImpl, config, idempotencyKey }) {
  const auth = Buffer.from(`${config.secretKey}:`).toString('base64');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GATEWAY_TIMEOUT_MS);
  let response;
  try {
    // No body means a lookup; Xendit's reads are plain GETs on the same auth.
    response = await fetchImpl(`${BASE_URL}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      signal: controller.signal,
      headers: {
        Authorization: `Basic ${auth}`,
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...(idempotencyKey ? { 'idempotency-key': idempotencyKey } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    // 4xx is Xendit saying no to *this* request; 5xx is Xendit having a bad
    // day. Only the first is worth recording as a decision.
    if (response.status >= 400 && response.status < 500) {
      let code = `HTTP_${response.status}`;
      try {
        code = (await response.json())?.error_code ?? code;
      } catch {
        // keep the status code
      }
      throw new GatewayRejection(code, `xendit refused: ${code}`);
    }
    throw new Error(`xendit responded ${response.status}`);
  }
  try {
    return await response.json();
  } catch {
    throw new Error('xendit returned a non-JSON body');
  }
}

/**
 * Channel codes for a payout account. GCash and Maya are single channels;
 * a bank account carries its bank's code (`PH_BDO`, `PH_BPI`, …), chosen
 * from the list the app offers and validated by the rules.
 */
function channelCodeFor(account) {
  if (!account) return null;
  if (account.type === 'gcash') return 'PH_GCASH';
  if (account.type === 'maya') return 'PH_PAYMAYA';
  if (account.type === 'bank' && /^PH_[A-Z0-9_]{2,20}$/.test(account.bankCode || '')) {
    return account.bankCode;
  }
  return null;
}

/**
 * Sends money to a freelancer. `referenceId` is our payout id and doubles as
 * the idempotency key, so a retried request for the same payout cannot pay
 * twice. Xendit answers ACCEPTED at once and reports the outcome later by
 * callback (payout.succeeded / payout.failed).
 */
async function createPayout({ referenceId, amountPesos, account, description }, deps) {
  const channelCode = channelCodeFor(account);
  if (!channelCode) throw new GatewayRejection('UNSUPPORTED_CHANNEL', 'no channel for this account');
  const body = await call(
    '/v2/payouts',
    {
      reference_id: referenceId,
      channel_code: channelCode,
      channel_properties: {
        account_holder_name: account.accountName,
        account_number: account.accountNumber,
      },
      amount: amountPesos,
      currency: 'PHP',
      description: String(description).slice(0, 100),
      receipt_notification: {},
    },
    { ...deps, idempotencyKey: referenceId },
  );
  const id = body?.id;
  if (typeof id !== 'string') throw new Error('xendit payout missing id');
  return { id, status: String(body.status ?? 'ACCEPTED').toUpperCase() };
}

/** Statuses a payout callback can carry, mapped to what they mean to us. */
const PAYOUT_OUTCOMES = Object.freeze({
  SUCCEEDED: 'succeeded',
  FAILED: 'failed',
  CANCELLED: 'failed',
  REVERSED: 'reversed',
});

/**
 * Creates a hosted invoice page for one amount.
 *
 * `externalId` is ours and is echoed on every callback, which is how
 * settlement finds the order or subscriber. `metadata` is stored on the
 * invoice for reconciliation but is not relied on.
 */
async function createInvoice(
  { externalId, amountPesos, description, payerEmail, metadata, successUrl, failureUrl, method },
  deps,
) {
  const body = await call(
    '/v2/invoices',
    {
      external_id: externalId,
      amount: amountPesos,
      currency: 'PHP',
      description: String(description).slice(0, 255),
      invoice_duration: INVOICE_DURATION_SECONDS,
      success_redirect_url: successUrl,
      failure_redirect_url: failureUrl,
      ...(payerEmail ? { payer_email: payerEmail } : {}),
      ...(metadata ? { metadata } : {}),
      payment_methods: paymentMethodsFor(method),
    },
    deps,
  );
  const id = body?.id;
  const invoiceUrl = body?.invoice_url;
  // A missing url would otherwise reach the app as `undefined` and surface as
  // a confusing generic failure.
  if (typeof id !== 'string' || typeof invoiceUrl !== 'string') {
    throw new Error('xendit response missing id or invoice_url');
  }
  if (!invoiceUrl.startsWith('https://')) {
    throw new Error('xendit invoice_url is not https');
  }
  return { id, checkoutUrl: invoiceUrl };
}

/**
 * The gateway's current view of an invoice, in the same shape its callback
 * delivers (`external_id`, `status`, `paid_amount`), so the reconciler can
 * hand it to the same settlement code.
 */
async function getInvoice(invoiceId, deps) {
  if (typeof invoiceId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(invoiceId)) {
    throw new Error('invalid invoice id');
  }
  return call(`/v2/invoices/${invoiceId}`, undefined, deps);
}

/**
 * Refunds a paid invoice in full. Idempotent on our reference so a retried
 * trigger cannot refund twice at the gateway.
 */
async function createRefund({ invoiceId, amountPesos, reason, referenceId }, deps) {
  const body = await call(
    '/refunds',
    {
      invoice_id: invoiceId,
      reference_id: referenceId,
      amount: amountPesos,
      currency: 'PHP',
      reason: reason || 'REQUESTED_BY_CUSTOMER',
    },
    { ...deps, idempotencyKey: referenceId },
  );
  const id = body?.id;
  if (typeof id !== 'string') throw new Error('xendit refund missing id');
  if (body.status === 'FAILED') throw new Error('xendit refund failed');
  return { id, status: body.status ?? null };
}

/**
 * Constant-time check of the callback verification token.
 *
 * Xendit sends the same token on every delivery, so a leaked token is a
 * forged settlement; it is compared byte-for-byte without early exit and
 * lives only in a Firebase secret.
 */
function verifyCallback(tokenHeader, config) {
  if (typeof tokenHeader !== 'string' || !config.callbackToken) return false;
  const a = Buffer.from(tokenHeader, 'utf8');
  const b = Buffer.from(config.callbackToken, 'utf8');
  // timingSafeEqual throws on a length mismatch, so compare lengths first.
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

/** Statuses on which the money has arrived. `SETTLED` follows `PAID` once
 *  Xendit moves funds to the balance; both mean the same to us and the
 *  second is idempotent. */
const PAID_STATUSES = ['PAID', 'SETTLED'];

module.exports = {
  GatewayRejection,
  createInvoice,
  paymentMethodsFor,
  PAYMENT_METHODS,
  getInvoice,
  createRefund,
  createPayout,
  channelCodeFor,
  verifyCallback,
  PAID_STATUSES,
  PAYOUT_OUTCOMES,
  GATEWAY_TIMEOUT_MS,
  INVOICE_DURATION_SECONDS,
};
