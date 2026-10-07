import 'package:cloud_firestore/cloud_firestore.dart';

/// Notification types are a closed enum. Senders are verified per type by
/// security rules; never branch on display text.
enum AppNotificationType {
  chatMessage('chat.message'),
  offerReceived('offer.received'),
  offerAccepted('offer.accepted'),
  offerDeclined('offer.declined'),
  orderCreated('order.created'),
  orderAccepted('order.accepted'),
  orderRejected('order.rejected'),
  orderStarted('order.started'),
  orderSubmitted('order.submitted'),
  orderRevisionRequested('order.revision_requested'),
  orderCompleted('order.completed'),
  orderCancelled('order.cancelled'),
  paymentConfirmed('payment.confirmed'),
  reviewReceived('review.received'),
  // Written by the backend only (Admin SDK); rules never allow a client to
  // create these, so a "payout sent" can never be forged by a peer.
  paymentReleased('payment.released'),
  paymentRefunded('payment.refunded'),
  paymentChargedBack('payment.charged_back'),
  walletDormant('wallet.dormant'),
  payoutPaid('payout.paid'),
  payoutRejected('payout.rejected'),
  proActivated('pro.activated'),
  verificationApproved('verification.approved'),
  verificationRejected('verification.rejected'),
  orderAutoCompleteReminder('order.auto_complete_reminder'),
  adminRefundAttention('admin.refund_attention'),
  adminPayoutRequested('admin.payout_requested'),
  adminVerificationPending('admin.verification_pending'),
  adminDormantWallet('admin.dormant_wallet'),
  systemAnnouncement('system.announcement');

  const AppNotificationType(this.wireName);

  final String wireName;

  static AppNotificationType? fromWire(String? name) {
    for (final type in AppNotificationType.values) {
      if (type.wireName == name) return type;
    }
    return null;
  }
}

/// A persisted notification document at users/{uid}/notifications/{id}.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.read,
    required this.createdAt,
    this.conversationId,
    this.orderId,
  });

  final String id;
  final AppNotificationType type;

  /// Generic, lock-screen-safe copy. No message content ever goes here.
  final String title;
  final String body;
  final bool read;
  final DateTime createdAt;
  final String? conversationId;
  final String? orderId;

  factory AppNotification.fromMap(String id, Map<String, dynamic> data) {
    return AppNotification(
      id: id,
      type:
          AppNotificationType.fromWire(data['type'] as String?) ??
          AppNotificationType.systemAnnouncement,
      title: data['title'] as String? ?? 'Notification',
      body: data['body'] as String? ?? '',
      read: data['read'] as bool? ?? false,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      conversationId: data['conversationId'] as String?,
      orderId: data['orderId'] as String?,
    );
  }

  /// Payload for the centralized notification router.
  Map<String, dynamic> toRouteData() => {
    'type': type.wireName,
    if (conversationId != null) 'conversationId': conversationId,
    if (orderId != null) 'orderId': orderId,
  };
}
