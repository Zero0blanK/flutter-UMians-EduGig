import 'package:cloud_firestore/cloud_firestore.dart';

import '../../orders/domain/order.dart';

/// Headline figures for the staff dashboard.
///
/// Money is kept in whole pesos, as everywhere else in the app, and the three
/// revenue figures are related by construction: gross is what clients paid,
/// commission is the platform's share, and the payout is the remainder. They
/// are not three independent measurements that might disagree.
class PlatformMetrics {
  const PlatformMetrics({
    required this.users,
    required this.services,
    required this.publishedServices,
    required this.orders,
    required this.reviews,
    required this.ordersByStatus,
    required this.settledPayments,
    required this.grossMerchandiseValue,
    required this.commissionEarned,
    required this.paidOutToFreelancers,
  });

  static const empty = PlatformMetrics(
    users: 0,
    services: 0,
    publishedServices: 0,
    orders: 0,
    reviews: 0,
    ordersByStatus: {},
    settledPayments: 0,
    grossMerchandiseValue: 0,
    commissionEarned: 0,
    paidOutToFreelancers: 0,
  );

  final int users;
  final int services;
  final int publishedServices;
  final int orders;
  final int reviews;
  final Map<OrderStatus, int> ordersByStatus;

  /// Orders whose money actually arrived. Pending payments are excluded: an
  /// intention to pay is not revenue.
  final int settledPayments;

  /// Total value of settled orders.
  final int grossMerchandiseValue;

  /// The platform's 5% share of that value — the revenue model, measured.
  final int commissionEarned;

  final int paidOutToFreelancers;

  int countOf(OrderStatus status) => ordersByStatus[status] ?? 0;

  /// Share of all orders that reached `completed`, as a percentage.
  ///
  /// Orders still in flight are counted in the denominator, so a young
  /// marketplace reads low rather than flattering itself.
  double get completionRate =>
      orders == 0 ? 0 : (countOf(OrderStatus.completed) / orders) * 100;

  /// Share of orders that ended in dispute — the number worth watching.
  double get disputeRate =>
      orders == 0 ? 0 : (countOf(OrderStatus.disputed) / orders) * 100;

  /// Average value of a settled order.
  int get averageOrderValue =>
      settledPayments == 0 ? 0 : grossMerchandiseValue ~/ settledPayments;
}

/// One entry in the staff audit trail.
class AdminAction {
  const AdminAction({
    required this.id,
    required this.actorId,
    required this.action,
    required this.targetType,
    required this.targetId,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String actorId;

  /// A dotted verb, e.g. `dispute.completed` or `service.paused`.
  final String action;
  final String targetType;
  final String targetId;
  final String note;
  final DateTime createdAt;

  /// "Dispute completed", "Service paused" — the action id read aloud.
  String get label {
    final parts = action.split('.');
    if (parts.length != 2) return action;
    final subject = parts[0][0].toUpperCase() + parts[0].substring(1);
    return '$subject ${parts[1]}';
  }

  factory AdminAction.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return AdminAction(
      id: doc.id,
      actorId: data['actorId'] as String? ?? '',
      action: data['action'] as String? ?? '',
      targetType: data['targetType'] as String? ?? '',
      targetId: data['targetId'] as String? ?? '',
      note: data['note'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
