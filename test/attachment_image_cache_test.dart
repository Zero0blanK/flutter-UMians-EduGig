import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_freelance_services/core/storage/attachment_image_cache.dart';

void main() {
  test('reuses image bytes and shares concurrent downloads', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    final cache = AttachmentImageCache(
      client: MockClient((request) {
        requests++;
        return response.future;
      }),
    );
    final first = cache.load('https://example.com/photo.png');
    final preview = cache.load('https://example.com/photo.png');
    response.complete(http.Response.bytes([1, 2, 3], 200));
    final bytes = await first;
    expect(await preview, same(bytes));
    expect(await cache.load('https://example.com/photo.png'), same(bytes));
    expect(requests, 1);
  });

  test(
    'evicts least recently used bytes when the budget is exceeded',
    () async {
      final cache = AttachmentImageCache(
        maxBytes: 6,
        client: MockClient(
          (request) async => http.Response.bytes([1, 2, 3], 200),
        ),
      );
      await cache.load('https://example.com/a');
      await cache.load('https://example.com/b');
      cache.cached('https://example.com/a');
      await cache.load('https://example.com/c');
      expect(cache.cached('https://example.com/b'), isNull);
      expect(cache.cached('https://example.com/a'), isNotNull);
      expect(cache.cached('https://example.com/c'), isNotNull);
    },
  );

  test('failed downloads are retried instead of cached', () async {
    var requests = 0;
    final cache = AttachmentImageCache(
      client: MockClient((request) async {
        requests++;
        return requests == 1
            ? http.Response('', 503)
            : http.Response.bytes([1], 200);
      }),
    );
    await expectLater(
      cache.load('https://example.com/photo.png'),
      throwsFormatException,
    );
    expect(await cache.load('https://example.com/photo.png'), [1]);
    expect(requests, 2);
  });

  test(
    'clearing the session prevents pending downloads repopulating it',
    () async {
      final response = Completer<http.Response>();
      final cache = AttachmentImageCache(
        client: MockClient((request) => response.future),
      );
      final pending = cache.load('https://example.com/photo.png');
      cache.clear();
      response.complete(http.Response.bytes([1], 200));
      await pending;
      expect(cache.cached('https://example.com/photo.png'), isNull);
    },
  );
}
