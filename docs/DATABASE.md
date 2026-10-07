# Database schema

Cloud Firestore. Every collection below is protected by `firestore.rules`,
which is the real authorization layer — client-side checks are UX only. Where a
rule does something non-obvious, it is explained here rather than left to be
rediscovered.

Money is always an **integer number of whole pesos**. There are no decimal
amounts anywhere in the system, so a split can never drift by a centavo.

---

## Collection map

```text
users/{uid}
  ├── notifications/{id}
  └── devices/{token}          FCM tokens, owner-only
services/{id}
offers/{id}                  negotiated quotes; one offer → one order
orders/{id}
  └── deliveries/{id}
payments/{orderId}          document id == order id
reviews/{orderId}           document id == order id
conversations/{uidA_uidB}   deterministic id, uids sorted
  └── messages/{id}
wallets/{uid}               held money; balances backend-only
ledger/{id}                 append-only money movements, backend-only
payouts/{id}                transfer requests, backend-only
subscriptions/{sessionId}   Pro months, settled by the webhook
verificationRequests/{uid}  student-ID checks; one per student
admins/{uid}                role + permissions; main admin Admin-SDK only
adminActions/{id}           staff's own rule-validated log
auditLog/{id}               the platform's log, backend-only
categories/{id}             staff-managed, merged over the built-in list
settings/platform           announcement, ordersPaused
```

Every read and write in every rule starts from `isSignedIn()`, which now
means **a verified `@umindanao.edu.ph` token**. There is no other identity.

Cloud Storage mirrors the same ownership (`storage.rules`):

```text
conversations/{id}/{file}          participants, ≤ 10 MB
orders/{id}/deliveries/{file}      freelancer writes, participants read, ≤ 25 MB
verification/{uid}/{file}          owner writes, owner + staff read, image ≤ 5 MB
users/{uid}/{file}                 profile photo, signed-in read, image ≤ 2 MB
```

Three collections use a **deterministic document id** rather than a generated
one. This is a structural guarantee, not a convention: because there is only
one address a payment or a review can live at, an order can never accumulate
two of them, and a duplicate is refused by Firestore itself rather than by
application logic that might have a race in it.

---

## users/{uid}

The public profile. Every account is simultaneously a buyer and a seller;
there is no role field, by design.

| Field | Type | Notes |
| --- | --- | --- |
| `uid` | string | Equals the document id |
| `email` | string? | The UM address from the token; pinned at creation |
| `studentId` | string? | Six digits from a student-format address, checked against the token |
| `suspended` | bool | Staff only (`users.manage`); blocks every create and move |
| `displayName` | string | 1–60 chars, from the Google account at creation |
| `bio` | string | ≤ 500 chars |
| `skills` | string[] | ≤ 20 entries |
| `collegeId` | string? | One of the ids in `lib/core/constants/academics.dart` |
| `program` | string? | Degree name, ≤ 80 chars |
| `photoUrl` | string? | ≤ 2048 chars |
| `birthDate` | timestamp? | Set once, never changed (rules pin it); 13 to 100 years ago. Gates selling and payouts |
| `paymentTermsAcceptedAt` | timestamp? | Written by the owner once, before the first gateway checkout |
| `proUntil` | timestamp? | **Server-owned.** End of the paid Pro month |
| `identityVerified` | bool | **Server-owned.** Staff checked ID + school email |
| `createdAt` | timestamp | Required at creation |
| `updatedAt` | timestamp | |

The verified badge is `identityVerified && proUntil > now`, computed by the
client; there is no stored badge flag to drift. `proUntil` and
`identityVerified` may be carried through a profile edit unchanged but never
introduced or altered — otherwise the badge would be self-granted the moment
someone edited their bio.

`devices/{token}` holds `{token, platform, updatedAt}`; the document id is the
token, so a re-registering device overwrites rather than duplicates. Owner
read/write only; the push function reads them with the Admin SDK and deletes
the ones FCM reports as dead.

**Rules.** Readable by any signed-in user (needed for seller names and
conversation headers). Only the owner may write, and only within the bounds
above. `uid` and `createdAt` are pinned on update.

`createdAt` is **required at creation** because the update rule compares it; a
profile written without one could never be edited again.

Listing the collection is denied for ordinary users — no directory scraping —
and allowed for staff, who need it to report sign-ups.

---

## services/{id}

A listing.

| Field | Type | Notes |
| --- | --- | --- |
| `sellerId` | string | Must equal the writer's uid |
| `title` | string | 1–80 chars |
| `titleLower` | string | Must equal `title.lower()` — checked in rules |
| `description` | string | 20–4000 chars |
| `categoryId` | string | One of eight fixed categories |
| `skills` | string[] | Free text |
| `keywords` | string[] | Derived search tokens, ≤ 40 |
| `startingPrice` | int | ₱1 – ₱1,000,000 |
| `currency` | string | `PHP` |
| `deliveryDays` | int | 1–90 |
| `revisionCount` | int | 0–10 |
| `status` | string | `draft` · `published` · `paused` · `archived` |
| `pricingMode` | string | `fixed` (default) · `negotiable`: the price is a starting point |
| `requiresContact` | bool | The seller wants a conversation before any order |
| `ratingSum` | int | Denormalised; see below |
| `ratingCount` | int | Denormalised; see below |
| `lastReviewId` | string? | The review that last moved the counters |
| `createdAt` / `updatedAt` | timestamp | |

**`titleLower` and `keywords` are derived, not authored.** Both are computed in
`toFirestore` from the title, and rules verify `titleLower`. A hand-maintained
search index drifts from the text it describes, and a drifted value silently
makes a listing unfindable.

### Rating counters without a server

`ratingSum` / `ratingCount` let a marketplace page show scores with **no extra
reads** — the totals arrive with the documents already being listed. The
obvious objection is that a denormalised total needs a trusted writer, and
there is no Cloud Function here. Rules solve it:

```
allow update: if isSignedIn() && validRatingBump(serviceId);
```

The reviewer writes the review and bumps the counters in one atomic batch, and
the rule binds them together:

- `getAfter()` reads the review as it will exist *after* this commit, so the
  increment must match the rating actually being written;
- `exists()` is false and `existsAfter()` is true only when the review is being
  **created in this very write** — which is what stops a bump being replayed
  off an older review to inflate a score;
- the review's `reviewerId` must be the caller and its `serviceId` this service;
- a separate rule forbids the seller touching their own score at all.

Nine rules tests cover this, including the replay attempt.

**Rules.** Public reads see `published` only; a seller always sees their own
drafts; staff see everything. `validService()` runs on **update as well as
create** — otherwise an owner could push their own price or title outside every
bound after the fact. Staff may change `status` to `paused`/`archived` and
nothing else: taking a listing down is a different power from rewriting it.

---

## offers/{id}

A negotiated quote, sent by the freelancer in the pair's conversation.

| Field | Type | Notes |
| --- | --- | --- |
| `serviceId` / `serviceTitle` | | The seller's published listing; title checked against it |
| `freelancerId` / `clientId` / `participantIds` | | Sender must be the seller; client the other participant |
| `conversationId` | string | The pair's conversation; the offer card is a message in it |
| `price` | int | 1–1,000,000, the agreed price |
| `deliveryDays` / `revisionCount` | int | 1–90 / 0–10 |
| `scope` | string | 10–2000 chars; copied to the order |
| `status` | string | `pending` → `accepted` → `ordered`; `declined`, `withdrawn`, `expired` |
| `orderId` | string? | Set when spent |
| `expiresAt` | timestamp | Seven days |

**Rules.** The client moves `pending → accepted | declined`; the freelancer
`pending → withdrawn`; the client `accepted → ordered` only in a batch that
creates an order whose `offerId` is this offer. Figures never change.

## orders/{id}

A purchase. Price and participants are frozen at creation.

| Field | Type | Notes |
| --- | --- | --- |
| `serviceId` / `serviceTitle` | string | Title is a **historical snapshot** |
| `clientId` / `freelancerId` | string | |
| `participantIds` | string[] | Both uids, sorted — the field rules check |
| `price` | int | The listing's fixed price, or the accepted offer's price |
| `currency` | string | `PHP` |
| `deliveryDays` / `revisionCount` | int | Terms as agreed |
| `requirements` | string | 10–4000 chars, the client's side |
| `offerId` | string? | The spent offer, for a negotiated order |
| `scope` | string? | The freelancer's side, copied from the offer |
| `status` | string | See the state machine below |
| `deadline` | timestamp? | Set when accepted |
| `autoCompleted` | bool | Completed by the backend after the client went silent |
| `createdAt` / `updatedAt` | timestamp | |

`serviceTitle` and `price` are denormalised **on purpose**: they record what
was agreed, and must not change when the seller later edits the listing.

**Creation** takes one of two shapes, checked in rules (`directOrder()`,
`offerOrder()`) and re-derived by the backend (`pricingMismatch()`) before
any checkout:

- **direct** — no `offerId`; the listing is `pricingMode: fixed` with
  `requiresContact` false, and `price == startingPrice`;
- **from an offer** — `offerId` names an `accepted` offer for this client,
  `price`, `deliveryDays`, `revisionCount` and `scope` all equal the offer's,
  and the same batch marks the offer `ordered` with this order's id.

Both also require the student not to be suspended and `settings/platform`
not to have `ordersPaused`.

### Order state machine

```text
pending ──accept──▶ accepted ──start──▶ in_progress ──submit──▶ submitted ──▶ completed
   │                    │                    │                      │
   │ reject/cancel      │ cancel/dispute     │ cancel/dispute       ├──▶ revision_requested
   ▼                    ▼                    ▼                      │         │
rejected            cancelled            disputed  ◀────────────────┘         │
                                                        redeliver ────────────┘
```

Enforced in three layers: the UI only offers legal actions, the repository
re-validates inside a transaction, and rules reject illegal writes server-side.

Actors are keyed on the **edge**, not the destination. Cancelling a *pending*
request belongs to the buyer (the seller declines with `rejected`), while
cancelling work already under way is open to either party. Keying on the
destination alone could not express that, and produced a "Cancel" button the
rules always rejected.

`disputed` is terminal for both parties by design — only staff can close it,
as `completed` or `cancelled`.

---

## payments/{orderId}

One payment per order, enforced by the shared id.

| Field | Type | Notes |
| --- | --- | --- |
| `orderId` | string | Equals the document id |
| `clientId` / `freelancerId` / `participantIds` | | Copied from the order |
| `amount` | int | Must equal the order's price |
| `commission` | int | The platform's 10% |
| `netToFreelancer` | int | `amount − commission` |
| `status` | string | `pending` · `paid` · `failed` · `refunded` |
| `method` | string | `manual` · `xendit` |
| `verified` | bool | **Server-owned** |
| `holdStatus` | string? | **Server-owned.** `held` · `released` · `refunded`; gateway payments only |
| `gatewayPaymentId` | string? | **Server-owned.** The Xendit payment behind the session; needed to refund |
| `refundStatus` | string? | **Server-owned.** `sent` · `failed` · `manual-required` · `manual` (recorded by staff) |
| `reference` | string? | Manual mode: the payer's GCash/bank reference |
| `gatewayReference` | string? | Gateway mode, written by the backend |
| `createdAt` / `updatedAt` / `paidAt` / `releasedAt` / `refundedAt` | timestamp | |

**Hold and release.** A gateway payment settles as `paid, held`. The backend's
`onOrderStatusChanged` trigger moves it: `completed` → `released` (the net is
credited to `wallets/{freelancer}` with a `ledger` entry), `cancelled` or
`rejected` → a Xendit refund, then `refunded`. Both only act on `held`, so a
redelivered trigger is harmless. Manual settlements have no hold: the
freelancer was paid directly.

There is deliberately **no `unpaid` status**: an unpaid order simply has no
payment document. "Unpaid" is the absence of a record, not a state that could
be written or transitioned out of.

**Rules.**

- The split must reconstitute the gross exactly:
  `commission + netToFreelancer == amount`. Money can be neither invented nor
  lost, whatever the client-side arithmetic did.
- `amount` must equal the order's `price`, read live via `get()` — so a buyer
  cannot open a ₱1 payment for a ₱5,000 order.
- `verified` and `gatewayReference` are unreachable from every client. Only the
  payments backend can set them, using the Admin SDK, which bypasses rules —
  which is precisely why the rules can forbid clients outright.
- In manual mode only the **freelancer** may mark a payment paid. The payer
  confirming their own payment would make the record assert nothing.
- No deletes: payment history is dispute evidence.

### Reading earnings

The earnings query **must constrain `participantIds`**:

```dart
.where('participantIds', arrayContains: uid)
.where('freelancerId', isEqualTo: uid)
.where('status', isEqualTo: 'paid')
```

For a `list`, Firestore can only prove a query safe over the fields the query
itself filters on. The rule inspects `participantIds`; filtering on
`freelancerId` alone left it unknown, and every earnings read failed with
`PERMISSION_DENIED`. This is a regression test in the suite.

---

## reviews/{orderId}

| Field | Type | Notes |
| --- | --- | --- |
| `orderId` / `serviceId` | string | |
| `reviewerId` / `revieweeId` | string | Buyer and seller |
| `rating` | int | 1–5 |
| `comment` | string | 1–1000 chars |
| `createdAt` | timestamp | |

Only the client of a **completed** order may create one, and because the
document id is the order id, duplicates are impossible. Create-only: no
updates, no deletes.

The review flow writes **nothing to the order document**. Orders accept
`status`/`deadline`/`updatedAt` and nothing else, so an earlier `hasReview`
flag was rejected and took the whole transaction — and therefore every review —
down with it. Whether an order has been reviewed is answered by whether
`reviews/{orderId}` exists.

---

## conversations/{uidA_uidB}

The id is the two uids sorted and joined with `_`, so one pair maps to exactly
one conversation regardless of who opens it first.

| Field | Type | Notes |
| --- | --- | --- |
| `participantIds` | string[] | Exactly two, sorted |
| `unreadCount` | map | uid → count |
| `lastMessagePreview` | string | ≤ 80 chars |
| `lastMessageSenderId` | string | |
| `lastMessageAt` / `createdAt` | timestamp | `createdAt` required at creation |

Messages live in a subcollection with `senderId`, `text` (≤ 2000), `sentAt`,
and optionally `attachmentUrl` (https, ≤ 2048), `attachmentName` (≤ 200),
`attachmentType` (`image` · `file`) and `attachmentSize` (≤ 10 MB). A message
must carry text or an attachment; never neither. Messages are immutable once
written. Deliveries carry the same shape as an `attachments` list of at most
five `{url, name, size, type}` entries.

**`unreadCount` is bounded per writer**: you may only clear *your own* counter
and raise the other party's by at most one. Without that, either participant
could write any number into the other's slot and pin a permanent badge on their
inbox.

Creation must include `createdAt` for the same reason as profiles: the update
rule pins it.

---

## wallets/{uid}, ledger/{id}, payouts/{id}

Money the platform holds. Written **only by the backend**, in transactions
that also append a `ledger` entry saying why; nothing is updated in place to a
different amount.

| `wallets/{uid}` | Type | Notes |
| --- | --- | --- |
| `available` | int | Released, cleared, and not yet requested |
| `clearing` | int | Released but inside the new-seller clearance window (first 3 releases, 7 days) |
| `releaseCount` | int | Decides whether the next release clears immediately |
| `pendingPayout` | int | Requested, waiting for staff to transfer |
| `totalReleased` / `totalPaidOut` | int | Lifetime figures |
| `payoutAccount` | map | `{type: gcash·maya·bank, accountName, accountNumber, bankCode?}` — **the only owner-writable field**; a bank account names its bank as a Xendit channel code from the supported list |

`ledger/{id}`: `{uid, type, amount, orderId?, payoutId?, note?, createdAt}`
where `type` is `release` · `refund` · `payout_requested` · `payout_paid` ·
`payout_rejected` and `amount` is signed relative to `available`. A `release`
also carries `cleared` and `clearsAt`; the scheduled job flips `cleared` and
moves the amount from `clearing` to `available` when the date passes.

`payouts/{id}`: `{uid, amount, status: requested·processing·paid·rejected·failed,
account, requestedAt, settledAt?, settledBy?, reference?, note?,
gatewayPayoutId?, gatewayError?}`. Requested through `POST /wallet/payout`
(min ₱300, one at a time). With automated payouts on, the backend hands it to
Xendit Payouts (`processing`) and Xendit's callback settles it (`paid`,
`settledBy: xendit`) or returns the money (`failed`); otherwise staff send
it via Xendit or record a hand-made transfer (`paid`) or return it
(`rejected`). Every path is a ledger entry.

**Rules.** Owner and staff read; owner may create/update `payoutAccount`
only; no client writes anywhere else; nothing deletable.

## subscriptions/{sessionId} and verificationRequests/{uid}

`subscriptions/{sessionId}` (`{uid, amount, status: pending·paid, periodEnd,
paidAt}`) is written by `/pro/checkout` and settled by the webhook, which sets
`users/{uid}.proUntil` and extends any currently featured listing to the new
end. Read by owner and staff; no client writes.

`verificationRequests/{uid}` is the one document a student writes here:
`{uid, schoolEmail, idImagePath, status: pending, createdAt}`, with
`idImagePath` pinned by rule to `verification/{uid}/…`. A pending or approved
request is not theirs to change; a rejected one may be re-submitted. Staff
decide through the backend, which sets `status`, `decidedBy`, `note`, and
`users/{uid}.identityVerified` in one transaction.

`services/{id}.featuredUntil` is likewise **server-owned**: set by
`POST /services/:id/featured` to the seller's `proUntil` (max two per seller),
carried through the seller's own saves unchanged, and lapsing with Pro.

`featuredRotations/{scope}__page_{n}` contains at most three service ids and
the current page count for the global or category rotation. The backend writes
the pages; signed-in clients may get a selected page but cannot enumerate or
change the rotation.

---

## admins/{uid}, adminActions/{id}, auditLog/{id}

`admins/{uid}` is `{role: 'admin' | 'staff', permissions: string[],
displayName?, email?, createdBy, createdAt}`. `role: admin` (every
permission) is written only by a service-account key; the main admin creates,
edits and revokes `role: staff` documents from the console, never their own,
and only with permissions from the known list. Rules expose `can(permission)`
and every staff surface asks for one; `storage.rules` and the backend do the
same.

`adminActions` is the staff's own log: rule-validated, `actorId` must be the
caller, append-only, readable with `reports.view`.

`auditLog` is the platform's: `{actorId, action, targetType, targetId,
details, createdAt}`, written only by Cloud Functions — routes with the acting
uid, triggers for document changes the app makes directly (profiles,
listings' pricing and status, offers, orders, staff, settings, categories),
and Identity Platform blocking functions for sign-ins. Readable with
`reports.view`; no client can write it.

## categories/{id} and settings/platform

`categories/{id}` (`{label, active, sortOrder}`) is merged over the built-in
list in `lib/core/constants`: an entry with a built-in id overrides its label
or retires it, a new id extends the list. Never deleted, because listings
keep the id. Written with `categories.manage`.

`settings/platform` (`{announcement ≤ 300, ordersPaused}`) is read by every
signed-in user (the banner) and by the order-create rule (`ordersOpen()`);
written with `settings.manage`.

Staff access is **the existence of `admins/{uid}`**. No client can create, edit
or delete those documents — `allow write: if false` — so the only way to become
staff is a write from the Admin SDK with a service-account key held off-device.
A boolean on the user's own profile would be self-granted the moment someone
edited their profile.

```sh
node tools/seed/seed.js --admin you@example.com --live
```

`adminActions` is an append-only audit trail: `actorId` (must be the caller),
`action` (e.g. `dispute.completed`), `targetType`, `targetId`, `note`,
`createdAt`. Readable by staff, never updatable or deletable — including by the
person being audited. It lives in its own collection precisely because the
documents it describes are shape-locked.

---

## Indexes

`firestore.indexes.json` holds 31 composite indexes. Two things to know:

**The emulator does not enforce composite indexes.** A query that works locally
can fail in production with `FAILED_PRECONDITION`. Always deploy indexes before
trusting a new query shape.

**Direction matters.** An ascending index does *not* serve a descending
`orderBy`; Firestore rejects the query outright. Each sort therefore needs its
own entry — `newest` (`createdAt DESC`) and `priceHighToLow`
(`startingPrice DESC`) cannot share the ascending index that serves
`priceLowToHigh`. This was found in production, not locally.

Marketplace queries need one index per equality combination × sort:

| Equality filters | Sorts |
| --- | --- |
| `status` | `createdAt DESC`, `startingPrice ASC`, `startingPrice DESC` |
| `status` + `categoryId` | (same three) |
| `status` + `keywords[]` | (same three) |
| `status` + `categoryId` + `keywords[]` | (same three) |

Plus `sellerId + updatedAt DESC`, `sellerId + status + updatedAt DESC`,
`participantIds[] + updatedAt DESC` (orders),
`participantIds[] + lastMessageAt DESC` (conversations),
`serviceId + createdAt DESC` and `revieweeId + createdAt DESC` (reviews), and
`participantIds[] + freelancerId + status` (earnings).

Blaze features add: `status + featuredUntil DESC` (the backend featured-pool
sweep), `sellerId + featuredUntil` (the per-seller cap), `status + updatedAt` in
**both** directions (staff queues descending, the auto-complete sweep
ascending — one cannot serve the other), `uid + createdAt DESC` (ledger),
`uid + requestedAt DESC` and `status + requestedAt` (payouts), and
`status + createdAt` (verification queue), `type + cleared + clearsAt`
(the clearance sweep), and `refundStatus + updatedAt DESC` (the refund queue).

---

## Retention

Notifications carry `expiresAt` (60 days). Configure a **TTL policy** on
`users/{uid}/notifications` for that field in the Firebase console and the
server deletes them automatically. Until the policy exists the field is inert
and nothing is deleted.

Dead FCM tokens are deleted by the push function when a send reports them
unregistered.

Nothing else is ever deleted. Orders, payments, ledger entries, reviews, and
uploaded files are permanent records that disputes may depend on.
