# Blaze: turning everything on

The project is on the Blaze plan and the code for every paid-tier feature is
in the repository. This is the runbook for switching each one on against the
real project, in the order that avoids surprises.

Nothing here is needed to develop or demo. Against the emulator the app runs
with no backend: manual settlement, inbox-only notifications, no attachments.

---

## 0. Before anything else: a budget alert

Blaze is pay-as-you-go with the same free allowances Spark has. For a campus
marketplace that is usually ₱0 a month, but an unbounded card on a project
with public endpoints is the one genuinely risky thing here.

Firebase console → ⚙ → **Usage and billing** → **Details & settings** →
**Set a budget alert**. Pick a figure you would notice (₱500/month). An alert
emails you; it does not cap spending.

| Service | Free allowance | What would burn it |
| --- | --- | --- |
| Firestore reads | 50k/day | A runaway listener |
| Cloud Storage | 5 GB stored, 1 GB/day down | Video "deliveries"; capped at 25 MB per file in rules |
| Cloud Functions | 2M invocations | A webhook retry storm; the webhook answers 200 to anything permanent for exactly this reason |
| FCM | Free | — |
| Cloud Scheduler | 3 jobs free | The auto-complete job is one |

---

## 1. Authentication: UM Google accounts

1. Firebase console → **Build → Authentication → Sign-in method → Google →
   Enable**. Set the support email. Email/password stays off on the real
   project; the emulator build keeps it for seeded accounts.
2. **Authorized domains**: add the domain the web build is served from.
3. Android: add the debug and release **SHA-1/SHA-256** fingerprints to the
   Android app in Project settings and re-download `google-services.json`.
4. Optional but recommended: **upgrade to Firebase Authentication with
   Identity Platform** (Authentication → Settings → Upgrade), then set
   `IDENTITY_PLATFORM=true` in `functions/.env` and deploy again. This turns
   on the `gateSignUp` / `gateSignIn` blocking functions, which refuse a
   non-UM account before it exists and record every sign-in in the audit
   log. Leave the flag `false` until the upgrade is done: Google refuses to
   deploy blocking functions on a project without Identity Platform, and
   that one refusal fails every function in the batch. The app, the rules
   and the backend refuse non-UM accounts on their own either way.

The first main admin is granted with a service-account key once that
person has signed in once:

```sh
node tools/seed/seed.js --admin a.nerosa.545679@umindanao.edu.ph --live
```

## 2. Storage: attachments and ID photos

1. Firebase console → **Build → Storage → Get started**, same region as
   Firestore (`asia-southeast1`).
2. Deploy the rules. **Do not ship the console's default template** — it lets
   any signed-in user write anywhere.

   ```sh
   firebase deploy --only storage
   ```

That is all: chat attachments, delivery files, and verification photos work
in every build, backend or not. Paths and size caps are in `storage.rules`;
the client checks sizes too, but the rule is the limit.

---

## 3. Functions: money, Pro, push, schedules, audit

### Secrets and config

```sh
cd functions && npm install && cd ..

firebase functions:secrets:set XENDIT_SECRET_KEY        # xnd_development_… first
firebase functions:secrets:set XENDIT_CALLBACK_TOKEN    # after step 3

cat > functions/.env <<EOF
APP_SUCCESS_URL=https://your-app.example.com/payment/success
APP_CANCEL_URL=https://your-app.example.com/payment/cancelled
APP_ALLOWED_ORIGINS=https://your-app.example.com,http://localhost:8777
EOF
```

`functions/.env` is deployed with the code and **tracked in git**, so whoever
deploys has it; only non-secret URLs go in it. The two Xendit values are
Firebase secrets and never touch the repo. Edit the URLs in the committed
file rather than creating a local one.

### Deploy

```sh
firebase deploy --only functions,firestore:rules,firestore:indexes
```

This creates the `api` HTTPS function, the money and push triggers, the
`autoCompleteOrders` schedule, the audit triggers (`auditUsers`,
`auditServices`, `auditOffers`, `auditOrderCreated`, `auditStaff`,
`auditSettings`, `auditCategories`) and, with `IDENTITY_PLATFORM=true`, the
two blocking functions, all in `asia-southeast1`. The first deploy of a
scheduled function enables Cloud Scheduler and may ask you to confirm.

The very first deploy on a project can also fail every Firestore trigger with
"Failed to create function": the Eventarc and Pub/Sub service identities are
created during that deploy and take a minute to propagate. Run the same
deploy again; the second attempt goes through.

The `api` URL is `https://asia-southeast1-<project-id>.cloudfunctions.net/api`.
`GET <url>/health` should answer `{"status":"ok","mode":"test"}`.

### 3. Xendit callback

In the Xendit dashboard (test mode first), go to **Settings → Developers →
Callbacks**, set the **Invoices** callback URL to `<api url>/webhook`, and
copy the **callback verification token** into `XENDIT_CALLBACK_TOKEN`; then
redeploy functions. Xendit sends that token on every delivery as
`x-callback-token`. Without the correct token every delivery is refused with
401, and payments stay `pending` forever.

A test-mode key (`xnd_development_…`) needs no business activation; the
whole flow is demoable with Xendit's test payment simulators for GCash,
cards and the rest. A live key (`xnd_production_…`) needs a verified
business — and, because the platform now holds money, the legal and tax
groundwork in `business_proposal.md` §5.

### 3b. Automated payouts (optional)

1. Enable the **Payouts** product on the Xendit account and fund the
   balance (payouts draw from it, not from incoming payments).
2. In Settings → Developers → Callbacks, set the **Payouts** callback URL to
   the same `<api url>/webhook`.
3. Set `XENDIT_PAYOUTS=auto` in `functions/.env` and redeploy functions.

From then on a student's payout request is sent to their GCash, Maya or
bank account at once; staff only see the ones Xendit refused or could not be
reached for. Leave it at `manual` to keep the staff queue and hand-made
transfers.

### 4. Point the app at it

Nothing to do for this project: production and development builds default
to `PaymentConfig.deployedBackendUrl`, which is
`https://asia-southeast1-student-freelance-services.cloudfunctions.net/api` (the `api` function's URL, printed at the end of
`firebase deploy` and listed under Functions in the console). Another
backend, or none, is a build flag:

```sh
flutter build apk --dart-define=PAYMENTS_API_URL=https://other-host/api
flutter build apk --dart-define=PAYMENTS_API_URL=manual
```

One define. It switches payments to gateway mode and enables payouts, Pro,
featured listings, and the staff queues. Verify by paying a test order: the
payment document should reach `status: paid`, `verified: true`,
`holdStatus: held`. Then accept the delivery and watch `wallets/{freelancer}`
appear with the net amount and a `ledger` entry beside it.

---

## 5. Push

Push works on Android as soon as functions are deployed: the app registers a
token on sign-in (Android 13+ shows the permission dialog) and the trigger
sends to it.

- **iOS**: upload an APNs key under Project settings → Cloud Messaging.
- **Web**: create a Web Push certificate (same page), then build with
  `--dart-define=FCM_VAPID_KEY=<the key>`. `web/firebase-messaging-sw.js`
  is already in place.
- **Windows/Linux**: no FCM. The app detects this and keeps the inbox.

Check it: send yourself a chat message from a second account with the app in
the background. The push carries the same `type`/`conversationId` payload the
inbox row does, and tapping it opens the conversation.

---

## 6. Housekeeping

- **Notification TTL**: Firestore → TTL policies → collection group
  `notifications`, field `expiresAt`. Sixty-day retention, server-side.
- **First admin**: `node tools/seed/seed.js --admin you@example.com --live`
  with a service-account key. Staff decide payouts and verifications; nothing
  else can.
- **Payout runs**: before transferring, open the admin overview and compare
  "Money held" with the Xendit balance. They should agree to the peso; a
  gap is a bug or a theft, and a payout run is the wrong moment to find out.
- **Indexes**: the emulator does not enforce them. The featured strip, the
  payout and verification queues, and the auto-complete sweep each need one;
  they are in `firestore.indexes.json` and deployed above. A query that works
  locally and fails live with `FAILED_PRECONDITION` is always this.

---

## After any change

```sh
flutter analyze && flutter test
cd functions && npm test && cd ..
firebase emulators:start --only firestore     # terminal 1
cd rules-tests && npm test                    # terminal 2
firebase deploy --only functions,firestore:rules,firestore:indexes,storage
```

Rules, indexes, and functions go out **together** with the code that depends
on them. If payments or attachments start answering "You are not allowed to
do that", that string is this app's rendering of `permission-denied`: look at
the rules, and reproduce with the emulator and `rules-tests/` before touching
the live project.
