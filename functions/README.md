# Backend (`functions/`)

The trusted server behind the parts of the app that cannot be decided on a
phone: money, entitlements, and push.

**The app runs without this.** With no backend configured the Flutter app
falls back to manual settlement, no Pro, no payouts, and in-app-only
notifications. Everything here is what the Blaze plan turns on.

## What it does

| Piece | Kind | Job |
| --- | --- | --- |
| `api` | HTTPS (Express, `server.js`) | Checkout, Xendit callback, Pro checkout, featured listings, payout requests, staff decisions |
| `onNotificationCreated` | Firestore trigger | Pushes every `users/{uid}/notifications` document to that user's devices |
| `onOrderStatusChanged` | Firestore trigger | `completed` → release held money to the freelancer's wallet; `cancelled`/`rejected` → refund the client through Xendit |
| `autoCompleteOrders` | Schedule, every 6 h | Completes a `submitted` order the client has ignored for 3 days |

`server.js` is plain Express and also runs standalone (`npm start`) on any
container host. The triggers and the schedule exist only on Cloud Functions.

## Why this exists

1. **The Xendit secret key cannot ship in the app.** An APK decompiles and a
   web build ships readable JavaScript.
2. **Payment must be verified, not reported.** Xendit confirms settlement
   with a callback carrying the account's verification token; Firestore
   rules cannot call an external API.
3. **Money held for someone else needs a ledger no client can touch.**
   Balances, releases, refunds, and payouts are written here with the Admin
   SDK, which bypasses security rules — which is exactly why those rules can
   forbid every client from writing `wallets`, `ledger`, `payouts`,
   `proUntil`, `identityVerified`, and `featuredUntil`.

## Deploy (Cloud Functions, Blaze)

```sh
cd functions && npm install && cd ..

# Secrets are injected by Firebase and never committed.
firebase functions:secrets:set XENDIT_SECRET_KEY        # xnd_development_… first
firebase functions:secrets:set XENDIT_CALLBACK_TOKEN    # Settings → Developers → Callbacks

# Non-secret config lives in functions/.env (deployed with the code).
cat > functions/.env <<EOF
APP_SUCCESS_URL=https://your-app.example.com/payment/success
APP_CANCEL_URL=https://your-app.example.com/payment/cancelled
APP_ALLOWED_ORIGINS=https://your-app.example.com
EOF

firebase deploy --only functions,firestore:rules,firestore:indexes,storage
```

The function URL is
`https://asia-southeast1-<project-id>.cloudfunctions.net/api`. In the Xendit
dashboard → Settings → Developers → Callbacks, set the **Invoices** callback
URL to `<that URL>/webhook` and copy the **callback verification token** into
`XENDIT_CALLBACK_TOKEN`. Xendit sends that token on every delivery as
`x-callback-token`; a delivery without it is refused.

Then point the app at it:

```sh
flutter run --dart-define=PAYMENTS_API_URL=https://asia-southeast1-<project-id>.cloudfunctions.net/api
```

That single define switches `PaymentConfig` to gateway mode and turns on
payouts, Pro, and the staff queues. No application code changes.

### Standalone instead

```sh
cp .env.example .env      # all five variables
GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json npm start
```

You lose the triggers and the schedule: no push, no automatic release or
refund, no auto-completion. Cloud Functions is the intended home.

## Endpoints

All `POST`, all JSON. Every route except `/webhook` needs
`Authorization: Bearer <Firebase ID token>`.

| Route | Who | Body | Does |
| --- | --- | --- | --- |
| `/checkout` | buyer | `{orderId}` | Xendit invoice for the order; records a pending payment |
| `/webhook` | Xendit | invoice callback | Settles a payment (`verified: true, holdStatus: held`) or a Pro month; closes an expired one |
| `/pro/checkout` | anyone | – | ₱99 invoice; records a pending subscription |
| `/services/:id/featured` | the seller | `{featured: bool}` | Pins/unpins; needs active Pro, max 2 per seller |
| `/wallet/payout` | freelancer | – | Moves the available balance into a payout request (min ₱300, one at a time); with `XENDIT_PAYOUTS=auto`, sends it through Xendit Payouts at once |
| `/admin/payouts/:id/submit` | staff | – | (Re)sends a waiting payout through Xendit Payouts |
| `/admin/payouts/:id/settle` | staff | `{reference}` | Records a transfer made by hand, moves pending → paid out |
| `/admin/payouts/:id/reject` | staff | `{note}` | Returns the money to the balance |
| `/admin/verification/:uid` | staff | `{approve, note}` | Decides a student-ID check; sets `identityVerified` |

Routes take **ids only**. Amounts, entitlements, and who may do what are
re-derived from Firestore. `/checkout` never reads a price from the request.

### Status codes

| Code | When |
| --- | --- |
| 400 | Malformed body or id |
| 401 | No bearer token, an unverifiable one, or a missing/wrong callback token |
| 402 | Featuring without an active Pro subscription |
| 403 | Not the buyer / seller / staff |
| 404 | No such order, service, payout, or request |
| 409 | Wrong state: order not payable, already paid, featured cap reached, payout already pending, request already decided |
| 413 | Body over 64 KB |
| 422 | Malformed order; payout below the minimum or without an account |
| 502 / 504 | Xendit refused, answered nonsense, or timed out |
| 503 | Firestore unavailable |

Callback replies follow Xendit's retry behaviour: **non-2xx means retry**,
so only transient failures return one. Every permanent outcome answers 200
with a reason in the body.

### How the callback finds the order

We choose each invoice's `external_id` — `order:<orderId>` or
`pro:<uid>:<nonce>` — and Xendit echoes it on every callback. Settlement
reads that, never the invoice's metadata or anything the browser passed
through. `PAID` and `SETTLED` both mean the money arrived (the second is a
no-op); `EXPIRED` closes a still-pending record as `failed`; everything else
is acknowledged and ignored. Amounts are whole pesos: `paid_amount` must be
at least the order's price.

## Money flow

```text
client pays ──callback──▶ payments/{orderId}: paid, verified, holdStatus: held
                                │
      order → completed ────────┼──▶ holdStatus: released
      (client, or auto after 3d)│    wallets/{freelancer}.available += net
                                │    ledger: release
      order → cancelled/rejected┴──▶ Xendit refund → holdStatus: refunded
                                     ledger: refund

freelancer requests payout ──▶ payouts/{id}: requested
                               wallet: available → pendingPayout
   XENDIT_PAYOUTS=auto ──────▶ Xendit Payouts (idempotency key = payout id)
        accepted ────────────▶ payouts/{id}: processing, gatewayPayoutId
        refused (4xx) ───────▶ payouts/{id}: failed; wallet: pending → available
        unreachable ─────────▶ stays requested; staff retry from the queue
   payout.succeeded callback ▶ payouts/{id}: paid
                               wallet: pendingPayout → totalPaidOut
   payout.failed callback ───▶ payouts/{id}: failed; wallet: pending → available
   (or) staff mark sent by hand ▶ payouts/{id}: paid, reference
```

### Automated payouts

Set `XENDIT_PAYOUTS=auto` in `functions/.env` and a requested payout is
handed to **Xendit Payouts** in the same request: `PH_GCASH` and
`PH_PAYMAYA` for e-wallets, the bank's channel code (`PH_BDO`, `PH_BPI`, …,
the list in `policy.BANK_CHANNELS`) for bank accounts. The payout id is the
gateway's idempotency key, so nothing can pay twice. Xendit answers
`ACCEPTED` and reports the outcome later on the **Payouts** callback URL
(same `/webhook`, envelope `{event: 'payout.succeeded' | 'payout.failed',
data: {reference_id, …}}`), which settles or returns the money. A
`payout.reversed` after success is flagged for staff rather than guessed at.

This needs the Payouts product enabled on the Xendit account and a funded
balance. With `XENDIT_PAYOUTS=manual` (the default) every payout waits in
the staff queue, where staff can still press **Send via Xendit** per payout
or record a hand-made transfer.

Every balance change is a transaction that also appends a `ledger` entry.
Retries are safe: release and refund only act on `held`, settlement only on
`requested`, Pro activation only on a session not yet `paid`.

Refunds go to the gateway **before** the record changes, against the
invoice id with `refund-<orderId>` as the idempotency key, so a retried
trigger cannot refund twice. If Xendit refuses, the payment is flagged
`refundStatus: failed` for staff rather than being recorded as returned when
it was not.

## Tests

```sh
npm test
```

70 tests on Node's built-in runner, offline: `smoke.test.js` drives every
HTTP route against a real listener with Firestore, token verification, and
Xendit substituted; `ledger.test.js` exercises release, refund, payouts,
auto-completion, Pro renewal, and push fan-out against the in-memory
Firestore in `test-helpers.js`.

## Security properties

- The secret key exists only in Firebase secrets or this process's env.
- Callbacks: the verification token is compared in constant time and lives
  only in a Firebase secret. Xendit has no per-delivery signature, so the
  token *is* the secret — rotate it in the dashboard if it ever leaks.
- Test and live are separate keys (`xnd_development_` / `xnd_production_`);
  `/health` reports which one a deployment holds.
- Ids are restricted to `[A-Za-z0-9_-]{1,128}` so `orders/${id}` cannot
  address another document.
- Settlement, release, refund, and payout are idempotent.
- `verified`, `holdStatus`, `proUntil`, `identityVerified`, `featuredUntil`,
  and every wallet balance are unreachable from any client, by rule.
- Staff routes check `admins/{uid}`, a document only a service-account key
  can write, and log every decision to `adminActions`.
- Errors never render a stack trace.
