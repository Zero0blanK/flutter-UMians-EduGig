enum AttachmentType { image, video, file }

/// A file that lives in Cloud Storage and is referenced from a Firestore
/// document — a chat attachment or a delivered piece of work.
///
/// Only the download URL and enough metadata to render a chip are stored on
/// the document. The bytes never touch Firestore, so a message with a photo
/// costs the same read as a message without one.
class Attachment {
  const Attachment({
    required this.url,
    required this.name,
    required this.size,
    required bool isImage,
    AttachmentType? type,
  }) : type = type ?? (isImage ? AttachmentType.image : AttachmentType.file);

  final String url;

  /// Original file name, shown on the chip and used as the download name.
  final String name;

  /// Bytes, for the "2.3 MB" label.
  final int size;

  /// Existing image/file records remain compatible with video-aware chat.
  final AttachmentType type;
  bool get isImage => type == AttachmentType.image;
  bool get isVideo => type == AttachmentType.video;

  /// "2.3 MB", "540 KB". Rounded because nobody needs the byte count.
  String get sizeLabel {
    if (size >= 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (size >= 1024) return '${(size / 1024).round()} KB';
    return '$size B';
  }

  Map<String, dynamic> toMap() => {
    'url': url,
    'name': name,
    'size': size,
    'type': type.name,
  };

  static Attachment? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final url = data['url'] as String?;
    if (url == null || url.isEmpty) return null;
    return Attachment(
      url: url,
      name: data['name'] as String? ?? 'file',
      size: (data['size'] as num?)?.toInt() ?? 0,
      isImage: data['type'] == 'image',
      type: data['type'] == 'video' ? AttachmentType.video : null,
    );
  }
}
