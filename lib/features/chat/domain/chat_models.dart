import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/storage/attachment.dart';

class Conversation {
  const Conversation({
    required this.id,
    required this.participantIds,
    required this.lastMessagePreview,
    required this.lastMessageSenderId,
    required this.lastMessageAt,
    required this.createdAt,
    this.unreadCount = const {},
  });

  final String id;
  final List<String> participantIds;
  final String lastMessagePreview;
  final String lastMessageSenderId;
  final DateTime? lastMessageAt;
  final DateTime createdAt;

  /// Per-participant unread counters, maintained server-adjacent by the
  /// sender's write and reset when the reader opens the conversation.
  final Map<String, int> unreadCount;

  int unreadFor(String uid) => unreadCount[uid] ?? 0;

  String otherParticipant(String myUid) =>
      participantIds.firstWhere((id) => id != myUid, orElse: () => myUid);

  factory Conversation.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return Conversation(
      id: doc.id,
      participantIds: List<String>.from(
        (data['participantIds'] as List<dynamic>?) ?? const [],
      ),
      lastMessagePreview: data['lastMessagePreview'] as String? ?? '',
      lastMessageSenderId: data['lastMessageSenderId'] as String? ?? '',
      lastMessageAt: (data['lastMessageAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      unreadCount: Map<String, int>.from(
        data['unreadCount'] as Map? ?? const {},
      ),
    );
  }
}

/// The listing that prompted a message, with its title retained for history.
class ChatServiceReference {
  const ChatServiceReference({required this.id, required this.title});

  final String id;
  final String title;
}

/// A chat message: text, an attachment, or both, with optional service context.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.sentAt,
    this.attachment,
    this.offerId,
    this.serviceReference,
  });

  final String id;
  final String senderId;
  final String text;
  final DateTime sentAt;
  final Attachment? attachment;

  /// An offer card. The message carries only the id; the card streams the
  /// offer document so its status is always current.
  final String? offerId;
  final ChatServiceReference? serviceReference;

  factory ChatMessage.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    final url = data['attachmentUrl'] as String?;
    return ChatMessage(
      id: doc.id,
      senderId: data['senderId'] as String,
      text: data['text'] as String? ?? '',
      sentAt: (data['sentAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      offerId: data['offerId'] as String?,
      serviceReference:
          data['serviceId'] is String && data['serviceTitle'] is String
          ? ChatServiceReference(
              id: data['serviceId'] as String,
              title: data['serviceTitle'] as String,
            )
          : null,
      attachment: url == null
          ? null
          : Attachment(
              url: url,
              name: data['attachmentName'] as String? ?? 'file',
              size: (data['attachmentSize'] as num?)?.toInt() ?? 0,
              isImage: data['attachmentType'] == 'image',
              type: data['attachmentType'] == 'video'
                  ? AttachmentType.video
                  : null,
            ),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'senderId': senderId,
    'text': text,
    'sentAt': FieldValue.serverTimestamp(),
    if (serviceReference != null) ...{
      'serviceId': serviceReference!.id,
      'serviceTitle': serviceReference!.title,
    },
    if (attachment != null) ...{
      'attachmentUrl': attachment!.url,
      'attachmentName': attachment!.name,
      'attachmentType': attachment!.type.name,
      'attachmentSize': attachment!.size,
    },
  };
}
