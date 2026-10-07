import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Keeps compressed pictures across route changes without retaining every
/// full-resolution decoded image in Flutter's image cache.
class AttachmentImageCache {
  AttachmentImageCache({
    http.Client? client,
    this.maxBytes = 32 * 1024 * 1024,
    this.maxEntries = 100,
  }) : _client = client ?? http.Client(),
       assert(maxBytes > 0),
       assert(maxEntries > 0);

  static final shared = AttachmentImageCache();

  final http.Client _client;
  final int maxBytes;
  final int maxEntries;
  final _images = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  int _byteCount = 0;
  int _generation = 0;

  Uint8List? cached(String url) {
    final bytes = _images.remove(url);
    if (bytes != null) _images[url] = bytes;
    return bytes;
  }

  Future<Uint8List> load(String url) async {
    final bytes = cached(url);
    if (bytes != null) return bytes;
    final request = _pending.putIfAbsent(
      url,
      () => _download(url, _generation),
    );
    try {
      return await request;
    } finally {
      if (identical(_pending[url], request)) _pending.remove(url);
    }
  }

  Future<Uint8List> _download(String url, int generation) async {
    final response = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw const FormatException('Could not load this picture.');
    }
    final bytes = response.bodyBytes;
    if (generation == _generation && bytes.lengthInBytes <= maxBytes) {
      while (_images.isNotEmpty &&
          (_byteCount + bytes.lengthInBytes > maxBytes ||
              _images.length >= maxEntries)) {
        _byteCount -= _images.remove(_images.keys.first)!.lengthInBytes;
      }
      _images[url] = bytes;
      _byteCount += bytes.lengthInBytes;
    }
    return bytes;
  }

  void clear() {
    _generation++;
    _images.clear();
    _pending.clear();
    _byteCount = 0;
  }

  void remove(String url) {
    final bytes = _images.remove(url);
    if (bytes != null) _byteCount -= bytes.lengthInBytes;
  }
}
