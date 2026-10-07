import 'package:cloud_firestore/cloud_firestore.dart';

import 'order_transitions.dart';

/// How long a submitted delivery waits for the client before the backend
/// completes it on their behalf. A client who simply closes the app must not
/// be able to keep a freelancer unpaid indefinitely; they keep every right
/// they had (revision, dispute) for this long. Mirrors AUTO_COMPLETE_DAYS in
/// `functions/policy.js`.
const kAutoCompleteAfter = Duration(days: 3);

enum OrderStatus {
  pending,
  accepted,
  rejected,
  inProgress,
  submitted,
  revisionRequested,
  completed,
  cancelled,
  disputed;

  static OrderStatus fromName(String? name) => OrderStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => OrderStatus.pending,
  );

  /// True for the states an order can never leave. A deadline on one of these
  /// is history, not something anyone still has to act on.
  bool get isFinished =>
      this == OrderStatus.completed ||
      this == OrderStatus.cancelled ||
      this == OrderStatus.rejected ||
      this == OrderStatus.disputed;

  String get label => switch (this) {
    OrderStatus.pending => 'Pending',
    OrderStatus.accepted => 'Accepted',
    OrderStatus.rejected => 'Rejected',
    OrderStatus.inProgress => 'In progress',
    OrderStatus.submitted => 'Submitted',
    OrderStatus.revisionRequested => 'Revision requested',
    OrderStatus.completed => 'Completed',
    OrderStatus.cancelled => 'Cancelled',
    OrderStatus.disputed => 'Disputed',
  };
}

enum OrderRole { client, freelancer }

/// Who may close a dispute. Mirrors DISPUTE_SECOND_OPINION_FROM in
/// `functions/policy.js` and the literal in the disputed-order rule.
abstract final class DisputePolicy {
  /// From this price up, one staff member proposes and a different one
  /// closes; below it a single decision stands.
  static const secondOpinionFrom = 2000;

  static bool needsSecondOpinion(int price) => price >= secondOpinionFrom;
}

/// A staff member's recorded decision on a disputed order, waiting for a
/// second staff member to confirm it.
class DisputeProposal {
  const DisputeProposal({
    required this.outcome,
    required this.proposedBy,
    required this.proposedAt,
  });

  final OrderStatus outcome;
  final String proposedBy;
  final DateTime proposedAt;

  static DisputeProposal? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    return DisputeProposal(
      outcome: OrderStatus.fromName(data['outcome'] as String?),
      proposedBy: data['proposedBy'] as String? ?? '',
      proposedAt:
          (data['proposedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

/// A purchase of a [FreelanceService]. Price and participants are immutable
/// after creation; security rules reject any attempt to change them.
class WorkOrder {
  const WorkOrder({
    required this.id,
    required this.serviceId,
    required this.serviceTitle,
    required this.clientId,
    required this.freelancerId,
    required this.price,
    required this.currency,
    required this.deliveryDays,
    required this.revisionCount,
    required this.requirements,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.deadline,
    this.autoCompleted = false,
    this.offerId,
    this.scope,
    this.disputeReason,
    this.disputeResolution,
  });

  final String id;
  final String serviceId;
  final String serviceTitle;
  final String clientId;
  final String freelancerId;
  final int price;
  final String currency;
  final int deliveryDays;
  final int revisionCount;
  final String requirements;
  final OrderStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deadline;

  /// True when the backend completed this order because the client never
  /// responded to the delivery, rather than the client accepting it.
  final bool autoCompleted;

  /// The accepted offer this order was created from, when the price was
  /// negotiated rather than taken from the listing. Null for direct orders.
  final String? offerId;

  /// The freelancer's statement of what they will deliver, copied from the
  /// offer. Sits beside the client's requirements on the order screen.
  final String? scope;

  /// The explanation supplied by the party who opened the dispute. It is
  /// immutable evidence for staff, unlike a chat message that may be buried.
  final String? disputeReason;

  /// Present only while a dispute above [DisputePolicy.secondOpinionFrom]
  /// waits for a second staff member.
  final DisputeProposal? disputeResolution;

  bool get isNegotiated => offerId != null;

  /// Whether [staffUid] may close this dispute as [outcome] right now: any
  /// decision below the threshold, otherwise only one that confirms a
  /// different staff member's proposal.
  bool canResolveDispute(String staffUid, OrderStatus outcome) {
    if (status != OrderStatus.disputed) return false;
    if (outcome != OrderStatus.completed && outcome != OrderStatus.cancelled) {
      return false;
    }
    if (!DisputePolicy.needsSecondOpinion(price)) return true;
    final proposal = disputeResolution;
    return proposal != null &&
        proposal.outcome == outcome &&
        proposal.proposedBy != staffUid;
  }

  /// When a `submitted` order completes itself if the client stays silent.
  /// Null in every other state.
  DateTime? get autoCompletesAt => status == OrderStatus.submitted
      ? updatedAt.add(kAutoCompleteAfter)
      : null;

  OrderRole roleOf(String uid) =>
      uid == clientId ? OrderRole.client : OrderRole.freelancer;

  bool involves(String uid) => uid == clientId || uid == freelancerId;

  /// Whether [uid] may move this order to [next] given its current status.
  bool canTransition(String uid, OrderStatus next) {
    if (!involves(uid)) return false;
    final role = roleOf(uid);
    return kOrderTransitions[status]!.contains(next) &&
        (kTransitionActors[(status, next)]?.contains(role) ?? false);
  }

  factory WorkOrder.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return WorkOrder(
      id: doc.id,
      serviceId: data['serviceId'] as String,
      serviceTitle: data['serviceTitle'] as String? ?? '',
      clientId: data['clientId'] as String,
      freelancerId: data['freelancerId'] as String,
      price: (data['price'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'PHP',
      deliveryDays: (data['deliveryDays'] as num?)?.toInt() ?? 0,
      revisionCount: (data['revisionCount'] as num?)?.toInt() ?? 0,
      requirements: data['requirements'] as String? ?? '',
      status: OrderStatus.fromName(data['status'] as String?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      deadline: (data['deadline'] as Timestamp?)?.toDate(),
      autoCompleted: data['autoCompleted'] as bool? ?? false,
      offerId: data['offerId'] as String?,
      scope: data['scope'] as String?,
      disputeReason: data['disputeReason'] as String?,
      disputeResolution: DisputeProposal.fromMap(
        (data['disputeResolution'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}
