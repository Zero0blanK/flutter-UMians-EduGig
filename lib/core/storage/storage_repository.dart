import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../errors/app_failure.dart';
import 'attachment.dart';

/// A file the user picked, with its bytes already in memory.
///
/// Read only after the picker reports an acceptable size, including on web.
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;

  int get size => bytes.length;

  static AttachmentType typeOf(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}.contains(ext)) {
      return AttachmentType.image;
    }
    if (const {'mp4', 'mov', 'm4v', 'webm'}.contains(ext)) {
      return AttachmentType.video;
    }
    return AttachmentType.file;
  }

  AttachmentType get type => typeOf(name);

  bool get isImage {
    return type == AttachmentType.image;
  }

  String get contentType {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      'txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }
}

/// Uploads to Cloud Storage. The only class that imports `firebase_storage`.
///
/// Paths mirror `storage.rules`: a file lives under the conversation, order,
/// or user it belongs to, so the path itself carries the authorisation
/// question. Sizes are checked here for a fast, friendly error; the rules
/// check them again because a client-side limit is not a limit.
class StorageRepository {
  StorageRepository(this._storage);

  final FirebaseStorage _storage;

  static const chatLimitBytes = 10 * 1024 * 1024;
  static const chatVideoLimitBytes = 25 * 1024 * 1024;

  static int chatLimitFor(AttachmentType type) =>
      type == AttachmentType.video ? chatVideoLimitBytes : chatLimitBytes;

  static void validateChatFile(String name, int size) {
    final limit = chatLimitFor(PickedFile.typeOf(name));
    if (size <= 0) {
      throw const InvalidInputFailure('The selected file is empty.');
    }
    if (size > limit) {
      throw InvalidInputFailure(
        '$name exceeds the ${limit ~/ (1024 * 1024)} MB limit. '
        'For larger files, paste a Google Drive, OneDrive, or Dropbox '
        'HTTPS link and give the recipient access.',
      );
    }
  }

  static const deliveryLimitBytes = 25 * 1024 * 1024;
  static const idLimitBytes = 5 * 1024 * 1024;

  /// Opens the platform picker. Empty when the user cancelled.
  ///
  /// The size check runs before the bytes are read, so a 2 GB video is
  /// refused without loading it into memory first.
  Future<List<PickedFile>> pick({
    bool imagesOnly = false,
    bool multiple = false,
    required int limitBytes,
    bool forChat = false,
  }) async {
    final type = imagesOnly ? FileType.image : FileType.any;
    final picked = multiple
        ? await FilePicker.pickFiles(type: type)
        : [?await FilePicker.pickFile(type: type)];
    final files = <PickedFile>[];
    for (final file in picked) {
      final length = file.lengthSync() ?? await file.length();
      if (forChat) validateChatFile(file.name, length);
      if (length > limitBytes) {
        throw InvalidInputFailure(
          '${file.name} is too large. Files are limited to '
          '${limitBytes ~/ (1024 * 1024)} MB.',
        );
      }
      files.add(PickedFile(name: file.name, bytes: await file.readAsBytes()));
    }
    return files;
  }

  Future<Attachment> uploadChatAttachment({
    required String conversationId,
    required PickedFile file,
  }) {
    validateChatFile(file.name, file.size);
    return _upload('conversations/$conversationId', file, chat: true);
  }

  Future<Attachment> uploadDelivery({
    required String orderId,
    required PickedFile file,
  }) => _upload('orders/$orderId/deliveries', file);

  /// Returns the storage *path* rather than a URL: the ID is read only by
  /// staff, through a rule-checked download, never from a public link.
  Future<String> uploadVerificationId({
    required String uid,
    required PickedFile file,
  }) async {
    final path = 'verification/$uid/${_uniqueName(file.name)}';
    try {
      await _storage
          .ref(path)
          .putData(file.bytes, SettableMetadata(contentType: file.contentType));
      return path;
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Download URL for a path the caller is entitled to (rules decide).
  Future<String> downloadUrl(String path) async {
    try {
      return await _storage.ref(path).getDownloadURL();
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<Attachment> _upload(
    String folder,
    PickedFile file, {
    bool chat = false,
  }) async {
    final ref = _storage.ref('$folder/${_uniqueName(file.name)}');
    try {
      await ref.putData(
        file.bytes,
        SettableMetadata(contentType: file.contentType),
      );
      final url = await ref.getDownloadURL();
      return Attachment(
        url: url,
        name: file.name,
        size: file.size,
        isImage: file.isImage,
        type: chat ? file.type : null,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Prefixes a timestamp so two "poster.png" uploads never collide, and
  /// strips anything a file name should not carry into a URL.
  static String _uniqueName(String original) {
    final safe = original.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final trimmed = safe.length > 80 ? safe.substring(safe.length - 80) : safe;
    return '${DateTime.now().millisecondsSinceEpoch}_$trimmed';
  }
}
