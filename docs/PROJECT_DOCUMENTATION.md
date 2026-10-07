# Student Freelance Services: Codebase Documentation

This document explains the structure and behavior of the Student Freelance Services project. It is intended for developers, maintainers, testers, and project reviewers who need to understand where code belongs and how the application works as a whole.

The project is a Flutter application backed by Firebase. Students from the University of Mindanao can publish freelance services, discover services, communicate with one another, negotiate offers, place orders, exchange deliveries, review completed work, receive payments, and manage a wallet. Staff members have a separate administration console for moderation, disputes, reports, verification, refunds, and payouts.

The main implementation is in Dart under `lib/`. Trusted operations that cannot safely be performed by a client are implemented in Node.js under `functions/`. Firestore and Storage rules are part of the security boundary and must be considered application code.

## Technology overview

| Area | Technology | Purpose |
| --- | --- | --- |
| Client | Flutter and Dart | Cross-platform mobile, desktop, and web application |
| UI navigation | `go_router` | Authentication redirects and application routes |
| State management | `provider` | Provides repositories and controllers to screens |
| Authentication | Firebase Authentication and Google Sign-In | UM account sign-in and session management |
| Database | Cloud Firestore | Users, services, orders, chats, payments, reviews, and administration data |
| File storage | Firebase Storage | Delivery and chat attachments |
| Push notifications | Firebase Cloud Messaging | Notifications while the app is in the background |
| Trusted backend | Node.js, Express, Firebase Admin SDK, Cloud Functions | Payments, wallet operations, Pro entitlements, staff actions, and scheduled work |
| Payment gateway | Xendit, through the backend | Gateway checkout, webhooks, and payouts |
| Local development | Firebase Emulator Suite | Local Auth, Firestore, Storage, and Functions |
| Testing | Flutter tests, Node tests, rules tests, and browser smoke tests | Domain, backend, security, and runtime validation |

The client supports two payment modes. Emulator builds use manual settlement so the application can be demonstrated without gateway credentials. Development and production builds use the deployed backend and Xendit unless `PAYMENTS_API_URL=manual` is supplied at build time. Xendit secrets are kept in the backend and are never placed in the Flutter application.

## Repository structure

The following tree shows the source and operational directories. Generated output, package caches, and platform-specific build products are intentionally omitted from the conceptual structure.

```text
student_freelance_services/
├── lib/                         Flutter application source
│   ├── main.dart                Application bootstrap and dependency wiring
│   ├── firebase_options.dart    Generated Firebase platform configuration
│   ├── app/                     App shell, routes, and theme
│   ├── core/                    Shared infrastructure and reusable UI
│   └── features/                Business features, split by responsibility
├── functions/                   Trusted Node.js backend and payment API
├── test/                        Flutter unit and widget tests
├── rules-tests/                 Firestore and Storage security-rule tests
├── tools/
│   ├── seed/                    Demo data seeder
│   ├── uismoke/                 Headless browser walkthrough
│   └── *.mjs, *.py, *.ps1       Development and documentation utilities
├── assets/                      Fonts and image assets bundled with Flutter
├── docs/                        Architecture, feature, database, and project docs
├── android/                     Android host project
├── ios/                         iOS host project
├── macos/                       macOS host project
├── linux/                       Linux host project
├── windows/                     Windows host project
├── web/                         Web host files and platform entry point
├── firestore.rules              Firestore authorization and write validation
├── storage.rules                Storage authorization and file validation
├── firestore.indexes.json       Composite indexes required by Firestore queries
├── firebase.json                Firebase emulators, hosting, rules, and Functions config
├── pubspec.yaml                 Flutter dependencies, assets, and fonts
├── analysis_options.yaml        Dart analyzer and lint configuration
└── README.md                    Quick project introduction
```

### Root-level folders and files

`lib/` is the application source. It contains the Flutter entry point, dependency registration, screens, repositories, domain models, shared infrastructure, and reusable widgets.

`functions/` is the trusted server-side portion of the project. It uses the Firebase Admin SDK and can bypass Firestore client rules, so it is responsible for validating privileged operations before changing financial, identity, entitlement, or moderation data.

`test/` contains Dart tests for domain logic, feature behavior, routing, state transitions, and selected widget flows. These tests run without requiring a live Firebase project for the cases that are pure or mocked.

`rules-tests/` tests the actual Firestore and Storage authorization boundary against the Firebase Emulator Suite. A passing client test does not replace a passing rules test because a modified client can skip UI and repository checks.

`tools/seed/` creates realistic emulator or development data: users, services, orders, payments, reviews, conversations, and featured listings. The default target is the emulator. Live seeding requires an explicit live command and a service-account credential that must remain outside the repository.

`tools/uismoke/` drives the built Flutter web application with headless Chrome. It verifies that the application boots, authenticates, loads real seeded data, navigates through major screens, and does not produce runtime errors that static analysis cannot detect.

`assets/` contains bundled visual assets and the Bricolage Grotesque and Plus Jakarta Sans font files configured in `pubspec.yaml`.

`docs/` contains design and project documentation. The most relevant companion documents are [`ARCHITECTURE.md`](ARCHITECTURE.md), [`FEATURES.md`](FEATURES.md), [`DATABASE.md`](DATABASE.md), [`PAYMENT_TERMS.md`](PAYMENT_TERMS.md), and [`DEMO_ACCOUNT_FLOW.md`](DEMO_ACCOUNT_FLOW.md).

The platform directories (`android`, `ios`, `macos`, `linux`, `windows`, and `web`) are Flutter host projects. They provide platform runners, native configuration, permissions, and build integration. Business behavior should remain in `lib/` unless a platform-specific integration requires native code.

`build/`, `.dart_tool/`, `.gradle-user-home/`, and package `node_modules/` directories are generated or cached artifacts. They are useful while building or testing but are not source modules and should not be used as the basis for architectural changes.

## Flutter application architecture

The application follows a feature-first structure with three layers inside most features:

```text
feature/
├── data/          Firebase queries, repositories, gateways, and persistence adapters
├── domain/        Plain models, enums, policies, and business rules
└── presentation/ Screens, dialogs, page-specific widgets, and view behavior
```

The intended dependency direction is:

```text
presentation  →  domain  →  data  →  Firebase or trusted backend
```

In practice, screens obtain repositories through `provider`; repositories translate Firestore or HTTP data into domain objects; domain code defines rules that can be tested without a database; and shared infrastructure owns common integration details. Widgets should not perform raw Firestore reads or import Firebase SDKs directly.

### `lib/app/`

`lib/app/app_shell.dart` defines the authenticated application shell. It provides the main destinations—Home, Orders, Messages, and Me—using a bottom navigation bar on smaller screens and a navigation rail on wider screens. It also maintains session-wide notification and platform-settings listeners.

`lib/app/router/` contains the `go_router` configuration. It handles login and onboarding redirects, the authenticated route tree, deep links from notifications, and routes for services, orders, chats, payments, wallets, Pro, profiles, reviews, and administration. Static routes are declared before parameterized routes where matching order matters.

`lib/app/theme/` owns the visual system. `app_theme.dart` defines light and dark themes, color roles, typography, radii, and component defaults. `theme_controller.dart` persists the selected appearance, while `appearance_card.dart` exposes the setting to the profile area.

### `lib/core/`

`core` contains code shared by multiple features. It should only receive code when that code has a stable cross-feature purpose.

| Folder | Responsibility | Important files |
| --- | --- | --- |
| `core/backend/` | Authenticated HTTP access to the trusted backend | `backend_client.dart` |
| `core/config/` | Build and runtime environment selection | `app_environment.dart` |
| `core/constants/` | Shared paths and closed lists used by client and rules | `firestore_paths.dart`, `academics.dart` |
| `core/errors/` | User-safe application failure types | `app_failure.dart` |
| `core/platform/` | Platform-level settings stored in Firestore | `platform_repository.dart` |
| `core/storage/` | Cloud Storage uploads, attachment metadata, and previews | `storage_repository.dart`, `attachment.dart`, `attachment_view.dart`, `video_attachment_view.dart` |
| `core/utils/` | Reusable validation and feedback helpers | `validators.dart`, `feedback.dart` |
| `core/widgets/` | Shared layout, loading, error, status, rating, identity, and pagination widgets | `lily.dart`, `status_views.dart`, `paginated_list.dart` |

`core/constants/firestore_paths.dart` is the client-side source of truth for collection names and common document paths. The same layout is mirrored by `firestore.rules`; changing a path requires checking both sides.

`core/backend/backend_client.dart` is the single client entry point for the trusted backend. It attaches the current Firebase ID token and sends identifiers or validated request data. It should not contain gateway secrets or business decisions that require server trust.

`core/storage/storage_repository.dart` is the single application boundary for Firebase Storage. This keeps upload paths, metadata, and attachment handling out of feature screens.

### `lib/features/`

Each feature owns a user-facing capability and its related models and persistence code. The feature modules are described below.

| Feature | What it is used for | Main code areas |
| --- | --- | --- |
| `auth` | UM identity, sign-in, onboarding, profile creation, birth date, academic information, and session state | `auth_repository.dart`, `auth_controller.dart`, `um_account.dart`, `user_profile.dart`, login and onboarding screens |
| `marketplace` | Browse published services, search, filters, pagination, featured listings, and service detail pages | `marketplace_screen.dart`, `service_detail_screen.dart`, `people_search_repository.dart`, featured-session models and widgets |
| `services` | Create, edit, publish, pause, archive, and manage a student's own listings | `service_repository.dart`, `freelance_service.dart`, `my_services_screen.dart`, `edit_service_screen.dart` |
| `offers` | Negotiate a custom scope, price, delivery period, and revisions inside a conversation | `offer_repository.dart`, `offer.dart`, offer cards and send-offer dialog |
| `orders` | Create orders, track roles and status, submit deliveries, request revisions, complete, cancel, reject, or dispute work | `order.dart`, `order_transitions.dart`, `delivery.dart`, `order_repository.dart`, order screens |
| `payments` | Represent payment records, calculate commission, select manual or gateway settlement, and show payment history | payment domain models, repositories, gateways, checkout and return screens |
| `wallet` | Show earnings and ledger movements, save payout accounts, and request payouts | `wallet.dart`, `wallet_repository.dart`, wallet and payout-account screens |
| `pro` | Purchase a 30-day Pro subscription and manage Pro-only featured listings | `subscription.dart`, `pro_policy.dart`, `pro_repository.dart`, Pro screens and cards |
| `reviews` | Create and display reviews and rating summaries for services and profiles | `review_repository.dart`, review screens, overview, and tile widgets |
| `chat` | Create deterministic two-person conversations, stream messages, send text, and attach files | `chat_models.dart`, `chat_repository.dart`, conversation and chat screens |
| `notifications` | Store an in-app inbox, register devices for push notifications, and route notification taps to destinations | `notification_repository.dart`, `push_service.dart`, `notification_router.dart`, notifications screen |
| `profile` | Display and edit the private profile hub and public student profile | profile screens and public-profile screen |
| `admin` | Gate staff access and provide moderation, reports, verification, order/dispute review, refunds, payout actions, and platform management | `admin_access.dart`, `admin_repository.dart`, admin screens and dispute review |

The `services` and `marketplace` features are deliberately separate. `services` owns the seller's listing lifecycle, while `marketplace` owns discovery and buyer-facing presentation. `orders` owns the transaction lifecycle, while `payments` owns payment records and settlement integration. This keeps a screen from becoming responsible for unrelated business areas.

## Application startup and dependency wiring

`lib/main.dart` is the composition root:

1. Flutter bindings are initialized.
2. Firebase is initialized using `firebase_options.dart`.
3. Emulator builds redirect Auth, Firestore, and Storage to configured emulator ports.
4. Firebase services and repositories are constructed.
5. `PaymentConfig` selects manual or Xendit mode.
6. `AuthController`, `ThemeController`, push registration, and the router are initialized.
7. Repositories and controllers are exposed through `MultiProvider`.
8. `MaterialApp.router` starts the themed application.

The application keeps one instance of long-lived repositories for the session. Authentication state drives routing, and push registration follows sign-in and sign-out. Foreground notification banners are read from the Firestore inbox stream; Firebase Messaging handles background delivery and notification taps.

## Feature behavior and important flows

### Identity and access

The application accepts University of Mindanao student identities. A student-format UM address provides the student identity used by the application. Profiles store academic information, skills, and a birth date. Selling and payouts require an adult profile; buying remains available to signed-in students.

Staff access is separate from ordinary authentication. The presence and permissions of `admins/{uid}` determine which administrative functions are available. The client hides unavailable actions, but Firestore rules and the backend enforce the permission boundary.

### Service discovery and selling

A student creates a service with a title, description, category, skills, price, turnaround, and revision count. A service progresses through draft, published, paused, and archived states. Published services appear in the marketplace, where users can search, filter, sort, paginate, open details, review the seller profile, message the seller, or place an order when the service supports direct ordering.

Services that require contact first use the offer flow instead of direct checkout. Featured listings are managed through the Pro feature and rotated by trusted backend logic so the marketplace does not permanently favor one seller.

### Offers and orders

An offer is created in chat by a freelancer and contains the negotiated price, delivery days, revisions, and scope. The client can accept or decline it. Acceptance creates an order with the offer's terms.

Direct orders copy the service terms inside a transaction. The order state machine is represented in `order_transitions.dart` and checked by the UI, repository, and security rules:

```text
pending → accepted → inProgress → submitted → completed
                                      └──────→ revisionRequested → submitted

Other terminal or exceptional states: rejected, cancelled, disputed
```

The order participant's role determines which transitions they may perform. Deliveries contain notes and Storage-backed attachments. A buyer can accept the delivery, request a revision, or dispute an order. Submitted work can auto-complete after the configured deadline when the buyer does not respond.

### Payments, wallet, and Pro

Payment records are associated with orders and retain gross amount, commission, net amount, method, and status. The current backend policy charges a 5% commission using integer peso arithmetic; the backend copy in `functions/policy.js` is authoritative for settlement and the Dart policy is used for client previews.

Manual payment records are an in-app attestation by the freelancer who received the external payment. Gateway payments are created and verified by the backend through Xendit. Webhook handling, payment reconciliation, refunds, holds, releases, and payouts remain server-side because a client cannot be trusted with those decisions.

Released earnings appear in the wallet ledger. A payout requires a valid GCash, Maya, or supported bank account and a minimum available balance. The first releases for a new seller can remain in a clearance period. The backend ledger functions keep balance changes append-only and handle payout completion, rejection, and chargeback effects.

Pro is a prepaid 30-day entitlement. A Pro seller can feature up to two published listings. The trusted backend activates the entitlement after confirmed payment and the featured-rotation logic controls fair marketplace exposure.

### Chat and notifications

Two-person conversation IDs are deterministic: participant IDs are sorted and joined, so both participants address the same conversation. Messages are streamed from Firestore and can contain text or Storage attachments. Offers are represented as structured chat content and become orders when accepted.

Notifications are persisted in the user's inbox. Device tokens are registered after sign-in, push messages can be delivered while the app is backgrounded, and notification data is routed through `NotificationRouter` to the same application routes used by in-app navigation.

### Administration

The admin area is protected by `AdminGate` and the staff access model. Depending on permissions, staff can inspect metrics and sales exports, manage users and services, review verification requests, inspect order and dispute chats, process refunds or chargebacks, and manage payout queues. Privileged money movement is sent through `BackendClient`; ordinary reporting and read-only moderation data uses `AdminRepository` and Firestore.

## Firebase data and security boundaries

The principal Firestore collections are:

```text
users/{uid}
users/{uid}/devices/{token}
users/{uid}/notifications/{notificationId}
services/{serviceId}
orders/{orderId}
conversations/{conversationId}/messages/{messageId}
reviews/{reviewId}
offers/{offerId}
payments/{orderId}
wallets/{uid}
wallets/{uid}/ledger/{entryId}
payouts/{payoutId}
subscriptions/{uid}
admins/{uid}
verificationRequests/{uid}
auditLog/{entryId}
settings/platform
```

`firestore.rules` is the authorization boundary for client access. It validates authentication, ownership, immutable fields, allowed field shapes, role permissions, order transitions, payment constraints, and staff permissions. `storage.rules` applies the equivalent boundary to uploaded files.

`firestore.indexes.json` defines composite indexes for query shapes that Firestore cannot serve from single-field indexes. When a new query adds a filter and sort combination, check the index file and deploy it with the application.

The application uses three layers of enforcement:

1. Screens present only actions that should be legal in the current state.
2. Repositories validate again and use transactions where values or state could race.
3. Firestore rules and trusted backend code reject invalid or forged requests even when the client is modified.

The third layer is the security boundary. UI behavior is helpful, repository checks protect normal application flows, and rules/backend validation protect the data.

## Backend structure

| File | Responsibility |
| --- | --- |
| `functions/index.js` | Firebase Functions exports and deployment entry point |
| `functions/server.js` | Express host for the same backend app outside the Functions runtime |
| `functions/xendit.js` | Gateway client and callback signature handling |
| `functions/ledger.js` | Wallet, holds, releases, payouts, chargebacks, and Pro ledger operations |
| `functions/featured-rotation.js` | Fair selection and rotation of featured listings |
| `functions/dispute-chat.js` | Trusted access to staff dispute-chat snapshots |
| `functions/push.js` | Push notification delivery helpers |
| `functions/public-identity.js` | Public identity/profile synchronization helpers |
| `functions/backfill-public-users.js` | One-time or maintenance backfill for public user data |
| `functions/audit.js` | Audit event helpers |
| `functions/policy.js` | Server-side business constants and pure validation/money logic |
| `functions/test-helpers.js` | Test dependencies and fakes |
| `functions/*.test.js` | Backend and ledger tests |

The backend receives authenticated requests from the Flutter client, derives sensitive values from Firestore, and performs operations such as creating or synchronizing invoices, handling signed callbacks, applying payment outcomes, releasing holds, activating Pro, and completing payouts. The backend should accept IDs and user intent, then re-read authoritative records before performing a privileged write.

## Testing and development workflow

Install Flutter dependencies with `flutter pub get`. Install Node dependencies separately in `functions/`, `tools/seed/`, and `tools/uismoke/` when using those tools.

The standard checks are:

```sh
flutter analyze
flutter test

cd functions
npm test
cd ..

cd rules-tests
npm test
cd ..
```

For an emulator-based walkthrough:

```sh
firebase emulators:start --only firestore,auth,storage,functions
node tools/seed/seed.js --wipe
flutter run --dart-define=APP_ENV=emulator
```

For the browser smoke test, build the web app for the emulator, start the emulator and seed data, serve `build/web`, and run `node tools/uismoke/ui_smoke.js`. The detailed sequence and environment notes are in [`tools/uismoke/README.md`](../tools/uismoke/README.md) and [`tools/seed/README.md`](../tools/seed/README.md).

Before deploying a change that touches Firebase behavior, run the relevant Dart, backend, and rules tests together. Deploy functions, rules, indexes, and the client behavior as one compatible change when a new field, query, trigger, or privileged operation requires all of them.

## How to choose a location for new code

Use the following decision process:

1. If the code is a complete user-facing capability, create or extend a folder under `lib/features/<name>/`.
2. If it is a Firestore query, HTTP call, gateway adapter, or persistence concern, place it in that feature's `data/` folder.
3. If it is a database-independent model, state machine, validator, or policy, place it in `domain/`.
4. If it is a screen, dialog, or feature-specific widget, place it in `presentation/`.
5. If several unrelated features use it and it has a stable contract, place it in `lib/core/` under the narrowest matching folder.
6. If it needs Admin SDK privileges, a secret, a signed webhook, a scheduled trigger, or authoritative money/entitlement logic, implement it in `functions/`.
7. If it changes authorization or file access, update and test `firestore.rules` or `storage.rules` as part of the same change.
8. If it introduces a new compound query, check `firestore.indexes.json` and add rules coverage for the query.

Avoid putting business logic into `main.dart`, navigation files, or reusable widgets. Keep generated configuration and build output out of feature folders. Add a focused test near the layer whose behavior it protects, and add a rules test when the behavior affects authorization.

## Existing documentation map

- [`ARCHITECTURE.md`](ARCHITECTURE.md): design system, dependency direction, routes, state management, security layers, and deployment notes.
- [`FEATURES.md`](FEATURES.md): user-facing behavior and feature-specific implementation locations.
- [`DATABASE.md`](DATABASE.md): Firestore collections, document fields, and data relationships.
- [`PAYMENT_TERMS.md`](PAYMENT_TERMS.md): payment language and user-facing settlement terms.
- [`DEMO_ACCOUNT_FLOW.md`](DEMO_ACCOUNT_FLOW.md): demo account and presentation flow.
- [`BLAZE_UPGRADE.md`](BLAZE_UPGRADE.md): Firebase billing and deployment considerations.
- [`functions/README.md`](../functions/README.md): backend operation and gateway details.
- [`tools/seed/README.md`](../tools/seed/README.md): demo-data setup and cleanup.
- [`tools/uismoke/README.md`](../tools/uismoke/README.md): browser smoke-test setup and coverage.

