import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:student_freelance_services/core/storage/attachment.dart';
import 'package:student_freelance_services/core/storage/video_attachment_view.dart';
import 'package:student_freelance_services/features/chat/presentation/chat_message_text.dart';

class _Player extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>.broadcast();
  int creates = 0;
  int plays = 0;
  int pauses = 0;
  int disposes = 0;
  Duration position = Duration.zero;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    creates++;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposes++;
  }

  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauses++;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => position;
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

void main() {
  testWidgets('HTTPS links retain their text and launch without punctuation', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    String? opened;
    var success = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      opened = (call.arguments as Map)['url'] as String?;
      return success;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    const text =
        'File (https://drive.google.com/file/d/example/view). '
        'javascript:https://bad.example http://plain.example https://user@bad.example';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ChatMessageText(text))),
    );
    final span = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!;
    expect(span.toPlainText(), text);
    final links = span.children!
        .cast<TextSpan>()
        .where((span) => span.recognizer != null)
        .toList();
    expect(links, hasLength(1));
    (links.single.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
    expect(opened, 'https://drive.google.com/file/d/example/view');
    success = false;
    (links.single.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
    expect(
      find.text('Could not open this link. Copy it into your browser.'),
      findsOneWidget,
    );
  });

  const attachment = Attachment(
    url: 'https://example.com/clip.mp4',
    name: 'clip.mp4',
    size: 100,
    isImage: false,
    type: AttachmentType.video,
  );

  testWidgets(
    'video loads on demand, plays, seeks, pauses on navigation and disposes',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _Player();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() async {
        VideoPlayerPlatform.instance = previous;
        await platform.events.close();
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: VideoAttachmentView(attachment: attachment, onOpen: () {}),
          ),
        ),
      );
      expect(platform.creates, 0);
      await tester.tap(find.byTooltip('Load video'));
      await tester.pump();
      expect(platform.creates, 1);
      platform.events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 20),
          size: const Size(640, 360),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      expect(platform.plays, 1);
      await tester.tap(find.byType(VideoProgressIndicator));
      await tester.pump();
      expect(platform.position.inSeconds, closeTo(10, 1));
      final pauses = platform.pauses;
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Next')),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.pauses, greaterThan(pauses));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      expect(platform.disposes, 1);
    },
  );

  testWidgets('desktop opens externally without initializing the player', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoAttachmentView(
            attachment: attachment,
            onOpen: () {
              opened = true;
            },
          ),
        ),
      ),
    );
    expect(find.byTooltip('Load video'), findsNothing);
    await tester.tap(find.text('Open video externally'));
    expect(opened, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('video errors offer external playback', (tester) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _Player();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() async {
      VideoPlayerPlatform.instance = previous;
      await platform.events.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoAttachmentView(attachment: attachment, onOpen: () {}),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Load video'));
    await tester.pump();
    platform.events.addError(
      PlatformException(
        code: 'unsupported-codec',
        message: 'Unsupported codec',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open video externally'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
