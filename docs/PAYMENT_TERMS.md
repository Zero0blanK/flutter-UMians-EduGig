# Payment terms

What a student agrees to before their first in-app payment. The in-app
dialog (`PaymentTermsDialog` in `lib/features/payments/presentation/`) is a
summary of this page and must say the same thing. Acceptance is recorded on
the profile as `paymentTermsAcceptedAt`.

This is the plain-language version. It is not legal advice, and it is not a
substitute for having the merchant-of-record structure below reviewed by a
lawyer before Xendit live mode.

## What happens to your money

1. **You pay the full price when the freelancer accepts your order.** The
   platform collects it through Xendit and holds it while the work is done.
   The freelancer cannot start until the payment is confirmed.
2. **The freelancer is paid when you accept the delivery.** They receive the
   price minus the platform commission (10%, with a ₱20 minimum). The
   commission is shown to both of you before you pay.
3. **If you do nothing for three days after a delivery, the order completes
   on its own** and the freelancer is paid. You are reminded a day before.
   You can request a revision or raise a dispute at any point in those three
   days.
4. **If the order is cancelled or declined, you are refunded** through the
   payment method you used. Refunds can take a few days to appear, and the
   gateway's processing fee is not refundable by the platform.
5. **If you dispute an order,** staff read the order, the chat, and the
   delivery, and decide between a full release to the freelancer and a full
   refund to you. There is no partial outcome. On orders of ₱2,000 or more,
   two different staff members must agree before the order is closed.

## For freelancers

6. **Released money goes to your balance,** not straight to your bank. You
   request a payout of your whole available balance once it reaches ₱300,
   and it is sent to the GCash, Maya, or bank account on your profile —
   usually within minutes through Xendit, or by staff if the transfer has to
   be made by hand. If the transfer fails, the money returns to your balance
   and you are told why. Check the number: a transfer to the wrong account
   cannot be recalled.
7. **Your first three payments clear after seven days** before they can be
   paid out. After that, releases are available immediately. This is the
   platform's protection against card chargebacks that arrive after a
   payout.
8. **If a card payment is charged back after it was released to you,** your
   share of it is taken from your balance. Anything your balance cannot
   cover is deducted from your next releases; the platform absorbs its own
   commission. You are told when this happens.
9. **Request a payout before you leave the university.** Your account is
   your university Google account, and the platform cannot sign you in once
   the university closes it. A balance untouched for 90 days is flagged so
   staff can reach you through the payout account on file. Unclaimed money
   is held indefinitely; the platform never takes it.
10. **Selling and payouts are for students aged 18 and over.** Your birth date
   is set once at sign-up and cannot be changed. Under-18 students can hire
   but not sell.

## What the platform is

11. **The platform is the merchant of record.** It sells the service to you,
   collects the price as an ordinary merchant, and pays the freelancer as a
   contractor after delivery. It holds money for the duration of an order.
   It is **not** an escrow service, a wallet, or a bank, and the balance on
   your profile is not a deposit.
12. **Nothing is deleted.** Orders, payments, chat, and delivered files are
    kept as the record a dispute is decided on.

## Open items before live mode

These are operational, not engineering, and are listed in
`business_proposal.md` §5: BSP classification of the merchant-of-record
structure, BIR registration and withholding on contractor payouts, a written
dispute policy with response deadlines, and a retention schedule for ID
photos (currently deleted at the moment of the staff decision).
