# Features

What the app does, from a user's point of view, and where each piece lives.

---

## Accounts and profiles

**Sign in** with a University of Mindanao Google account; there is no
registration form. The profile is created from the account — name, photo,
email — and a student-format address (`a.nerosa.545679@umindanao.edu.ph`)
yields the student number and marks the profile identity-verified, because
the institutional sign-in *is* the check. Personal Gmail and any other domain
is refused: the app deletes the stray auth record, the rules refuse every
read and write, the backend refuses every route, and with Identity Platform
enabled the account is never created at all.

Add a **birth date** once, in Edit profile; it cannot be changed and gates
selling and payouts (18+), not buying. The verification email is sent immediately rather
than waiting for you to find a button.

College is a closed list (CCE, CASE, CBAE, CAE, CEE, CTE, CHSE) and the
programme list narrows to that college, so a student can't end up filed under
"CCE, BS Nursing". Choosing a different college clears the programme rather
than leaving a stale pairing.

**Me** (`/profile`) is a hub: who you are on the lily header, three numbers
(earned, rating, available balance), and doors to My services, Wallet
(`/wallet`), Reviews received, Pro (`/pro`), Edit profile (`/profile/edit`,
a page grouped into about you / where you study / skills), your public
profile, appearance, and, for staff, the admin console. **Public profiles**
(`/user/{uid}`) show the student's name, programme, bio and skills, a review
overview with a link to every review they have received
(`/user/{uid}/reviews`), everything they currently sell, and a button to
message them. Seller names on service pages and review authors are links.

*Where:* `lib/features/auth/`, `lib/features/profile/`

## Pricing modes and offers

Every listing is **fixed-price** or a **starting price**, and a seller can
ask to be **contacted before ordering**. Only a fixed-price listing with no
such request shows an Order button; the others show "Message seller to get
an offer", and the rules refuse a direct order for them.

In the chat, the freelancer taps the offer icon, picks one of their
published listings, and sets the agreed price, delivery days, revisions and
scope. The card appears in the conversation, live: the client sees Accept &
order or Decline, the freelancer can withdraw it, and either side sees when
it became an order. Accepting creates the order from the offer's figures and
opens it; payment follows once the freelancer accepts the order. Offers
expire after seven days if unanswered.

*Where:* `lib/features/offers/`, `lib/features/chat/`

## Marketplace

Browse published listings, filter by category, sort by newest or price, and
search.

Search matches **derived keyword tokens** from the title and skills, so
"poster" finds "Event poster for your student org". The earlier prefix match on
the title could not.

Home opens with a greeting header, a category strip, and a row of featured
listings, then the results. Each card carries a category colour bar, the
category tag, the title, the price in stem green (with "from" when the price
is a starting point), the seller with their avatar, their rating or "New",
and the turnaround. One column on a phone, a grid on wider screens. Infinite
scroll pages through with a real cursor.

A **service page** is laid out in the order a buyer decides: category and
title, the seller and their score, price / delivery / revisions, the
description and skills, "how ordering works" for that listing's path, and a
concise **review overview** (average, count, the two latest, "View all N
reviews") that opens the dedicated reviews page. The decision never scrolls
away: order or message sits in a bar pinned to the bottom on a phone and in
a side column on a wide window.

*Where:* `lib/features/marketplace/`, `lib/features/services/`

## Selling

Create a listing with a title, description, category, skills, starting price,
delivery days and revision count. Move it through `draft → published → paused →
archived` yourself, so an overloaded exam week means pausing rather than
deleting.

*Where:* `lib/features/services/presentation/`

## Orders

A buyer places an order against a listing; the price and terms are copied from
the service **inside a transaction**, so a manipulated request cannot change
what the order says.

```text
pending → accepted → in progress → submitted → completed
                                        ↕
                                revision requested
```

Plus `rejected`, `cancelled` and `disputed` as exits. Each transition is
restricted to the party entitled to make it — the seller accepts, starts and
submits; the buyer completes or asks for a revision — and enforced in the UI,
in a database transaction, and in security rules.

Work cannot start until the order is paid. A delivery is a note plus up to
five files (25 MB each) in Cloud Storage; the rules accept only Storage
download URLs, so a "file" can never be a link elsewhere. Redelivering
after a revision request goes through the same delivery dialog. Ending an
order (decline, cancel, dispute) asks for confirmation first, and every
action button waits for the previous one to finish.

The **Orders** tab splits Buying and Selling, badges each with how many
orders are waiting on you, and filters with Needs you / Active / Done / All.
An order page opens with a five-step tracker (requested, accepted, in
progress, delivered, completed) and one sentence on what happens next from
your side, then the terms, the agreed scope for negotiated orders, the
requirements, deliveries, and payment. The actions you can take right now
sit in a bar at the bottom and nowhere else. The buyer's review is a single
dialog with stars and words.

*Where:* `lib/features/orders/`

## Payments and the 10% commission

Every order carries a payment record with the gross amount, the platform's 10%
commission, and the freelancer's net. The split uses integer arithmetic, so the
two parts always reconstitute the gross exactly.

**Manual mode (the default)** runs with no server and no gateway account: the
buyer records a reference, and the **freelancer** — the party who actually
receives the money — confirms it. The payer cannot confirm their own payment.
These records are marked unverified and the interface says "Confirmed by the
freelancer" rather than showing a gateway receipt; an attestation and a proof
should not look alike.

**Gateway mode** is the default for production and development builds
(`PaymentConfig.deployedBackendUrl`); the emulator build has no backend, and
`--dart-define=PAYMENTS_API_URL=manual` forces the no-backend path anywhere.

The client picks how to pay on a checkout sheet (GCash, Maya, credit or
debit card, or another wallet) and finishes on a Xendit page that opens in
the browser on that channel. Coming back to the app asks the gateway at
once (`POST /payments/{orderId}/sync`, the same code path as the callback),
so a finished payment reads **Paid** immediately; while a checkout is still
open the order page offers "Check payment status" and "Reopen checkout"
rather than another payment. Reopening hands back the invoice that is
still open rather than minting a second one, and if two invoices for one
order are ever both paid the second is refunded automatically. The
callback and the half-hourly reconciler remain the safety net. Paid,
and the **platform holds the money** until the order ends: released to the
freelancer's wallet (minus commission, ₱20 minimum) when the client accepts
the delivery, refunded if the order is cancelled or rejected, and decided by
staff on a dispute. A client who ignores a delivery for three days does not
keep the freelancer unpaid: the order completes on its own, and the screen
says exactly when.

The Xendit secret key never reaches the app — it can't; an APK decompiles and
a web build ships readable JavaScript. `functions/` holds it, re-derives the
amount from the order, and its signed webhook is the only thing that can mark
a payment verified.

*Where:* `lib/features/payments/`, `functions/`

## Transactions

`/transactions` (from Me, and "History" on the Wallet) lists every payment
the student sent or received and every Pro month bought, newest first, with
its state: awaiting confirmation, paid and held, released, refunded, failed.
Filter to Sent or Received; a row opens its order or the Pro page.

## Wallet and payouts

The **payout account** has its own page (`/wallet/account`): choose GCash,
Maya or a bank the way a delivery app adds a payment method, then fill in
the one form that applies (bank picker, holder name, number). The saved
account shows masked, with an edit and the other methods below it.

Released money lands in the freelancer's balance, shown on the **Wallet**
page (`/wallet`) with lifetime earnings and a ledger of every movement. A seller's
first three releases sit as "Clearing" for seven days before they become
available, which is the platform's cushion against a card chargeback filed
after a payout. They add a GCash, Maya, or bank account (the number is
shape-checked in the app, the backend, and the rules; a bank account picks
its bank from a list), and once the available balance reaches ₱300 they
request a payout of the whole balance (one at a time). With automated
payouts on, it is sent through Xendit at once and settled by Xendit's
callback; otherwise staff send it via Xendit from the queue or record a
transfer made by hand. The student is notified either way, and a failed
transfer returns to their balance with the reason. Every movement is an append-only
ledger entry. Payouts, like selling, need a birth date showing 18 or over.

If a card payment is **charged back** after it was released, staff record it
from the refunds tab; the seller's share leaves their balance, and whatever
the balance cannot cover shows as **Owed** and is deducted from their next
releases. A balance whose owner has not signed in for 90 days is flagged so
staff can reach them before a graduate's university account closes.

*Where:* `lib/features/wallet/`, `functions/ledger.js`

## Pro, featured listings, and the verified badge

₱99 buys 30 days, paid up front through the same checkout, no auto-renewal.
A Pro seller can feature up to two published listings from **My services**;
they are pinned above the marketplace in batches of three, rotated fairly
across sellers and listings, and labelled as paid. More batches appear as a
student scrolls. A once-daily home showcase uses the same first batch. Features
lapse with the subscription. A Pro seller can also
submit a student ID photo and school email; staff review it in the admin
console, and an approved student shows the verified check mark next to their
name on every card, page, and profile — while Pro is active. Paying never
buys the badge on its own, and Pro never discounts the commission.

*Where:* `lib/features/pro/`, `functions/ledger.js`

## Reviews and ratings

One review per completed order, written by the buyer, keyed to the order id so
duplicates are structurally impossible.

Writing a review also bumps the service's rating counters **in the same atomic
write**, with rules binding the increment to the rating actually written. A
marketplace page therefore shows scores without a single extra read.

Reviews have **their own page**: `/service/{id}/reviews` for a listing and
`/user/{uid}/reviews` for everything a seller has earned. It opens with the
average and a bar per star (five count aggregates, so it costs the same for
ten reviews as for ten thousand), sorts by newest / highest / lowest,
filters to one star by tapping a bar or a chip, and pages twenty at a time.
Service and profile pages show only an overview with a "View all" link.

*Where:* `lib/features/reviews/`

## Messaging

Chat between a buyer and a seller, with unread badges and live updates. A
message can carry a photo or a file (10 MB) uploaded to Cloud Storage; images
show inline, files as a chip that opens in the browser. Conversation ids are
the two uids sorted, so one pair maps to exactly one conversation no matter
who opens it first.

*Where:* `lib/features/chat/`

## Notifications

Typed in-app notifications — new order, status change, message, payment
confirmed, review received — delivered over realtime streams with deep links to
the exact order or conversation. Rules validate every notification against its
type: senders must genuinely be a participant, and a recipient may only mark
one read.

Every inbox document is also pushed to the student's registered devices by a
Cloud Function, and a tapped push lands on the same screen as a tapped inbox
row. Windows and Linux have no FCM and keep the inbox only.

*Where:* `lib/features/notifications/`

## Admin console

Reachable at `/admin` for staff only, and each section only for staff who
hold its permission. The main admin holds every permission and sees a
**Staff** section where staff are granted by UM email with a checklist of
permissions. Sections sit in a rail on a wide window and a chip row on a
phone; the queues (disputes, payouts, refunds, verification) carry a badge
with their open count, and the Overview opens with a **Needs attention**
strip of the same counts, each tile a door to its queue.

**Students** — search by name, see email, student number and programme,
suspend or reinstate with a reason. A suspended student can sign in and
read but cannot order, sell, offer or message.

**Orders** and **Transactions** — every order by status, every payment with
its hold state and commission.

**Categories** — add, rename, reorder and retire marketplace categories on
top of the built-in eight; listings keep their label.

**Settings** — an announcement banner shown on every tab, and a platform-wide
pause on new orders that the rules enforce.

**Audit log** — the backend's record of sign-ins, profile creation, pricing
changes, offers, order moves, payments, payouts, and staff changes.

**Overview** — commission earned, gross value, paid out to students, average
order, completion rate, dispute rate, counts of students/listings/orders/
reviews, a breakdown of orders by stage, and recent staff actions. Revenue
counts **settled payments only**; money promised but not sent is not income.

**Disputes** — a disputed order is terminal for both parties, so only staff can
close it, as completed ("release to seller") or cancelled ("refund buyer"). A
reason of at least ten characters is required and goes into the audit log.

**Listings** — every listing including drafts, with the power to take one down.
Staff can change a listing's status and nothing else; they cannot edit its
content, price or score.

**Payouts** — transfer requests oldest first, with the account to send to.
Staff mark one sent with the transfer reference, or return the money with a
reason the student sees.

**Refunds** — payments whose refund the gateway refused or cannot address.
Retry through the gateway, or record a refund sent by hand with its
reference. Staff are notified the moment one lands here.

**Verification** — student-ID checks oldest first, each showing how long it
has waited (red after three days), with the photo loaded through a
rule-checked download. Approve or reject with a reason; staff cannot approve
themselves. The photo is deleted the moment a decision is made.

**Money held** on the overview: what is held on orders plus every wallet
balance (available, clearing, requested) and the total of stuck refunds, so
staff can reconcile against the Xendit balance before a payout run.

Every staff action is written to an append-only audit trail that nobody can
edit or delete, including the person who performed it.

Staff access is granted by a document only a service-account key can write:

```sh
node tools/seed/seed.js --admin you@example.com --live
```

*Where:* `lib/features/admin/`

---

## Without the backend

A build with no `PAYMENTS_API_URL` — which is how the app runs against the
emulator — keeps the marketplace, orders, chat, reviews and inbox, and says so
where the rest would be: payments fall back to manual settlement, the Pro and
payout cards explain that they need the backend, and staff queues are
read-only. Attachments and push work as soon as Storage and Functions are
deployed; they do not depend on the URL. Turning everything on is in
[BLAZE_UPGRADE.md](BLAZE_UPGRADE.md).

## Known limits

- Orders, conversations and notifications each show the **50 most recent** and
  say so on screen. They do not page further back.
- Seller names on marketplace cards cost one cached read per distinct seller on
  first load. Denormalising `sellerName` onto the service (rules-verified
  against the seller's own profile, to prevent impersonation) would make it
  free if it ever matters.
- Ratings on a service are counters; a service created before that field
  existed reads as unrated until something writes its totals.
