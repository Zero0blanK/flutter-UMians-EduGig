# student_freelance_services

A Flutter + Firebase marketplace where students can both **hire** and **offer**
freelance services (tutoring, design, programming, …).

The Firebase project is on the **Blaze plan**, and the app uses it for three
things a phone cannot do on its own: hold and move money, store files, and
send push. All three live in `functions/` and Cloud Storage; everything else
still runs from Firestore under security rules.

The app also still runs with **no backend at all** — manual settlement and
in-app notifications only — which is how it is developed against the emulator.
When the Storage emulator is started, chat, delivery, and verification
attachments are exercised locally too. Production and development builds are pointed at the deployed
backend by default (`PaymentConfig.deployedBackendUrl`); `PAYMENTS_API_URL`
overrides it, and `PAYMENTS_API_URL=manual` forces the no-backend path.

## Features

- **UM Google Sign-In only.** No registration: a verified
  `@umindanao.edu.ph` Google account is the one way in. The profile is
  created from the account (name, photo, email); a student-format address
  (`a.nerosa.545679@…`) yields the student number and counts as identity
  verification. Any other account is refused by the app, the rules, the
  backend, and (with Identity Platform) before it exists in Authentication.
- **Flexible pricing.** A listing is fixed-price or a starting price
  (negotiable), and a seller can require a conversation before any order.
  Negotiated jobs are ordered from an **offer card** the freelancer sends in
  chat (price, revisions, duration, scope) and the client accepts; the order
  carries the offer's price, never the listing's. Enforced in rules and
  re-checked by the backend before charging.
- **Role-based staff console.** The main admin holds every permission; staff
  hold a granted list (users, listings, categories, orders, disputes,
  payouts, refunds, verification, reports, settings). Every staff surface,
  rule and backend route asks for the one permission it needs.
- **Audit log.** Sign-ins, profile creation, pricing changes, offers, order
  moves, payments, payouts, staff and settings changes are recorded by the
  backend in `auditLog`, which no client can write.
- Public student profiles with college and programme
- Marketplace: browse, search and filter published services
- Sell: create/edit/publish/pause/archive your own services
- Order lifecycle with an enforced state machine:
  `pending → accepted → in_progress → submitted → completed`
  (+ revision loop, cancel, dispute)
- Realtime chat with unread badges, photos and files (Cloud Storage)
- Deliveries with up to five attached files
- In-app notifications with typed payloads and centralized deep-link routing,
  pushed to registered devices by a Cloud Function (FCM)
- Reviews (one per order, deterministic id); rating totals denormalised onto
  the service and maintained atomically by the reviewer — see [Ratings](#ratings).
  Every listing and every seller has a dedicated reviews page with a star
  breakdown, sort and star filter; service and profile pages show an overview
- **Red Lily design system**: one theme and one component kit
  (`lib/core/widgets/lily.dart`) behind every screen; bottom navigation on
  phones and a rail from 1000px; skeleton loading, empty states with a next
  step, and a pinned action bar on decision screens. See
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#design-system-red-lily)
- Word-level search over derived `keywords`, plus sorting by newest or price
- **Pay in-app, held, released**: the client pays through Xendit, the
  platform holds the money, and it is released to the freelancer's wallet
  (minus a 5% commission) when the work is accepted — or
  refunded if the order is cancelled. Silent clients auto-complete after three
  days. See [Payments](#payments)
- Freelancer wallet with batched payouts settled by staff
- **Pro** (₱99/30 days): up to two featured listings and a verified badge after
  a staff identity check. Commission is never discounted — see [Pro](#pro)
- Staff console: metrics, disputes, listing moderation, payout queue,
  verification queue, append-only audit log

## Project layout

```text
lib/
├── app/            # root app shell, go_router config, theme
├── core/           # firebase bootstrap, errors, constants, shared widgets
├── features/       # auth, services, marketplace, orders, chat,
│   │               # notifications, profile, reviews
│   └── <feature>/  # data/ (repositories) · domain/ (models) · presentation/
└── main.dart

firestore.rules        # authorization boundary — the real access control
storage.rules          # same idea for files: the path carries the question
firestore.indexes.json # composite indexes for all list queries
functions/             # trusted backend: payments, ledger, Pro, push, schedules
```

Dependency direction is strict: **presentation → domain → data → Firebase**.
Widgets never touch Firebase SDKs directly.

## Setup

1. Install dependencies:

   ```sh
   flutter pub get
   ```

2. Generate the client configuration if missing:

   ```sh
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```

3. Enable in the Firebase console:
   Authentication (Email/Password), Cloud Firestore.

4. Link the CLI to your project and deploy the backend pieces. **The indexes
   matter**: sorting and keyword search need composite indexes, and the
   emulator does not enforce them, so a query that works locally will fail
   against a real project until these are deployed.

   ```sh
   firebase use --add          # select your project once
   firebase deploy --only firestore:rules,firestore:indexes
   ```

5. Run it:

   ```sh
   flutter run            # or -d windows / chrome
   ```

## Documentation

| Document | Covers |
| --- | --- |
| [docs/FEATURES.md](docs/FEATURES.md) | What the app does, screen by screen, and what is deliberately absent |
| [docs/DATABASE.md](docs/DATABASE.md) | Every collection, field, rule and index, with the reasoning |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layering, the three-layer enforcement rule, testing |
| [docs/business_proposal.md](docs/business_proposal.md) | The five-point business proposal |
| [functions/README.md](functions/README.md) | The trusted backend: routes, money flow, deployment |
| [docs/PAYMENT_TERMS.md](docs/PAYMENT_TERMS.md) | What a student agrees to before paying; the in-app dialog mirrors it |
| [docs/BLAZE_UPGRADE.md](docs/BLAZE_UPGRADE.md) | Turning the Blaze features on: secrets, webhook, VAPID key, TTL |
| [docs/DEMO_ACCOUNT_FLOW.md](docs/DEMO_ACCOUNT_FLOW.md) | Short setup and account-switching flow for a local demonstration |
| [tools/seed/README.md](tools/seed/README.md) | Demo data, and removing it again |
| [tools/uismoke/README.md](tools/uismoke/README.md) | The headless browser walkthrough |

## Admin

Staff reach `/admin`. Access is `admins/{uid}`, which carries a **role** and
a **permission list**:

- The **main admin** (`role: admin`) holds every permission and manages
  staff. Only a service-account key can create one:

  ```sh
  node tools/seed/seed.js --admin a.nerosa.545679@umindanao.edu.ph --live
  ```

- **Staff** (`role: staff`) are granted from the console's Staff tab by UM
  email, with any subset of: `users.manage`, `services.moderate`,
  `categories.manage`, `orders.manage`, `disputes.resolve`, `payouts.settle`,
  `refunds.handle`, `verification.decide`, `reports.view`, `settings.manage`.
  A staff member sees only the tabs they hold, and `firestore.rules`,
  `storage.rules` and every backend route check the same permission, so the
  tab is a convenience and the rule is the boundary.

Staff actions land in `adminActions` (rule-validated, the actor's own log)
and, together with everything the backend does and every pricing, offer,
order, payment and sign-in event, in `auditLog` (backend-only).

## Demo data

The app is far easier to judge with a marketplace in it. `tools/seed/` fills
the emulator with 7 students, 34 services, 27 orders across every lifecycle
state, settled payments, reviews, and chat history:

```sh
cd tools/seed && npm install && cd ../..
firebase emulators:start --only firestore,auth,storage # terminal 1
node tools/seed/seed.js                          # terminal 2
flutter run --dart-define=APP_ENV=emulator
```

The build's target is `--dart-define=APP_ENV=production|development|emulator`
(default `production`). `development` talks to the real Firebase project like
production but keeps the demo-account selector; seed the real project once
with `node tools/seed/seed.js --live` (service-account key required, reversed
by `--unseed --live`) and run `flutter run --dart-define=APP_ENV=development`.
`emulator` is for the smoke test and rules work.

Choose any seeded student from the demo-account selector (start with Maya
Robles). See `tools/seed/README.md`.

## Development & verification

```sh
flutter analyze          # static analysis (must be clean)
flutter test             # unit + widget tests
```

The payments backend has its own offline suite:

```sh
cd functions && npm install && npm test
```

And the built web app can be driven end to end in headless Chrome against the
seeded emulator, which catches runtime errors and denied queries that static
analysis cannot see:

```sh
cd tools/uismoke && npm install && cd ../..
node tools/uismoke/ui_smoke.js     # see tools/uismoke/README.md
```

### Security rules tests

The rules have their own suite in `rules-tests/` (unauthenticated access,
ownership spoofing, price manipulation, illegal order transitions, chat
membership, duplicate reviews, notification forgery). Run them against the
**emulator only**:

```sh
firebase emulators:start --only firestore   # terminal 1
cd rules-tests && npm install && npm test   # terminal 2
```

## Ratings

Each service carries `ratingSum` and `ratingCount`, so a marketplace page shows
scores with **no extra reads** — the totals arrive with the documents already
being listed. Previously every page load fetched every review of every visible
service.

They are maintained without a trusted server. The reviewer writes the review
and bumps the counters in one atomic batch, and security rules bind the two
together:

- `getAfter()` reads the review as it will exist after the commit, so the
  increment must match the rating actually being written;
- `exists()` / `existsAfter()` prove the review is being *created* in this
  write, so a counter bump cannot be replayed off an older review;
- the review's `reviewerId` must be the caller and its `serviceId` must be this
  service;
- a separate rule forbids the seller touching their own score at all.

`titleLower` and `keywords` are derived from the title in `toFirestore`, and
rules check `titleLower == title.lower()`, so the search index cannot drift
from the text it describes.

## Notification retention

Notifications carry `expiresAt` (60 days). To have them removed automatically,
add a **TTL policy** on `users/{uid}/notifications` for the `expiresAt` field
in the Firebase console — server-side deletion, no Cloud Functions. Until that
policy exists the field is inert and nothing is deleted.

## Pricing and offers

A listing is **fixed-price** or a **starting price** (`pricingMode`), and a
seller may tick **talk to me before ordering** (`requiresContact`). Only a
fixed-price listing without that flag can be ordered directly, at the listed
price. Everything else goes through chat:

1. The client messages the seller from the listing.
2. They agree on scope, price, revisions and timing.
3. The freelancer taps **Send an offer** in the chat and fills in exactly
   those terms; an offer card appears in the conversation (valid 7 days).
4. The client taps **Accept & order**, adds requirements, and the order is
   created *from the offer* — its price, revisions, delivery days and scope
   are the offer's — and the client lands on it for payment.

One offer yields one order: the rules accept an order with an `offerId` only
if the offer is `accepted`, matches every figure, and is marked `ordered`
with that order's id in the same batch. The backend re-derives the same
justification before creating a checkout, so an order whose price is neither
the listing's fixed price nor a spent offer's price is never charged.

## Payments

### Gateway mode (the product)

In gateway mode the client taps **Pay now** after the freelancer accepts,
picks GCash, Maya, a card, or another wallet on a checkout sheet, and the
Xendit invoice page opens in the browser straight on that channel (the
backend restricts the invoice's `payment_methods` to the choice). Xendit's
token-verified callback settles the payment
with `verified: true` and `holdStatus: held`. From there
the backend moves the money in step with the order:

| Order becomes | Money |
| --- | --- |
| `completed` (client, or auto after 3 days of silence) | Released to `wallets/{freelancer}` minus commission, with a `ledger` entry |
| `cancelled` / `rejected` | Refunded through Xendit |
| `disputed` → staff decision | One of the two above |

The freelancer requests a payout from their profile (₱300 minimum, one at a
time) to a GCash, Maya or bank account. With `XENDIT_PAYOUTS=auto` the
backend sends it through **Xendit Payouts** immediately and Xendit's callback
settles it (or returns the money on failure); otherwise, or when Xendit is
unreachable, it waits in the staff queue, where staff send it via Xendit
with one tap or record a transfer made by hand. Every outcome is a ledger
entry.

Guard rails around that flow, each answering a specific way it could go wrong:

- **Terms first.** Before the first checkout the client reads how the hold
  works (`docs/PAYMENT_TERMS.md`) and acceptance is recorded on the profile.
- **Reminder before auto-complete.** A client is notified a day before a
  silent delivery completes on its own.
- **Clearance for new sellers.** A seller's first three releases sit in
  `clearing` for seven days before they can be paid out, so a card chargeback
  filed after the fact has somewhere to land.
- **Account numbers are shape-checked** (GCash/Maya: 11 digits starting 09;
  bank: 10 to 16 digits) in the app, the backend, and the rules, because a
  typo is a mis-sent payout.
- **Refunds that fail are a queue, not a log line.** Staff retry through the
  gateway or record a refund made by hand, and are notified when one lands.
- **Money held is reconciled on the admin overview**: held on orders, plus
  every wallet balance, equals what must be payable on demand.
- **Age gate.** Selling and payouts need a birth date showing 18+, set once
  at sign-up and pinned by rules; buying is open to everyone.
- **ID photos are deleted** the moment staff decide a verification.

### Manual mode (no backend)

Without a backend the app runs with no server, no gateway account, and no
card:

1. Once the freelancer accepts, the client taps **Pay now** and records a
   reference (a GCash reference number, say).
2. The **freelancer** — the party who actually received the money — confirms
   receipt. The payer cannot confirm their own payment; otherwise the record
   would assert nothing.
3. Only then can the freelancer start work.

Every order carries a 5% platform commission, split with integer arithmetic so
`commission + netToFreelancer` always equals the gross exactly. Payments live at
`payments/{orderId}` — the document id *is* the order id, so an order can never
accumulate two payment records.

Manual records are always `verified: false`, and the UI says "Confirmed by the
freelancer" rather than showing a gateway receipt. An attestation and a proof
must not look alike.

### Turning gateway mode on

Deploy `functions/` and point the app at it:

```sh
firebase deploy --only functions,firestore:rules,firestore:indexes,storage
flutter run            # production builds use the deployed api by default
flutter run --dart-define=PAYMENTS_API_URL=https://other-host/api   # override
```

The deployed URL is `https://asia-southeast1-student-freelance-services.cloudfunctions.net/api` (also printed as the `api` function URL at the end
of `firebase deploy`, and shown under Functions in the Firebase console).
Gateway mode enables
payouts, Pro, and the staff queues; no application code changes. The Xendit
secret key never reaches the app — it cannot, since an APK decompiles and a
web build ships readable JavaScript. The backend holds it, re-derives every
amount from the trusted Firestore document, and is the only writer permitted
to set `verified`, `holdStatus`, wallet balances, `proUntil`,
`identityVerified`, or `featuredUntil`. See `functions/README.md`.

## Pro

₱99 buys 30 days, paid up front through the same checkout, no auto-renewal.
It buys two things and nothing else:

- **Featured listings** — up to two of the seller's published listings are
  pinned above organic results in their category and search, at most three
  per page, rotated among subscribers. Pinned cards say "Featured by Pro
  sellers" and carry a pin; a buyer is never left guessing which cards are
  paid.
- **Verified badge** — the check mark certifies a *staff identity check*
  (student ID photo plus school email, reviewed in the admin console), and it
  shows only while Pro is active. Paying does not buy the badge; it pays for
  the check and keeps it current.

Commission stays at 5%. A discount for the most active sellers would cut the
primary revenue stream exactly where it is largest.

## Push notifications

Every inbox document under `users/{uid}/notifications` — whether the client
wrote it (chat, order events, validated by rules) or the backend did (money,
payouts, Pro, verification) — is pushed by `onNotificationCreated` to the
tokens registered under `users/{uid}/devices`. The app registers its token on
sign-in, forgets it on sign-out, and routes a tapped push through the same
`NotificationRouter` an inbox tap uses. Dead tokens are pruned on send.

Web push needs a VAPID key: `--dart-define=FCM_VAPID_KEY=...` and the
`web/firebase-messaging-sw.js` worker. Windows and Linux have no FCM and keep
the in-app inbox only.

## Attachments

Chat messages carry one photo or file (10 MB); deliveries carry up to five
(25 MB each); a verification request carries one ID photo (5 MB, staff-only).
Files live in Cloud Storage under the conversation, order, or user they belong
to, and `storage.rules` asks Firestore whether the caller is entitled to that
parent. Upload happens before the Firestore write, so a message can never
point at a file that failed to upload. Nothing is deletable from a client:
chat and delivery files are dispute evidence.

## Security model (summary)

- All authorization lives in `firestore.rules`; client-side checks are UX only.
  Default-deny for anything not explicitly allowed.
- Order price/participants/status are frozen after creation; transitions are
  constrained per role by rules mirroring the Dart state machine.
- Notification creation is validated per type in rules: senders must be
  conversation participants, order participants, or the buyer of the completed
  order being reviewed. Recipients can only flip `read`.
- Review document ids equal order ids → duplicate reviews are impossible;
  ratings are derived from these immutable documents, never client-stored.
- Payment amounts and the commission split are frozen at creation and must
  reconstitute the gross exactly; `verified`, `holdStatus`, and
  `gatewayReference` are server-owned and unreachable from any client; only the
  freelancer may confirm a manual payment; payment records can never be
  deleted, so dispute evidence survives.
- Wallet balances, the ledger, payouts, and subscriptions are written only by
  the backend, in transactions that append a ledger entry; the owner may write
  their payout account and nothing else.
- `proUntil`, `identityVerified`, and `featuredUntil` are server-owned; a
  profile or listing edit must carry them through unchanged.
- Storage paths are scoped to the parent document's participants, size-capped
  in rules, and never client-deletable.
- `birthDate` is set once and immutable; creating or publishing a listing
  requires it to show 18+, checked in rules against `request.time`.
