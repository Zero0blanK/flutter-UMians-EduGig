import '../../chat/domain/chat_models.dart';
import '../../../core/storage/attachment.dart';

class DisputeChatPage {
  const DisputeChatPage({
    required this.capturedAt,
    required this.messages,
    required this.nextCursor,
  });
  final DateTime capturedAt;
  final List<ChatMessage> messages;
  final String? nextCursor;

  factory DisputeChatPage.fromJson(Map<String, dynamic> json) =>
      DisputeChatPage(
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        nextCursor: json['nextCursor'] as String?,
        messages: [
          for (final entry in json['messages'] as List<dynamic>)
            if (entry is Map<String, dynamic>)
              ChatMessage(
                id: entry['id'] as String,
                senderId: entry['senderId'] as String,
                text: entry['text'] as String? ?? '',
                sentAt: DateTime.parse(entry['sentAt'] as String),
                offerId: entry['offerId'] as String?,
                serviceReference:
                    entry['serviceId'] is String &&
                        entry['serviceTitle'] is String
                    ? ChatServiceReference(
                        id: entry['serviceId'] as String,
                        title: entry['serviceTitle'] as String,
                      )
                    : null,
                attachment: Attachment.fromMap(
                  (entry['attachment'] as Map?)?.cast<String, dynamic>(),
                ),
              ),
        ],
      );
}
