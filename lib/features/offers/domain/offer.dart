import 'package:cloud_firestore/cloud_firestore.dart';

/// A negotiated quote, sent by the freelancer inside a conversation.
///
/// For a negotiable service (or a fixed-price one whose seller wants to talk
/// first) the listed price is only a starting point. The two students agree
/// on scope, price, revisions and duration in chat; the freelancer then sends
/// an offer card holding exactly those terms; the client accepts it; and the
/// order is created *from the offer*, with the offer's price frozen into it.
/// The listing's starting price never reaches such an order.
enum OfferStatus {
  /// Sent, waiting for the client.
  pending,

  /// The client agreed; an order can be placed from it (once).
  accepted,

  /// The client turned it down.
  declined,

  /// The freelancer took it back before a decision.
  withdrawn,

  /// An order was created from it; the offer is spent.
  ordered,

  /// Sat unanswered past its expiry.
  expired;

  static OfferStatus fromName(String? name) => OfferStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => OfferStatus.pending,
  );

  String get label => switch (this) {
    OfferStatus.pending => 'Waiting for your answer',
    OfferStatus.accepted => 'Accepted',
    OfferStatus.declined => 'Declined',
    OfferStatus.withdrawn => 'Withdrawn',
    OfferStatus.ordered => 'Ordered',
    OfferStatus.expired => 'Expired',
  };

  bool get isOpen =>
      this == OfferStatus.pending || this == OfferStatus.accepted;
}

class Offer {
  const Offer({
    required this.id,
    required this.serviceId,
    required this.serviceTitle,
    required this.freelancerId,
    required this.clientId,
    required this.conversationId,
    required this.price,
    required this.deliveryDays,
    required this.revisionCount,
    required this.scope,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.orderId,
  });

  /// How long an unanswered offer stays valid. Mirrors OFFER_VALID_DAYS in
  /// `functions/policy.js`.
  static const validity = Duration(days: 7);

  static const maxScopeLength = 2000;
  static const minScopeLength = 10;

  final String id;
  final String serviceId;
  final String serviceTitle;
  final String freelancerId;
  final String clientId;
  final String conversationId;

  /// The agreed price. Copied into the order at creation and frozen there.
  final int price;
  final int deliveryDays;
  final int revisionCount;

  /// What the freelancer will deliver, in their words. Becomes the order's
  /// `scope`, shown beside the client's requirements.
  final String scope;
  final OfferStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// Set once the client placed the order from this offer.
  final String? orderId;

  bool get isExpired =>
      status == OfferStatus.pending && DateTime.now().isAfter(expiresAt);

  bool involves(String uid) => uid == clientId || uid == freelancerId;

  factory Offer.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Offer(
      id: doc.id,
      serviceId: data['serviceId'] as String? ?? '',
      serviceTitle: data['serviceTitle'] as String? ?? '',
      freelancerId: data['freelancerId'] as String? ?? '',
      clientId: data['clientId'] as String? ?? '',
      conversationId: data['conversationId'] as String? ?? '',
      price: (data['price'] as num?)?.toInt() ?? 0,
      deliveryDays: (data['deliveryDays'] as num?)?.toInt() ?? 1,
      revisionCount: (data['revisionCount'] as num?)?.toInt() ?? 0,
      scope: data['scope'] as String? ?? '',
      status: OfferStatus.fromName(data['status'] as String?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      expiresAt:
          (data['expiresAt'] as Timestamp?)?.toDate() ??
          DateTime.now().add(validity),
      orderId: data['orderId'] as String?,
    );
  }
}
