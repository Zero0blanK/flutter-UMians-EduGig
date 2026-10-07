# Business Proposal — Student Freelance Services

A Flutter + Firebase mobile marketplace for student freelance work.

> Answers the five required points: Business Idea, Problem & Solution,
> Target Customers, Main Features, and Business & Revenue Model.

---

## 1. Business Idea

**Student Freelance Services** is a campus-focused freelance marketplace where
students can both **hire** and **be hired** for skill-based work.

Any registered student can publish a service listing (a "gig") with a title,
description, category, starting price, delivery time, and included revision
count. Any other student can browse those listings, place an order, chat with
the freelancer, receive the work, and leave a review.

The product is a single Flutter application backed by Firebase
(Authentication + Cloud Firestore). It runs on Android, iOS, web, and desktop
from one codebase.

The service catalogue is organised into eight fixed categories
(`lib/core/constants/firestore_paths.dart`):


| Category          | Category      |
| ----------------- | ------------- |
| Tutoring          | Video Editing |
| Graphic Design    | Photography   |
| Writing & Editing | Music & Audio |
| Programming       | Other         |

Every account is simultaneously a buyer and a seller — there is no separate
"freelancer account" to sign up for. This is a deliberate design decision
recorded in `lib/features/auth/domain/user_profile.dart`: a student who pays for
a logo this week can sell tutoring next week without creating a second identity.

---

## 2. Problem & Solution

### The problem

Students constantly need small pieces of paid work done — a thesis proofread, a
poster for an org event, a tutor before finals week, a video edited for a
defence presentation. At the same time, many students already have exactly those
skills and need income that fits around class schedules.

Today those two groups find each other through **Facebook groups, group chats,
and word of mouth**, which fails in four specific ways:

1. **No discovery.** Offers scroll away in a feed within hours. There is no way
   to search "programming tutor under ₱500."
2. **No trust signal.** A buyer cannot tell a reliable freelancer from a
   first-timer. Testimonials are screenshots, easily faked.
3. **No structure or accountability.** "Sending it later" has no defined
   meaning. There is no agreed record of what was ordered, at what price, with
   how many revisions, by when.
4. **Disputes have no process.** When work arrives late or wrong, both parties
   argue in a chat thread with no shared record of the agreement.

Professional platforms (Upwork, Fiverr) solve these problems but are a poor fit
for students: global competition, minimum-price expectations, payout
requirements students often cannot meet, and fees sized for full-time
professionals.

### How the Flutter application solves it


| Problem           | Solution in the app                                                                                                                                      | Where it lives                                      |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| No discovery      | Searchable, filterable marketplace of published services by category, keyword, and price                                                                 | `lib/features/marketplace/`                         |
| No trust signal   | Reviews permanently bound to completed orders — one review per order, id-locked so it can never be duplicated or faked                                  | `lib/features/reviews/`, `firestore.rules`          |
| No structure      | Every order freezes the agreed price, currency, delivery days, revision count, and requirements at creation; these fields can never be edited afterwards | `lib/features/orders/domain/order.dart`             |
| No accountability | A strict order state machine, enforced in three independent layers, defines exactly what each party may do at each stage                                 | `lib/features/orders/domain/order_transitions.dart` |
| Disputes          | Either party can move an active order to`disputed`, freezing it with the full order record and chat history intact                                       | `kOrderTransitions`                                 |

The **order state machine** is the core of the solution. The agreed lifecycle is:

```text
pending → accepted → in_progress → submitted → completed
                                       ↑ ↓
                              revision_requested
```

with `rejected`, `cancelled`, and `disputed` as terminal exits. Crucially, each
transition is restricted to the party entitled to make it — only the freelancer
can accept or submit; only the client can mark work complete or request a
revision (`kTransitionActors`).

This is enforced **three times over**, so it cannot be bypassed by a modified
client:

1. The UI only renders buttons for legal actions.
2. The repository re-validates the transition inside a Firestore transaction.
3. Firestore security rules reject any illegal write server-side.

A freelancer therefore cannot silently mark their own work "completed," and a
client cannot alter the price after the freelancer has agreed to it. The
informal arrangement students currently rely on becomes an enforced contract.

---

## 3. Target Customers

The platform serves one community with two roles, and every user can occupy
both.

### Primary — student buyers

College and senior-high students who need short, paid, deadline-bound work:
thesis and manuscript proofreading, tutoring in a specific subject, posters and
publication materials for student organisations, presentation and defence video
editing, event photography, and coding help for programming subjects.

They are price-sensitive, deadline-driven, and already accustomed to hiring
peers informally.

### Primary — student freelancers

Students with a marketable skill who want income that fits around a class
schedule — design, programming, writing, video, photography, music, and
tutoring. They typically cannot commit to fixed part-time hours and are
uncompetitive on global platforms, but are well-matched to peer-scale work.

### Secondary

- **Student organisations and councils** commissioning event materials — the
  highest-value recurring buyers.
- **Faculty and campus offices** needing small design or documentation jobs.

### Why the campus is the right beachhead

Pricing is anchored in Philippine pesos (`PHP` is the default currency on both
`FreelanceService` and `WorkOrder`) at peer-affordable levels. Shared campus
identity supplies the social accountability that anonymous global marketplaces
must buy with expensive escrow and arbitration systems — a freelancer who
delivers badly faces a classmate, not an anonymous review.

---

## 4. Main Features

The application is organised into nine feature modules under `lib/features/`.
Six are summarised here; the required minimum is three.

### 4.1 Marketplace with search and filtering

Browse every published service, filtered by category, keyword, and price. Only
listings whose status is `published` are visible; drafts, paused, and archived
listings never reach the marketplace. Sellers control this lifecycle themselves
— `draft → published → paused → archived` — so a freelancer overloaded during
exam week can pause listings without deleting them.

*Module:* `lib/features/marketplace/`, `lib/features/services/`

### 4.2 Order lifecycle with an enforced state machine

The accountability layer described in section 2. An order captures the agreed
terms at creation and freezes them permanently: price, currency, delivery days,
revision count, participants, and written requirements. It then advances only
through legal transitions, only by the entitled party, verified in the UI, in a
database transaction, and in server-side security rules.

Includes an explicit revision loop (the client returns submitted work for
changes) and a dispute exit available to both parties.

*Module:* `lib/features/orders/`

### 4.3 Realtime chat

Text messaging between a client and a freelancer, with unread badges and live
streaming updates. Conversation ids are deterministic — the two user ids sorted
and joined — which guarantees exactly one conversation per pair no matter who
messages first, so duplicate threads are structurally impossible
(`FirestorePaths.conversationIdFor`).

*Module:* `lib/features/chat/`

### 4.4 Reviews and ratings

A review can only be written by the buyer of a completed order, and the review
document's id **is** the order id. Duplicate or fabricated reviews are therefore
impossible at the database level rather than merely discouraged. Rating averages
are computed server-side with aggregate queries over these immutable documents,
never stored on the profile where a client could tamper with them.

*Module:* `lib/features/reviews/`

### 4.5 In-app notifications with deep linking

Typed notification payloads (new order, status change, new message, review
received) delivered as Firestore documents over realtime streams, with
centralised deep-link routing that opens the exact order or conversation
referenced. Security rules validate every notification against its type —
senders must genuinely be a participant in the conversation or order concerned,
and a recipient may only mark a notification read, never create one.

*Module:* `lib/features/notifications/`

### 4.6 Payments with an enforced platform commission

Each order carries a payment record holding the gross amount, the 10% platform
commission, and the freelancer's net payout. The split uses integer arithmetic
so the two parts always reconstitute the gross exactly — no centavo drift.
Work cannot start until payment is settled, which is what makes the commission
a real revenue stream rather than an aspiration.

Payment records use the same deterministic-id trick as reviews (`payments/ {orderId}`), so an order can never accumulate two of them. Amounts are frozen
at creation, records can never be deleted, and the fields that mean "a gateway
proved this" are unreachable from any client.

*Module:* `lib/features/payments/`, `functions/`

### Supporting features

Email/password authentication with email verification, public student profiles
carrying a bio and skill list, a lifetime earnings summary derived from settled
payments, and text-based work delivery.

---

## 5. Business & Revenue Model

The platform earns in two ways: a **commission on every order paid through the
app**, and an optional **Pro subscription** that buys visibility and a verified
badge — and nothing else. Neither stream discounts the other.

### How money moves: pay in-app, hold, release

Payment happens **inside the app, before work starts**, the way a food-delivery
order is paid before the kitchen begins — with one difference that matters:
the money is not handed to the freelancer at the moment of payment. It is
**held by the platform** until the client accepts the delivered work, then
released minus commission.

The flow maps onto the existing order state machine one step per transition:


| Step                        | Order state                  | What happens to the money                                                                                                  |
| --------------------------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| 1. Client places an order   | `pending`                    | Nothing yet — the freelancer has not agreed                                                                               |
| 2. Freelancer accepts       | `accepted`                   | Client is asked to pay the frozen price in-app (card, GCash, Maya via Xendit)                                            |
| 3. Gateway confirms payment | `accepted` → *paid*         | Gross amount lands in the platform's merchant account.`payments/{orderId}` is written by the backend with `verified: true` |
| 4. Work proceeds            | `in_progress` → `submitted` | Funds stay held. Neither party can touch them                                                                              |
| 5. Client accepts the work  | `completed`                  | Commission is retained; the freelancer's net is credited to their payout balance                                           |
| 6. Client requests changes  | `revision_requested`         | Still held. Loops back to`submitted`                                                                                       |
| 7. Either party disputes    | `disputed`                   | Frozen until an admin resolves it: full release, full refund, or a split                                                   |
| 8. Cancelled after payment  | `cancelled`                  | Refunded to the client through the gateway                                                                                 |
| 9. Client never responds    | `submitted` for N days       | **Auto-completes** and releases — the freelancer cannot be held hostage by silence                                        |

Step 9 does not exist in the app today: completion is only ever triggered by
the client (`kTransitionActors`). It has to be added, and it has to run on the
backend on a schedule, because a client who simply closes the app must not be
able to keep a freelancer unpaid indefinitely. Food-delivery apps solve exactly
this with automatic order completion.

Freelancers are paid out of their balance **in batches** (weekly, above a
minimum threshold) to GCash or a bank account — not per order. The reason is
in the cost table below.

#### Why this needs a server, and why it does not need a paid Firebase plan

Two facts make the flow impossible to run purely from the Flutter client:

1. **The gateway secret key cannot ship in an app.** An APK decompiles and a
   web build ships readable JavaScript. Anyone holding the `xnd_production_` key could
   refund every payment on the account.
2. **"Paid" must be proved, not reported.** Xendit confirms a payment with a
   signed webhook to a public HTTPS endpoint. Firestore rules cannot call out
   to verify a claim, so without that endpoint the only signal is the client
   asserting "I paid," which a modified client can forge.

The included `functions/` is a small Express service — `POST /checkout`
creates the gateway session for an order, `POST /webhook` verifies the
signature and writes the settled record with the Admin SDK. It runs on any
free container host (Render, Railway, Fly.io); Firebase itself stays on the
Spark tier. Security rules already treat `verified` and `gatewayReference` as
server-owned and unreachable from clients, so the flag flip
`--dart-define=PAYMENTS_API_URL=…` is a deployment change, not a rewrite.

What the hold-and-release model adds on top of the existing backend is a
**ledger**: per-freelancer balances, releases, refunds, and payouts, each an
append-only entry reconciled against the gateway's own settlement report. That
ledger is the single most security-critical piece of the system and must be
built and audited as such.

#### What "held" legally means

Holding money on behalf of two other parties and deciding who gets it is a
**regulated activity**. In the Philippines, custodial escrow and stored-value
wallets fall under BSP licensing (Electronic Money Issuer / Operator of Payment
Systems), which a student startup cannot obtain.

The model is therefore implemented and described as **merchant of record**:
the platform sells the service to the client, collects the full price as an
ordinary merchant, and pays the freelancer as a contractor after delivery.
Operationally that feels like escrow to both users; legally it is merchant
collection followed by contractor payout. The proposal, the terms of service,
and the interface must all say *held by the platform*, never *escrow*, and
this classification should be confirmed with a lawyer before live-mode
onboarding.

### Revenue stream 1 — commission on every in-app payment (primary)

A **10% platform commission** on the gross of every order released to the
freelancer. Because the order price is frozen at creation and the release is a
rules-enforced state transition, the commission base is unambiguous and cannot
be argued down by either party.

Commission is charged only on **released** orders. Refunded orders (cancelled,
or disputes resolved in the client's favour) generate no commission — and, as
the table shows, actually cost the platform money. Aligning income with
delivered work is deliberate: it gives the platform no incentive to side with
freelancers in disputes.

#### The per-order economics, honestly

Gateway and payout fees are real and do not scale down with the ticket size.
Approximate Xendit pricing for a PH account (verify current rates before
launch): cards ≈ 3.5% + ₱15, GCash/Maya ≈ 2.5% + small fixed fee; refunds return the amount but not the
processing fee; a payout to GCash or a bank costs roughly ₱10–15 per transfer.


| Order value | 10% commission | Gateway fee (GCash) | Margin if paid out per order (−₱15) | Margin with batched payouts |
| ----------- | -------------- | ------------------- | ------------------------------------- | --------------------------- |
| ₱150       | ₱15           | ₱4                 | **−₱4**                             | ₱11                        |
| ₱300       | ₱30           | ₱8                 | ₱7                                   | ₱22                        |
| ₱500       | ₱50           | ₱13                | ₱22                                  | ₱37                        |
| ₱1,000     | ₱100          | ₱25                | ₱60                                  | ₱75                        |

Two consequences shape the model:

- **A minimum commission of ₱20 per order**, so that small tutoring sessions
  do not run at a loss. The `CommissionPolicy` class already computes in
  integer basis points; a floor is a one-line addition.
- **Batched payouts with a ₱300 minimum**, so the per-transfer fee is paid once
  per week per freelancer rather than once per order.

Illustrative: 200 released orders per month at an average of ₱500 → ₱100,000
gross → **₱10,000 commission**, less roughly ₱2,500 in gateway fees and ₱600
in weekly payouts to ~40 active freelancers → **≈ ₱6,900 net**.

### Revenue stream 2 — Pro subscription (visibility and verification)

An optional **₱99/month** subscription for sellers. It does **not** reduce the
commission. A discount would cannibalise the primary stream exactly where it
is largest — the most active sellers — and would turn "Pro" into a cheaper
way to sell rather than a better one. Pro buys two things and only two:

**1. Featured listings — a limited number.** A Pro seller can flag up to
**two** of their published services as featured. Featured listings are pinned
above organic results in their category and in keyword search.

The cap is per seller *and* per surface: at most **three featured slots per
category page and per search result page**, rotated hourly across eligible
sellers, then across each seller's listings. Without that second cap, a category with twenty subscribers would
show twenty pinned cards and the feature would be worth nothing to anyone. The
two-per-seller limit also keeps the marketplace from becoming a paid wall —
organic listings must remain the majority of what a buyer sees, or the
marketplace's own quality is the thing being sold.

Implementation uses a `featuredUntil` timestamp on the service document and
server-built, paged global/category rotations. Three sellers appear per batch;
the starting position advances hourly so a pool of 100 sellers reaches every
seller over roughly 34 batches. The field is **server-owned**: only
the backend may write it, in the same way it alone writes `verified` on a
payment, so a modified client cannot feature itself for free.

**2. A verified badge.** A check mark on the public profile and on every card
the seller publishes.

The badge must mean something or it damages the trust signal the platform
exists to provide. Section 2 argues that screenshot testimonials fail because
they are easily faked; a badge that merely means "paid ₱99" is the same
failure sold by the platform itself. The badge therefore certifies
**verified student identity**: the subscriber submits a current student ID
and a school-issued email address, an admin checks them, and only then is
`verifiedUntil` set — again by the backend, never by the client. Subscription
pays for the check and keeps the badge active; it does not buy the badge
outright. A Pro seller who fails verification keeps the featured slots and is
told plainly why the badge is absent.

Billing is a **prepaid month**, renewed manually from the app through the same
Xendit checkout, not a recurring card mandate. E-wallet recurring payments
are poorly supported, and a student who forgets a subscription they cannot
easily cancel is a complaint, not a customer.

### Cost structure


| Item                  | Cost                                                                              |
| --------------------- | --------------------------------------------------------------------------------- |
| Firebase Spark tier   | ₱0 (Firestore reads/writes at student volumes stay within free quota)            |
| Payments backend host | ₱0 on a free container tier; ~₱400/month once always-on is required             |
| Gateway fees          | ≈ 2.5–3.5% + fixed fee per transaction, borne by the platform out of commission |
| Payouts               | ≈ ₱10–15 per batched transfer                                                  |
| Refund losses         | Processing fee on every refunded order                                            |
| Chargeback reserve    | A retained buffer against card disputes filed after payout                        |
| Verification labour   | Manual ID checks by admins — the only human cost in the model                    |
| Development           | Student team, no salary cost                                                      |

### Known risks and open questions

These are the places where the model can fail. They are listed rather than
hidden because each one has an answer, and the answer belongs in the plan.
Where the answer is code, it is built and noted; where it is policy or law,
it is named as the thing that still has to be done.

1. **Off-platform leakage.** Once two students have found each other, both
   have a 10% reason to finish the deal over GCash directly — and a held
   payment adds friction that makes leaving more tempting, not less. The only
   durable counter is that reviews, dispute protection, and the freelancer's
   public track record exist *only* for orders paid through the app. The
   commission has to buy something visible. *Built:* reviews and the verified badge exist only for paid,
   completed orders.
2. **Dispute resolution is now the platform's job.** Holding money means
   deciding who gets it. Admin staff will be arbitrating between classmates
   with nothing but a text chat and a text delivery as evidence. The dispute
   policy — what counts as delivered, how a split is decided, the response
   deadline for each side — must be written before the first peso is held,
   and shown to both parties at order time. *Built:* payment terms are shown and
   accepted before the first checkout; staff decide only between full release
   and full refund. *Still to do:* the written policy with response
   deadlines.
3. **Live services do not fit "submit, then accept."** A tutoring session is
   consumed as it happens; there is nothing to "submit" afterwards, and a
   client can decline to complete after receiving the full benefit. Auto-
   completion (step 9) plus a short response window for live-service
   categories is the mitigation, and disputes on those orders should default
   toward the freelancer once the session time has passed. *Built:* auto-
   completion after three days, with a reminder to the client a day before.
4. **Refunds cost money.** The gateway keeps its fee on refunded orders, so
   every cancellation after payment is a small loss. The cancellation policy
   should charge a processing deduction once work has started, and the
   `pending → accepted` step is the right place to make sure a client is
   committed *before* money moves.
5. **Chargebacks arrive after payout.** A card dispute can be filed weeks after
   the freelancer has been paid. The platform is liable. A retained reserve
   and a payout delay for first-time or low-history sellers are standard
   answers. *Built:* a seller's first three releases clear after seven days
   before they can be paid out.
6. **Minors.** Senior-high students are typically under 18, cannot enter a
   binding contract, and cannot hold a fully verified e-wallet for payouts.
   Selling on the platform should require being 18 or a verified guardian
   payout account; buying should require the same, or a clear parental-consent
   step. *Built:* a birth date at sign-up, set once and pinned by rules;
   selling and payouts are refused under 18. Buying stays open.
7. **Tax.** A platform collecting revenue and paying contractors has BIR
   registration and withholding obligations that a manual-settlement app
   never had. This needs an accountant before live mode, not after.
8. **Featured-slot dilution.** If subscriptions sell well, the per-page cap
   turns "featured" into a rotation rather than a guarantee. That must be
   disclosed at purchase: "one of up to three featured listings on the page,"
   not "top of the page." *Built:* slots rotate hourly by listing id, so every
   featured listing gets the same hours at the top, and a subscriber can
   check that for themselves.
9. **The badge as a wedge.** A verified check with admin approval creates a
   queue and an appeal process. Verification standards must be written down
   and applied identically, or the first accusation of favouritism among
   classmates will land on the platform.
10. **The ledger is a target.** Balances, releases, and payouts are the most
    valuable thing to attack. The backend must reconcile against the gateway's
    settlement report on a schedule, and every state change on money must be
    an append-only entry, never an update in place. *Built:* every balance change
    appends a ledger entry, and the admin overview totals the platform's
    liabilities for reconciliation before each payout run.

### Current implementation status

The app today ships in **manual settlement mode**: after acceptance the client
records a payment reference, the freelancer confirms receipt, and only then can
work start. Money moves off-platform, every record carries `verified: false`,
and the interface says "Confirmed by the freelancer" rather than showing a
receipt — an attestation and a proof must never look alike. This mode exists so
the product runs with no server, no gateway account, and no business
registration while demand is proved.

The hold model is implemented in `functions/` on the Blaze plan: the webhook
settles a payment as held, an order trigger releases it to the freelancer's
wallet on completion or refunds it through Xendit on cancellation, a
scheduled job completes deliveries the client ignored for three days, payouts
are requested by the freelancer and settled by staff against an append-only
ledger, and Pro months, featured listings, and identity checks are all
decided server-side with the corresponding fields unreachable from any
client. What remains is operational rather than engineering: Xendit live
mode, the legal classification, tax registration, and the written dispute
policy.

### Path to implementation

1. **v1 (current).** Manual settlement, zero cost. Objective: prove demand and
   accumulate the review corpus that makes the marketplace trustworthy.
2. **v2 — in-app payment, held and released (built).** Deploy `functions/`
   and set `PAYMENTS_API_URL`. Commission becomes real revenue. Begin in
   Xendit test mode — no business registration required — and move to live
   mode once the legal classification, tax registration, and dispute policy
   are in place.
3. **v3 — Pro subscription (built, switch on later).** Featured listings and
   identity verification ship with v2 but should be promoted only once order
   volume makes visibility genuinely contested. Launching it earlier sells a
   position in a queue nobody is standing in.

---

## Summary


| # | Requirement              | Answer                                                                                                                                                                                                                                                                                                                                                                                                                        |
| - | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | Business Idea            | Campus freelance marketplace where students both hire and get hired, built in Flutter on Firebase                                                                                                                                                                                                                                                                                                                             |
| 2 | Problem & Solution       | Informal student hiring has no discovery, trust, structure, or dispute process; the app supplies a searchable marketplace, order-bound reviews, frozen order terms, and a triple-enforced state machine                                                                                                                                                                                                                       |
| 3 | Target Customers         | Students buying short deadline-bound work, students selling skills around class schedules, plus student organisations and campus offices                                                                                                                                                                                                                                                                                      |
| 4 | Main Features            | Marketplace search & filtering · enforced order lifecycle · realtime chat · order-bound reviews · deep-linked notifications · commissioned payments                                                                                                                                                                                                                                                                      |
| 5 | Business & Revenue Model | Clients pay in-app before work starts; the platform holds the money and releases it minus a 10% commission when the work is accepted (auto-released if the client goes silent). A ₱99/month Pro subscription adds a capped number of featured listings and an identity-verified badge — it never discounts the commission. Manual settlement in v1; the included backend switches on gateway collection with one build flag |
