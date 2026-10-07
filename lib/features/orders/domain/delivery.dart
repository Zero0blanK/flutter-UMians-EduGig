import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/storage/attachment.dart';

/// A work delivery submitted by the freelancer: a note, plus up to
/// [maxAttachments] files uploaded to Cloud Storage.
class Delivery {
  const Delivery({
    required this.id,
    required this.senderId,
    required this.note,
    required this.createdAt,
    this.attachments = const [],
  });

  static const maxAttachments = 5;

  final String id;
  final String senderId;
  final String note;
  final DateTime createdAt;
  final List<Attachment> attachments;

  factory Delivery.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Delivery.fromMap(doc.id, data);
  }

  factory Delivery.fromMap(String id, Map<String, dynamic> data) {
    return Delivery(
      id: id,
      senderId: data['senderId'] as String,
      note: data['note'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      attachments: [
        for (final item in data['attachments'] as List<dynamic>? ?? const [])
          if (item is Map<String, dynamic> && Attachment.fromMap(item) != null)
            Attachment.fromMap(item)!,
      ],
    );
  }
}
