import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../notifications/data/notification_repository.dart';
import '../../notifications/domain/app_notification.dart';
import '../../services/domain/freelance_service.dart';
import '../domain/offer.dart';

/// Writes and reads offers. Placing the order from an accepted offer lives in
/// `OrderRepository.createFromOffer`, which is the only place an order is
/// ever created with a negotiated price.
class OfferRepository {
  OfferRepository(this._firestore);

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _ref(String id) =>
      _firestore.doc('${FirestorePaths.offers}/$id');

  Stream<Offer?> watch(String offerId) {
    return _ref(offerId).snapshots().map(
      (snapshot) => snapshot.exists ? Offer.fromFirestore(snapshot) : null,
    );
  }

  /// Sends an offer card into the conversation, in one batch: the offer
  /// document, a chat message that points at it, and the client's
  /// notification. Rules check that the sender owns the service, that the
  /// client is the other participant, and that every figure is in range.
  Future<String> send({
    required FreelanceService service,
    required String freelancerId,
    required String clientId,
    required int price,
    required int deliveryDays,
    required int revisionCount,
    required String scope,
  }) async {
    if (service.sellerId != freelancerId) throw const PermissionFailure();
    if (!service.isPublished) {
      throw const InvalidInputFailure(
        'Only a published listing can be offered.',
      );
    }
    if (clientId == freelancerId) {
      throw const InvalidInputFailure('You cannot send an offer to yourself.');
    }
    if (price < 1 || price > 1000000) {
      throw const InvalidInputFailure(
        'Price must be between ₱1 and ₱1,000,000.',
      );
    }
    if (deliveryDays < 1 || deliveryDays > 90) {
      throw const InvalidInputFailure('Delivery must be 1-90 days.');
    }
    if (revisionCount < 0 || revisionCount > 10) {
      throw const InvalidInputFailure('Revisions must be 0-10.');
    }
    final text = scope.trim();
    if (text.length < Offer.minScopeLength ||
        text.length > Offer.maxScopeLength) {
      throw const InvalidInputFailure(
        'Describe the scope in ${Offer.minScopeLength}-${Offer.maxScopeLength} characters.',
      );
    }

    final conversationId = FirestorePaths.conversationIdFor(
      freelancerId,
      clientId,
    );
    final offerRef = _firestore.collection(FirestorePaths.offers).doc();
    final now = DateTime.now();
    try {
      final batch = _firestore.batch();
      batch.set(offerRef, {
        'serviceId': service.id,
        'serviceTitle': service.title,
        'freelancerId': freelancerId,
        'clientId': clientId,
        'participantIds': [freelancerId, clientId]..sort(),
        'conversationId': conversationId,
        'price': price,
        'currency': service.currency,
        'deliveryDays': deliveryDays,
        'revisionCount': revisionCount,
        'scope': text,
        'status': OfferStatus.pending.name,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(now.add(Offer.validity)),
      });
      // The card in the chat is a message that references the offer; the
      // card itself streams the offer document, so its status is always live.
      batch.set(
        _firestore.collection(FirestorePaths.messages(conversationId)).doc(),
        {
          'senderId': freelancerId,
          'text': '',
          'offerId': offerRef.id,
          'sentAt': FieldValue.serverTimestamp(),
        },
      );
      batch.update(
        _firestore.doc('${FirestorePaths.conversations}/$conversationId'),
        {
          'lastMessagePreview': '📋 Offer: ₱$price for ${service.title}',
          'lastMessageSenderId': freelancerId,
          'lastMessageAt': FieldValue.serverTimestamp(),
          'unreadCount.$clientId': FieldValue.increment(1),
          'unreadCount.$freelancerId': 0,
        },
      );
      batch.set(
        _firestore.collection(FirestorePaths.notifications(clientId)).doc(),
        {
          'type': AppNotificationType.offerReceived.wireName,
          'title': 'New offer: ₱$price for ${service.title}',
          'body': '',
          'read': false,
          'conversationId': conversationId,
          'createdAt': FieldValue.serverTimestamp(),
          'expiresAt': Timestamp.fromDate(
            now.add(NotificationRepository.retention),
          ),
        },
      );
      await batch.commit();
      return offerRef.id;
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// The client declines, or the freelancer withdraws. Accepting goes
  /// through `OrderRepository.createFromOffer`, which accepts and orders in
  /// one flow so an accepted offer is never left dangling.
  Future<void> close({
    required String offerId,
    required String actorId,
    required OfferStatus outcome,
  }) async {
    if (outcome != OfferStatus.declined && outcome != OfferStatus.withdrawn) {
      throw const InvalidInputFailure(
        'An offer can only be declined or withdrawn.',
      );
    }
    try {
      Offer? offer;
      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(_ref(offerId));
        if (!snapshot.exists) throw const NotFoundFailure();
        offer = Offer.fromFirestore(snapshot);
        final expectedActor = outcome == OfferStatus.declined
            ? offer!.clientId
            : offer!.freelancerId;
        if (actorId != expectedActor) throw const PermissionFailure();
        if (offer!.status != OfferStatus.pending) {
          throw const InvalidInputFailure('This offer is no longer open.');
        }
        transaction.update(_ref(offerId), {
          'status': outcome.name,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      if (outcome == OfferStatus.declined) {
        try {
          await NotificationRepository(_firestore).create(
            toUid: offer!.freelancerId,
            type: AppNotificationType.offerDeclined,
            title: 'Offer declined: ${offer!.serviceTitle}',
            conversationId: offer!.conversationId,
          );
        } on AppFailure {
          // The decision stands without the notification.
        }
      }
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }
}
