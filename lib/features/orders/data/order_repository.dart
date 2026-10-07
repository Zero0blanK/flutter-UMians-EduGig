import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/storage/attachment.dart';
import '../../../core/widgets/capped_list.dart';
import '../../../core/errors/app_failure.dart';
import '../../notifications/domain/app_notification.dart';
import '../../notifications/data/notification_repository.dart';
import '../../offers/domain/offer.dart';
import '../../payments/domain/payment.dart';
import '../../services/domain/freelance_service.dart';
import '../domain/delivery.dart';
import '../domain/order.dart';

class OrderRepository {
  OrderRepository(this._firestore);

  final FirebaseFirestore _firestore;

  static const maxDeliveryNoteLength = 2000;

  /// Whether a freelancer must be paid before work may start.
  ///
  /// This is the revenue model's enforcement point: commission is only real
  /// if payment actually precedes delivery. Set to false only to demo the
  /// order flow without exercising payments.
  static const requirePaymentBeforeWork = true;

  Future<String> create({
    required FreelanceService service,
    required String buyerId,
    required String requirements,
  }) async {
    final text = requirements.trim();
    if (text.length < 10 || text.length > 4000) {
      throw const InvalidInputFailure(
        'Describe your requirements in 10-4000 characters.',
      );
    }

    // The order price is taken from the trusted service document inside a
    // transaction, never from client input, so a manipulated request cannot
    // change what the persisted order says.
    String orderId;
    try {
      orderId = await _firestore.runTransaction((transaction) async {
        final serviceRef = _firestore.doc(
          '${FirestorePaths.services}/${service.id}',
        );
        final snapshot = await transaction.get(serviceRef);
        if (!snapshot.exists) throw const NotFoundFailure();
        final current = FreelanceService.fromFirestore(snapshot);
        if (!current.isPublished) {
          throw const InvalidInputFailure(
            'This service is not accepting orders.',
          );
        }
        if (current.sellerId == buyerId) {
          throw const InvalidInputFailure('You cannot order your own service.');
        }
        // Negotiable listings, and fixed ones whose seller wants to talk
        // first, are ordered from an offer card in chat, never at the listed
        // price. Rules refuse this write too; the message here is kinder.
        if (!current.canOrderDirectly) {
          throw const InvalidInputFailure(
            'This service is ordered through an offer. Message the '
            'freelancer to agree on the scope and price first.',
          );
        }

        final orderRef = _firestore.collection(FirestorePaths.orders).doc();
        transaction.set(orderRef, {
          'serviceId': current.id,
          'serviceTitle': current.title,
          'clientId': buyerId,
          'freelancerId': current.sellerId,
          'participantIds': [buyerId, current.sellerId]..sort(),
          'price': current.startingPrice,
          'currency': current.currency,
          'deliveryDays': current.deliveryDays,
          'revisionCount': current.revisionCount,
          'requirements': text,
          'status': OrderStatus.pending.name,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return orderRef.id;
      });

      // Tell the freelancer about the new request; the backend pushes it.
      try {
        await NotificationRepository(_firestore).create(
          toUid: service.sellerId,
          type: AppNotificationType.orderCreated,
          title: 'New order request for "${service.title}"',
        );
      } on AppFailure {
        // Notification failures never roll back a legitimate order.
      }
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
    return orderId;
  }

  /// Places the order the client agreed to in chat.
  ///
  /// Two writes, in order. First the offer moves to `accepted`, which rules
  /// allow only the client to do and only from `pending`. Then, in one batch,
  /// the order is created *from the offer's figures* and the offer is marked
  /// `ordered` with the order id. Rules check the batch both ways: the order
  /// must match the offer, and the offer may only become `ordered` alongside
  /// an order that names it. An offer can therefore produce one order, ever,
  /// and that order's price is the agreed price, never the listing's.
  Future<String> createFromOffer({
    required Offer offer,
    required String buyerId,
    required String requirements,
  }) async {
    if (buyerId != offer.clientId) throw const PermissionFailure();
    final text = requirements.trim();
    if (text.length < 10 || text.length > 4000) {
      throw const InvalidInputFailure(
        'Describe your requirements in 10-4000 characters.',
      );
    }

    final offerRef = _firestore.doc('${FirestorePaths.offers}/${offer.id}');
    try {
      Offer current = offer;
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(offerRef);
        if (!snapshot.exists) throw const NotFoundFailure();
        current = Offer.fromFirestore(snapshot);
        if (current.status == OfferStatus.accepted) return; // retry path
        if (current.status != OfferStatus.pending) {
          throw const InvalidInputFailure('This offer is no longer open.');
        }
        if (current.isExpired) {
          throw const InvalidInputFailure(
            'This offer has expired. Ask the freelancer for a new one.',
          );
        }
        transaction.update(offerRef, {
          'status': OfferStatus.accepted.name,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      final orderRef = _firestore.collection(FirestorePaths.orders).doc();
      final batch = _firestore.batch();
      batch.set(orderRef, {
        'serviceId': current.serviceId,
        'serviceTitle': current.serviceTitle,
        'clientId': current.clientId,
        'freelancerId': current.freelancerId,
        'participantIds': [current.clientId, current.freelancerId]..sort(),
        'price': current.price,
        'currency': 'PHP',
        'deliveryDays': current.deliveryDays,
        'revisionCount': current.revisionCount,
        'requirements': text,
        'scope': current.scope,
        'offerId': current.id,
        'status': OrderStatus.pending.name,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      batch.update(offerRef, {
        'status': OfferStatus.ordered.name,
        'orderId': orderRef.id,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();

      try {
        await NotificationRepository(_firestore).create(
          toUid: current.freelancerId,
          type: AppNotificationType.offerAccepted,
          title: 'Offer accepted: ${current.serviceTitle}',
          conversationId: current.conversationId,
        );
        await NotificationRepository(_firestore).create(
          toUid: current.freelancerId,
          type: AppNotificationType.orderCreated,
          title: 'New order from your offer for "${current.serviceTitle}"',
          orderId: orderRef.id,
        );
      } on AppFailure {
        // Notification failures never roll back a legitimate order.
      }
      return orderRef.id;
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Most recent orders involving [uid].
  ///
  /// Reports whether the ceiling was hit so the screen can say that older
  /// orders exist rather than pretending these are all of them.
  static const recentOrderLimit = 50;

  Stream<CappedList<WorkOrder>> watchInvolving(
    String uid, {
    int limit = recentOrderLimit,
  }) {
    return _firestore
        .collection(FirestorePaths.orders)
        .where('participantIds', arrayContains: uid)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => CappedList(
            items: snapshot.docs.map(WorkOrder.fromFirestore).toList(),
            truncated: snapshot.docs.length == limit,
          ),
        );
  }

  Stream<WorkOrder> watchById(String orderId) {
    return _firestore.doc('${FirestorePaths.orders}/$orderId').snapshots().map((
      snapshot,
    ) {
      if (!snapshot.exists) throw const NotFoundFailure();
      return WorkOrder.fromFirestore(snapshot);
    });
  }

  /// Applies a state transition inside a transaction that re-validates the
  /// current status and the actor's role, so concurrent or out-of-order
  /// requests cannot corrupt the state machine.
  Future<void> transition({
    required String orderId,
    required String actorId,
    required OrderStatus next,
    String? disputeReason,
  }) async {
    final normalizedDisputeReason = disputeReason?.trim();
    if (next == OrderStatus.disputed &&
        (normalizedDisputeReason == null ||
            normalizedDisputeReason.length < 10 ||
            normalizedDisputeReason.length > 1000)) {
      throw const InvalidInputFailure(
        'Describe the problem in 10-1000 characters so staff can review it.',
      );
    }
    if (next != OrderStatus.disputed && disputeReason != null) {
      throw const InvalidInputFailure(
        'A dispute reason can only be added when opening a dispute.',
      );
    }
    try {
      WorkOrder? order;
      await _firestore.runTransaction((transaction) async {
        final reference = _firestore.doc('${FirestorePaths.orders}/$orderId');
        final snapshot = await transaction.get(reference);
        if (!snapshot.exists) throw const NotFoundFailure();
        order = WorkOrder.fromFirestore(snapshot);

        if (!order!.involves(actorId)) throw const PermissionFailure();
        if (!order!.canTransition(actorId, next)) {
          throw InvalidInputFailure(
            'Cannot move this order from ${order!.status.label} to ${next.label}.',
          );
        }

        // Work may not begin on an unpaid order. Read inside the same
        // transaction (and before any write) so a payment cannot be reversed
        // between the check and the status change.
        if (requirePaymentBeforeWork && next == OrderStatus.inProgress) {
          final payment = await transaction.get(
            _firestore.doc('${FirestorePaths.payments}/$orderId'),
          );
          final settled =
              payment.exists &&
              Payment.fromFirestore(payment).status == PaymentStatus.paid;
          if (!settled) throw const PaymentRequiredFailure();
        }

        final update = <String, dynamic>{
          'status': next.name,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (next == OrderStatus.disputed) {
          update['disputeReason'] = normalizedDisputeReason;
        }
        if (next == OrderStatus.accepted) {
          update['deadline'] = Timestamp.fromDate(
            DateTime.now().add(Duration(days: order!.deliveryDays)),
          );
        }
        transaction.update(reference, update);
      });

      // Inbox notification for the counterpart; the backend pushes it.
      final updated = order!;
      final recipient = actorId == updated.clientId
          ? updated.freelancerId
          : updated.clientId;
      try {
        await NotificationRepository(_firestore).create(
          toUid: recipient,
          type: switch (next) {
            OrderStatus.accepted => AppNotificationType.orderAccepted,
            OrderStatus.rejected => AppNotificationType.orderRejected,
            OrderStatus.inProgress => AppNotificationType.orderStarted,
            OrderStatus.submitted => AppNotificationType.orderSubmitted,
            OrderStatus.revisionRequested =>
              AppNotificationType.orderRevisionRequested,
            OrderStatus.completed => AppNotificationType.orderCompleted,
            OrderStatus.cancelled => AppNotificationType.orderCancelled,
            _ => AppNotificationType.systemAnnouncement,
          },
          title: '${updated.serviceTitle}: ${next.label}',
          orderId: orderId,
        );
      } on AppFailure {
        // Notification failures never roll back a legitimate transition.
      }
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Whether this order already has its (deterministically-id'd) review.
  Stream<bool> watchReviewed(String orderId) {
    return _firestore
        .doc('${FirestorePaths.reviews}/$orderId')
        .snapshots()
        .map((snapshot) => snapshot.exists);
  }

  /// Submits a delivery: a note plus files already uploaded to Storage.
  /// Only the freelancer may call this (enforced again by rules).
  Future<void> submitDelivery({
    required String orderId,
    required String freelancerId,
    required String note,
    List<Attachment> attachments = const [],
  }) async {
    final text = note.trim();
    if (text.isEmpty || text.length > maxDeliveryNoteLength) {
      throw InvalidInputFailure(
        'Delivery notes must be 1-$maxDeliveryNoteLength characters.',
      );
    }
    if (attachments.length > Delivery.maxAttachments) {
      throw const InvalidInputFailure(
        'A delivery can carry up to ${Delivery.maxAttachments} files.',
      );
    }

    try {
      await _firestore
          .collection('${FirestorePaths.orders}/$orderId/deliveries')
          .add({
            'senderId': freelancerId,
            'note': text,
            if (attachments.isNotEmpty)
              'attachments': [for (final a in attachments) a.toMap()],
            'createdAt': FieldValue.serverTimestamp(),
          });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Stream<List<Delivery>> watchDeliveries(String orderId) {
    return _firestore
        .collection('${FirestorePaths.orders}/$orderId/deliveries')
        .orderBy('createdAt', descending: false)
        .limit(50)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(Delivery.fromFirestore).toList());
  }
}
