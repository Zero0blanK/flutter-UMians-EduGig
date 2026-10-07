import 'package:cloud_firestore/cloud_firestore.dart';

/// Lifecycle of the money for one order.
///
/// There is deliberately no `unpaid` member: an unpaid order simply has no
/// payment document, so "unpaid" is represented by a null [Payment] rather
/// than by a state that could be written, queried, or transitioned out of.
enum PaymentStatus {
  /// Recorded, awaiting confirmation — the gateway has not settled yet, or in
  /// manual mode the freelancer has not yet acknowledged receipt.
  pending,

  /// Settled. In gateway mode only a trusted server may write this.
  paid,

  /// The gateway declined or the checkout expired.
  failed,

  /// Returned to the client after a cancellation or a dispute.
  refunded;

  static PaymentStatus fromName(String? name) => PaymentStatus.values
      .firstWhere((s) => s.name == name, orElse: () => PaymentStatus.pending);

  String get label => switch (this) {
    PaymentStatus.pending => 'Awaiting confirmation',
    PaymentStatus.paid => 'Paid',
    PaymentStatus.failed => 'Payment failed',
    PaymentStatus.refunded => 'Refunded',
  };
}

/// How the money moved.
enum PaymentMethod {
  /// Settled off-platform (GCash, bank transfer, cash) and attested in-app.
  /// This is the no-backend fallback: no gateway, therefore no cryptographic
  /// proof — only the recipient's confirmation.
  manual,

  /// Settled through Xendit, confirmed by a token-verified callback to the
  /// backend. Mirrors GATEWAY_METHOD in `functions/policy.js`.
  xendit;

  static PaymentMethod fromName(String? name) => PaymentMethod.values
      .firstWhere((m) => m.name == name, orElse: () => PaymentMethod.manual);

  String get label => switch (this) {
    PaymentMethod.manual => 'Direct settlement',
    PaymentMethod.xendit => 'Xendit',
  };
}

/// What the buyer picks at checkout. Sent to the backend by [wireName]; the
/// hosted Xendit page then opens straight on that channel instead of a menu
/// of every channel. Twinned with `PAYMENT_METHODS` in `functions/xendit.js`.
enum PaymentChannel {
  gcash('gcash', 'GCash', 'Pay with your GCash wallet'),
  maya('maya', 'Maya', 'Pay with your Maya wallet'),
  card('card', 'Credit or debit card', 'Visa, Mastercard, JCB'),
  other('any', 'Other', 'GrabPay, ShopeePay and more');

  const PaymentChannel(this.wireName, this.label, this.hint);

  final String wireName;
  final String label;
  final String hint;
}

/// Where a gateway payment's money currently sits.
///
/// The platform collects the full price when the client pays and keeps it
/// until the work is accepted. Only the backend moves it, and only in step
/// with the order: `completed` releases, `cancelled` refunds. Manual
/// settlements have no hold — the freelancer was paid directly.
enum HoldStatus {
  /// Collected and held by the platform; neither party can touch it.
  held,

  /// Credited to the freelancer's wallet, minus commission.
  released,

  /// Returned to the client through the gateway.
  refunded;

  static HoldStatus? fromName(String? name) {
    for (final value in HoldStatus.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// The payment record for a single order, stored at `payments/{orderId}`.
///
/// The document id **is** the order id. This mirrors the reviews collection
/// and gives the same structural guarantee: an order can never accumulate two
/// payment records, because there is only one address for them to live at.
///
/// [amount], [commission] and [netToFreelancer] are frozen at creation and
/// rejected by security rules on update, exactly as the order's price is.
class Payment {
  const Payment({
    required this.orderId,
    required this.clientId,
    required this.freelancerId,
    required this.amount,
    required this.currency,
    required this.commission,
    required this.netToFreelancer,
    required this.status,
    required this.method,
    required this.verified,
    required this.createdAt,
    required this.updatedAt,
    this.reference,
    this.gatewayReference,
    this.paidAt,
    this.holdStatus,
    this.releasedAt,
    this.refundedAt,
    this.refundStatus,
  });

  /// Equal to the document id.
  final String orderId;
  final String clientId;
  final String freelancerId;

  /// Gross amount the client owes, copied from the order at creation.
  final int amount;
  final String currency;

  /// The platform's cut, and the freelancer's payout. Always sum to [amount].
  final int commission;
  final int netToFreelancer;

  final PaymentStatus status;
  final PaymentMethod method;

  /// True only when a **trusted server** confirmed this payment against the
  /// gateway. A client can never set this field — rules reject any write that
  /// touches it — so `verified == false` on a `paid` record means the money
  /// was attested by a human, not proven by a webhook. The UI says so plainly
  /// rather than showing both cases as an identical green tick.
  final bool verified;

  /// Manual mode: the client's own reference (a GCash reference number, say).
  final String? reference;

  /// Gateway mode: the Xendit invoice id, written by the backend.
  final String? gatewayReference;

  /// Gateway mode only; null for manual settlements and unpaid records.
  final HoldStatus? holdStatus;

  /// Set by the backend when a refund could not be sent automatically
  /// (`failed`, `manual-required`) so staff know to follow up.
  final String? refundStatus;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? paidAt;
  final DateTime? releasedAt;
  final DateTime? refundedAt;

  bool get isSettled => status == PaymentStatus.paid;

  /// Money is in the platform's hands, waiting on the order.
  bool get isHeld => isSettled && holdStatus == HoldStatus.held;

  bool involves(String uid) => uid == clientId || uid == freelancerId;

  factory Payment.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Payment(
      orderId: doc.id,
      clientId: data['clientId'] as String,
      freelancerId: data['freelancerId'] as String,
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'PHP',
      commission: (data['commission'] as num?)?.toInt() ?? 0,
      netToFreelancer: (data['netToFreelancer'] as num?)?.toInt() ?? 0,
      status: PaymentStatus.fromName(data['status'] as String?),
      method: PaymentMethod.fromName(data['method'] as String?),
      verified: data['verified'] as bool? ?? false,
      reference: data['reference'] as String?,
      gatewayReference: data['gatewayReference'] as String?,
      holdStatus: HoldStatus.fromName(data['holdStatus'] as String?),
      refundStatus: data['refundStatus'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      paidAt: (data['paidAt'] as Timestamp?)?.toDate(),
      releasedAt: (data['releasedAt'] as Timestamp?)?.toDate(),
      refundedAt: (data['refundedAt'] as Timestamp?)?.toDate(),
    );
  }
}
