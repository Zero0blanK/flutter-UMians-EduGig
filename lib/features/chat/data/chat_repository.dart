import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/storage/attachment.dart';
import '../../../core/widgets/capped_list.dart';
import '../../auth/domain/user_profile.dart';
import '../../notifications/data/notification_repository.dart';
import '../../notifications/domain/app_notification.dart';
import '../domain/chat_models.dart';

/// What a row needs to know about another student: the name, and whether
/// they carry the verified badge.
class PeerSummary {
  const PeerSummary({required this.name, required this.verified});

  final String name;
  final bool verified;
}

class ChatRepository {
  ChatRepository(this._firestore);

  static const maxMessageLength = 2000;
  static const messagePageSize = 30;

  final FirebaseFirestore _firestore;

  /// Session-local profile cache so conversation lists don't issue one
  /// user read per tile per rebuild. Holds the badge too, so a name and its
  /// check mark come from the same read.
  final Map<String, PeerSummary> _peerCache = {};

  Future<String> displayNameOf(String uid) async => (await summaryOf(uid)).name;

  Future<PeerSummary> summaryOf(String uid) async {
    final cached = _peerCache[uid];
    if (cached != null) return cached;
    try {
      final doc = await _firestore.doc(FirestorePaths.user(uid)).get();
      final data = doc.data();
      final summary = data == null
          ? const PeerSummary(name: 'Student', verified: false)
          : PeerSummary(
              name: data['displayName'] as String? ?? 'Student',
              verified: UserProfile.fromFirestore(doc).hasVerifiedBadge,
            );
      _peerCache[uid] = summary;
      return summary;
    } on FirebaseException {
      return const PeerSummary(name: 'Student', verified: false);
    }
  }

  /// Returns the deterministic two-party conversation id, creating the
  /// conversation document if needed. Idempotent by construction.
  Future<String> openConversationWith({
    required String me,
    required String other,
  }) async {
    if (me.isEmpty || other.isEmpty) {
      throw const InvalidInputFailure('Invalid participant.');
    }
    final id = FirestorePaths.conversationIdFor(me, other);
    try {
      // Create only when absent. A merge that re-stamped createdAt on every
      // open was rejected by the update rule, which pins createdAt — so
      // reopening an existing chat failed with permission-denied. The
      // transaction also settles the race between two people opening the same
      // conversation at once.
      await _firestore.runTransaction((transaction) async {
        final reference = _firestore.doc('${FirestorePaths.conversations}/$id');
        final snapshot = await transaction.get(reference);
        if (snapshot.exists) return;
        transaction.set(reference, {
          'participantIds': [me, other]..sort(),
          'unreadCount': {me: 0, other: 0},
          'lastMessagePreview': '',
          'lastMessageSenderId': '',
          'lastMessageAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
      return id;
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Fetches a conversation once, or null if it does not exist.
  Future<Conversation?> fetchConversation(String conversationId) async {
    try {
      final doc = await _firestore
          .doc('${FirestorePaths.conversations}/$conversationId')
          .get();
      return doc.exists ? Conversation.fromFirestore(doc) : null;
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  static const recentConversationLimit = 50;

  Stream<CappedList<Conversation>> watchConversations(
    String uid, {
    int limit = recentConversationLimit,
  }) {
    return _firestore
        .collection(FirestorePaths.conversations)
        .where('participantIds', arrayContains: uid)
        .orderBy('lastMessageAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => CappedList(
            items: snapshot.docs.map(Conversation.fromFirestore).toList(),
            truncated: snapshot.docs.length == limit,
          ),
        );
  }

  /// Newest-first page of messages; UI reverses for display. Paginated with
  /// `startAfterDocument` when older history is requested.
  Stream<List<ChatMessage>> watchMessages(
    String conversationId, {
    DocumentSnapshot? startAfter,
  }) {
    Query<Map<String, dynamic>> query = _firestore
        .collection(FirestorePaths.messages(conversationId))
        .orderBy('sentAt', descending: true)
        .limit(messagePageSize);
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    return query.snapshots().map(
      (snapshot) => snapshot.docs.map(ChatMessage.fromFirestore).toList(),
    );
  }

  Future<void> sendText({
    required String conversationId,
    required String senderId,
    required String rawText,
    String? serviceId,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    if (text.length > maxMessageLength) {
      throw InvalidInputFailure(
        'Messages are limited to $maxMessageLength characters.',
      );
    }
    await _appendMessage(
      conversationId: conversationId,
      senderId: senderId,
      text: text,
      serviceId: serviceId,
    );
  }

  /// Sends a file that has already been uploaded to Cloud Storage, with an
  /// optional caption. Upload first, then write: a message that references
  /// a file which failed to upload is worse than a failed send.
  Future<void> sendAttachment({
    required String conversationId,
    required String senderId,
    required Attachment attachment,
    String caption = '',
    String? serviceId,
  }) async {
    final text = caption.trim();
    if (text.length > maxMessageLength) {
      throw InvalidInputFailure(
        'Messages are limited to $maxMessageLength characters.',
      );
    }
    await _appendMessage(
      conversationId: conversationId,
      senderId: senderId,
      text: text,
      attachment: attachment,
      serviceId: serviceId,
    );
  }

  Future<void> _appendMessage({
    required String conversationId,
    required String senderId,
    required String text,
    Attachment? attachment,
    String? serviceId,
  }) async {
    try {
      ChatServiceReference? serviceReference;
      if (serviceId != null) {
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(serviceId)) {
          throw const InvalidInputFailure('Invalid service reference.');
        }
        final service = await _firestore
            .doc('${FirestorePaths.services}/$serviceId')
            .get();
        final data = service.data();
        if (data == null ||
            data['status'] != 'published' ||
            data['sellerId'] != otherParticipantOf(conversationId, senderId)) {
          throw const InvalidInputFailure(
            'This service is no longer available for this conversation.',
          );
        }
        serviceReference = ChatServiceReference(
          id: serviceId,
          title: data['title'] as String,
        );
      }
      final batch = _firestore.batch();
      final messageRef = _firestore
          .collection(FirestorePaths.messages(conversationId))
          .doc();
      batch.set(
        messageRef,
        ChatMessage(
          id: '',
          senderId: senderId,
          text: text,
          sentAt: DateTime.now(),
          attachment: attachment,
          serviceReference: serviceReference,
        ).toFirestore(),
      );

      final recipient = otherParticipantOf(conversationId, senderId);
      batch.update(
        _firestore.doc('${FirestorePaths.conversations}/$conversationId'),
        {
          'lastMessagePreview': _previewOf(
            text.isNotEmpty
                ? text
                : attachment!.isImage
                ? '📷 Photo'
                : '📎 ${attachment.name}',
          ),
          'lastMessageSenderId': senderId,
          'lastMessageAt': FieldValue.serverTimestamp(),
          if (recipient != null)
            'unreadCount.$recipient': FieldValue.increment(1),
          'unreadCount.$senderId': 0,
        },
      );

      // Inbox notification; the backend pushes it to the recipient's devices.
      // Rules verify both users belong to this conversation before allowing
      // the write. The title is generic on purpose: it reaches a lock screen.

      if (recipient != null) {
        batch.set(
          _firestore.collection(FirestorePaths.notifications(recipient)).doc(),
          {
            'type': AppNotificationType.chatMessage.wireName,
            'title': 'New message',
            'body': '',
            'read': false,
            'conversationId': conversationId,
            'createdAt': FieldValue.serverTimestamp(),
            'expiresAt': Timestamp.fromDate(
              DateTime.now().add(NotificationRepository.retention),
            ),
          },
        );
      }
      await batch.commit();
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Derives the other participant from the deterministic conversation id
  /// (`uidA_uidB`, sorted) without spending a Firestore read per message.
  /// Returns null when the id does not follow that layout.
  static String? otherParticipantOf(String conversationId, String senderId) {
    final parts = conversationId.split('_');
    if (parts.length != 2 || !parts.contains(senderId)) return null;
    final other = parts.firstWhere((p) => p != senderId, orElse: () => '');
    return other.isEmpty ? null : other;
  }

  /// Resets this user's unread counter once the chat screen is open.
  Future<void> markConversationRead({
    required String conversationId,
    required String readerId,
  }) async {
    try {
      await _firestore
          .doc('${FirestorePaths.conversations}/$conversationId')
          .update({'unreadCount.$readerId': 0});
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  String _previewOf(String text) {
    final oneLine = text.replaceAll('\n', ' ');
    return oneLine.length <= 80 ? oneLine : '${oneLine.substring(0, 80)}…';
  }
}
