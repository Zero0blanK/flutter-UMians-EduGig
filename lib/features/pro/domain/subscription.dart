import 'package:cloud_firestore/cloud_firestore.dart';

/// One Pro checkout, as the backend records it at `subscriptions/{invoice}`.
/// Written only by the backend; the app reads its own.
class Subscription {
  const Subscription({
    required this.id,
    required this.uid,
    required this.amount,
    required this.status,
    required this.createdAt,
    this.paidAt,
    this.periodEnd,
  });

  final String id;
  final String uid;
  final int amount;

  /// `pending`, `paid`, or `failed`.
  final String status;
  final DateTime createdAt;
  final DateTime? paidAt;
  final DateTime? periodEnd;

  bool get isPaid => status == 'paid';

  factory Subscription.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return Subscription(
      id: doc.id,
      uid: data['uid'] as String? ?? '',
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'pending',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      paidAt: (data['paidAt'] as Timestamp?)?.toDate(),
      periodEnd: (data['periodEnd'] as Timestamp?)?.toDate(),
    );
  }
}
