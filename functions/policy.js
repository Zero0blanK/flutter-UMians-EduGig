/**
 * Business constants and pure money maths shared by every backend entry point.
 *
 * Each figure here has a twin in the Flutter app (see the comment beside it).
 * The server's copy is the one that is charged, released, or refused; the
 * client's copy only exists so the UI can show the same number before the
 * request is made. When one changes, change both.
 */

/** Firestore ids are opaque, but a slash would let `orders/${id}` address a
 *  different document entirely (`orders/x/sub/y`), so ids are constrained. */
const DOC_ID = /^[A-Za-z0-9_-]{1,128}$/;

/** Mirrors the app: whole pesos, 1 to 1,000,000 (`ServiceRepository._validate`). */
const MIN_PRICE = 1;
const MAX_PRICE = 1000000;

/** The gateway settles in PHP; anything else would charge a different
 *  currency than the order recorded. */
const SUPPORTED_CURRENCY = 'PHP';

/** The `method` a gateway-settled payment carries. Mirrors PaymentMethod in
 *  lib/features/payments/domain/payment.dart and the list in
 *  firestore.rules. Manual settlements carry 'manual'. */
const GATEWAY_METHOD = 'xendit';

/** Must match CommissionPolicy.standard in
 *  lib/features/payments/domain/commission.dart. */
const COMMISSION_BASIS_POINTS = 500; // 5.00%

/** No fixed minimum: small orders use the same percentage and rounding. */
const MINIMUM_COMMISSION = 0;

/** Pro subscription: price per prepaid month and how long a month is. Mirrors
 *  ProPolicy in lib/features/pro/domain/pro_policy.dart. */
const PRO_PRICE = 99;
const PRO_PERIOD_DAYS = 30;

/** How many of their own listings a Pro seller may feature at once. */
const FEATURED_PER_SELLER = 2;
const FEATURED_PER_PAGE = 3;

/** A submitted delivery the client never answers auto-completes after this
 *  long, so a silent buyer cannot keep a freelancer unpaid indefinitely.
 *  Mirrors kAutoCompleteAfter in lib/features/orders/domain/order.dart. */
const AUTO_COMPLETE_DAYS = 3;

/** Payouts are batched: a transfer costs a fixed fee whatever its size, so a
 *  balance has to be worth moving before it can be requested. Mirrors
 *  WalletPolicy.minimumPayout in lib/features/wallet/domain/wallet.dart. */
const MINIMUM_PAYOUT = 300;

/** A client is reminded this many hours before a silent delivery completes,
 *  so the deadline is never a surprise. */
const REMINDER_HOURS_BEFORE = 24;

/** Chargebacks arrive weeks after a card payment. A seller's first releases
 *  clear after a delay so a dispute has somewhere to land; after that, funds
 *  clear immediately. Mirrors WalletPolicy in the app. */
const NEW_SELLER_CLEARANCE_DAYS = 7;
const NEW_SELLER_CLEARED_RELEASES = 3;

/** A dispute on an order of this price or more needs two different staff
 *  members: one proposes the outcome, another closes it. Enforced by the
 *  rules (the literal there) and mirrored by DisputePolicy in the app. */
const DISPUTE_SECOND_OPINION_FROM = 2000;

/** A checkout still `pending` this long after it was opened is asked about
 *  at the gateway directly, in case its callback never arrived. Long enough
 *  that a student mid-payment is not raced; short enough that a lost callback
 *  is a delay, not a support ticket. Server-only. */
const RECONCILE_PENDING_AFTER_MINUTES = 30;

/** A balance whose owner has not signed in for this long is flagged for
 *  staff to reach out, before a graduate's university account is closed
 *  with money still inside. Mirrors WalletPolicy.dormantAfterDays. */
const DORMANT_WALLET_DAYS = 90;

/** Selling and payouts need an adult: a minor cannot enter a contract or hold
 *  a verified e-wallet. Buying is open to any signed-in student. */
const MIN_SELLER_AGE_YEARS = 18;

/** The only identity the platform accepts. Mirrors UmAccount in the app and
 *  isSignedIn()/isStudentEmail() in firestore.rules. */
const UM_DOMAIN = 'umindanao.edu.ph';
const STUDENT_EMAIL = /^[a-z]+\.[a-z]+\.(\d{6})@umindanao\.edu\.ph$/;

function isUmEmail(email) {
  return typeof email === 'string' && email.toLowerCase().endsWith(`@${UM_DOMAIN}`);
}

function studentIdOf(email) {
  const match = typeof email === 'string' ? STUDENT_EMAIL.exec(email.toLowerCase()) : null;
  return match ? match[1] : null;
}

/** Staff permissions. Mirrors knownPermissions() in firestore.rules and
 *  AdminPermission in the app. The main admin (role 'admin') has them all. */
const PERMISSIONS = Object.freeze([
  'users.manage',
  'services.moderate',
  'categories.manage',
  'orders.manage',
  'disputes.resolve',
  'payouts.settle',
  'refunds.handle',
  'verification.decide',
  'reports.view',
  'settings.manage',
]);

/** Whether a staff document grants `permission`. */
function hasPermission(staff, permission) {
  if (!staff) return false;
  if (staff.role === 'admin') return true;
  return Array.isArray(staff.permissions) && staff.permissions.includes(permission);
}

const PAYABLE_ORDER_STATUSES = [
  'accepted',
  'inProgress',
  'submitted',
  'revisionRequested',
];

/**
 * Integer-only split; mirrors the Dart implementation exactly.
 *
 * Commission rounds half-up and is floored at MINIMUM_COMMISSION, but never
 * exceeds the gross itself, so a ₱10 order cannot owe ₱20. The payout is
 * derived by subtraction so the two parts always reconstitute the gross.
 */
function breakdownOf(gross) {
  if (!Number.isInteger(gross) || gross < 0) {
    throw new RangeError('gross must be a non-negative integer');
  }
  let commission = Math.floor((gross * COMMISSION_BASIS_POINTS + 5000) / 10000);
  if (commission < MINIMUM_COMMISSION) {
    commission = Math.min(MINIMUM_COMMISSION, gross);
  }
  return { gross, commission, netToFreelancer: gross - commission };
}

/** Returns an error string when an order cannot safely be charged. */
function validateOrderForPayment(order) {
  if (!Number.isInteger(order.price)) return 'order price is not an integer';
  if (order.price < MIN_PRICE || order.price > MAX_PRICE) {
    return 'order price out of range';
  }
  if (typeof order.clientId !== 'string' || !order.clientId) {
    return 'order has no client';
  }
  if (typeof order.freelancerId !== 'string' || !order.freelancerId) {
    return 'order has no freelancer';
  }
  if ((order.currency || SUPPORTED_CURRENCY) !== SUPPORTED_CURRENCY) {
    return `unsupported currency ${order.currency}`;
  }
  return null;
}

/** Whether someone born on `birthDate` is at least MIN_SELLER_AGE_YEARS at `now`.
 *  Null or unparseable birth dates are not adults: the check must be opted
 *  into, never defaulted through. */
function isAdult(birthDate, now) {
  const born = birthDate instanceof Date
    ? birthDate
    : birthDate && typeof birthDate.toDate === 'function'
    ? birthDate.toDate()
    : null;
  if (!born || Number.isNaN(born.getTime())) return false;
  const cutoff = new Date(now);
  cutoff.setFullYear(cutoff.getFullYear() - MIN_SELLER_AGE_YEARS);
  return born <= cutoff;
}

/**
 * Payout account numbers by type. A typo here sends money to a stranger, so
 * the shape is checked everywhere it can be: here, in the app, and in rules.
 *   gcash / maya: an 11-digit PH mobile number starting 09
 *   bank:         10 to 16 digits
 */
function validAccountNumber(type, number) {
  if (typeof number !== 'string') return false;
  if (type === 'gcash' || type === 'maya') return /^09\d{9}$/.test(number);
  if (type === 'bank') return /^\d{10,16}$/.test(number);
  return false;
}

/** Banks a payout can be sent to, as Xendit channel codes. Mirrors
 *  WalletPolicy.banks in the app and the pattern in firestore.rules. */
const BANK_CHANNELS = Object.freeze([
  'PH_BDO', 'PH_BPI', 'PH_METROBANK', 'PH_LANDBANK', 'PH_UNIONBANK',
  'PH_SECURITYBANK', 'PH_PNB', 'PH_RCBC', 'PH_CHINABANK', 'PH_EASTWEST',
]);

/**
 * When a Pro period paid for at `now` should end.
 *
 * Renewing early extends the current period rather than restarting it, so a
 * subscriber who pays a week ahead does not lose that week.
 */
function proPeriodEnd(currentEnd, now) {
  const base = currentEnd && currentEnd > now ? currentEnd : now;
  return new Date(base.getTime() + PRO_PERIOD_DAYS * 24 * 60 * 60 * 1000);
}

module.exports = {
  DOC_ID,
  MIN_PRICE,
  MAX_PRICE,
  SUPPORTED_CURRENCY,
  GATEWAY_METHOD,
  COMMISSION_BASIS_POINTS,
  MINIMUM_COMMISSION,
  PRO_PRICE,
  PRO_PERIOD_DAYS,
  FEATURED_PER_SELLER,
  FEATURED_PER_PAGE,
  AUTO_COMPLETE_DAYS,
  RECONCILE_PENDING_AFTER_MINUTES,
  DORMANT_WALLET_DAYS,
  DISPUTE_SECOND_OPINION_FROM,
  REMINDER_HOURS_BEFORE,
  NEW_SELLER_CLEARANCE_DAYS,
  NEW_SELLER_CLEARED_RELEASES,
  MIN_SELLER_AGE_YEARS,
  UM_DOMAIN,
  STUDENT_EMAIL,
  isUmEmail,
  studentIdOf,
  PERMISSIONS,
  hasPermission,
  MINIMUM_PAYOUT,
  PAYABLE_ORDER_STATUSES,
  breakdownOf,
  validateOrderForPayment,
  isAdult,
  validAccountNumber,
  BANK_CHANNELS,
  proPeriodEnd,
};
