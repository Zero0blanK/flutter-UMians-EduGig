import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/widgets/capped_list.dart';
import '../domain/app_notification.dart';

/// Notifications inbox.
///
/// Without Cloud Functions (a paid-plan service), notifications are written
/// directly by the acting client inside the same batch as its business write,
/// and validated by strict per-type security rules. They are consumed via
/// realtime Firestore streams — there are no push notifications on the free
/// tier.
class NotificationRepository {
  NotificationRepository(this._firestore);

  final FirebaseFirestore _firestore;

  static const maxTitleLength = 140;

  /// How long a notification is kept.
  ///
  /// Nothing ever deleted these, so an active user's inbox grew without bound
  /// and every read paid for it. `expiresAt` is the field a Firestore TTL
  /// policy watches: configure the policy once on
  /// `users/{uid}/notifications.expiresAt` and the server deletes them on its
  /// own — no Cloud Functions, no client-side sweep. Until the policy exists
  /// the field is simply inert.
  static const retention = Duration(days: 60);

  /// Writes a notification document into [toUid]'s inbox.
  ///
  /// Security rules independently verify the sender↔recipient relationship
  /// for each type (conversation participant, order participant, or completed
  /// order's client), so arbitrary users cannot spam inboxes.
  Future<void> create({
    required String toUid,
    required AppNotificationType type,
    required String title,
    String? conversationId,
    String? orderId,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed.length > maxTitleLength) {
      throw InvalidInputFailure('Invalid notification title.');
    }
    try {
      await _firestore.collection(FirestorePaths.notifications(toUid)).add({
        'type': type.wireName,
        'title': trimmed,
        'body': '',
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(DateTime.now().add(retention)),
        'conversationId': ?conversationId,
        'orderId': ?orderId,
      });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  static const recentNotificationLimit = 50;

  Stream<CappedList<AppNotification>> watchNotifications(
    String uid, {
    int limit = recentNotificationLimit,
  }) {
    return _firestore
        .collection(FirestorePaths.notifications(uid))
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => CappedList(
            items: snapshot.docs
                .map((doc) => AppNotification.fromMap(doc.id, doc.data()))
                .toList(),
            truncated: snapshot.docs.length == limit,
          ),
        );
  }

  /// Only the unread ones, newest first: what the shell's badge and
  /// foreground banner need. A student with a long inbox otherwise pays for
  /// [recentNotificationLimit] documents on every app open for a count that
  /// is usually zero. Composite index: `read` + `createdAt`.
  Stream<List<AppNotification>> watchUnread(String uid) {
    return _firestore
        .collection(FirestorePaths.notifications(uid))
        .where('read', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .limit(recentNotificationLimit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => AppNotification.fromMap(doc.id, doc.data()))
              .toList(),
        );
  }

  Future<void> markAllRead(String uid) async {
    try {
      final unread = await _firestore
          .collection(FirestorePaths.notifications(uid))
          .where('read', isEqualTo: false)
          .limit(500)
          .get();
      if (unread.docs.isEmpty) return;
      final batch = _firestore.batch();
      for (final doc in unread.docs) {
        batch.update(doc.reference, <String, dynamic>{'read': true});
      }
      await batch.commit();
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }
}
