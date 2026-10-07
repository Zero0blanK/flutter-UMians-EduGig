import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:student_freelance_services/core/errors/app_failure.dart';
import 'package:student_freelance_services/core/storage/attachment.dart';
import 'package:student_freelance_services/core/storage/storage_repository.dart';
import 'package:student_freelance_services/features/auth/presentation/auth_controller.dart';
import 'package:student_freelance_services/features/chat/data/chat_repository.dart';
import 'package:student_freelance_services/features/chat/domain/chat_models.dart';
import 'package:student_freelance_services/features/chat/presentation/chat_screen.dart';

class _Auth extends ChangeNotifier implements AuthController {
  @override
  String get uid => 'alice';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage implements StorageRepository {
  List<PickedFile> selection = [];
  int uploads = 0;
  bool fail = false;
  @override
  Future<List<PickedFile>> pick({
    bool imagesOnly = false,
    bool multiple = false,
    required int limitBytes,
    bool forChat = false,
  }) async => selection;
  @override
  Future<Attachment> uploadChatAttachment({
    required String conversationId,
    required PickedFile file,
  }) async {
    uploads++;
    if (fail) throw const NetworkFailure();
    return Attachment(
      url: 'https://example.com/file',
      name: file.name,
      size: file.size,
      isImage: file.isImage,
      type: file.type,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Chat implements ChatRepository {
  int sends = 0;
  final serviceContexts = <String?>[];
  String? caption;
  Attachment? attachment;
  bool fail = false;
  Completer<void>? gate;
  List<ChatMessage>? previousMessages;
  Stream<List<ChatMessage>>? messageUpdates;
  @override
  List<ChatMessage>? cachedMessages(String conversationId) => previousMessages;
  @override
  Stream<List<ChatMessage>> watchMessages(
    String conversationId, {
    Object? startAfter,
  }) => messageUpdates ?? Stream.value([]);
  @override
  Future<Conversation?> fetchConversation(String conversationId) async => null;
  @override
  Future<void> markConversationRead({
    required String conversationId,
    required String readerId,
  }) async {}
  @override
  Future<void> sendAttachment({
    required String conversationId,
    required String senderId,
    required Attachment attachment,
    String caption = '',
    String? serviceId,
  }) async {
    sends++;
    serviceContexts.add(serviceId);
    this.caption = caption;
    this.attachment = attachment;
    if (fail) throw const NetworkFailure();
    await gate?.future;
  }

  @override
  Future<void> sendText({
    required String conversationId,
    required String senderId,
    required String rawText,
    String? serviceId,
  }) async {
    sends++;
    serviceContexts.add(serviceId);
    caption = rawText;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'chat size boundaries and video metadata preserve legacy attachments',
    () {
      for (final name in [
        'photo.png',
        'file.pdf',
        'clip.MP4',
        'clip.mov',
        'clip.m4v',
        'clip.webm',
      ]) {
        final type = PickedFile.typeOf(name);
        final limit = StorageRepository.chatLimitFor(type);
        expect(
          () => StorageRepository.validateChatFile(name, limit),
          returnsNormally,
        );
        expect(
          () => StorageRepository.validateChatFile(name, limit + 1),
          throwsA(isA<InvalidInputFailure>()),
        );
        expect(
          () => StorageRepository.validateChatFile(name, 0),
          throwsA(isA<InvalidInputFailure>()),
        );
      }
      final video = PickedFile(name: 'clip.MP4', bytes: Uint8List(1));
      expect(video.contentType, 'video/mp4');
      final attachment = Attachment(
        url: 'https://example.com/clip',
        name: video.name,
        size: 1,
        isImage: false,
        type: video.type,
      );
      expect(Attachment.fromMap(attachment.toMap())!.isVideo, isTrue);
      expect(
        Attachment.fromMap({'url': 'https://example.com/clip', 'type': 'file'})!
            .isVideo,
        isFalse,
      );
      expect(
        ChatMessage(
          id: '',
          senderId: 'alice',
          text: '',
          sentAt: DateTime(2026),
          attachment: attachment,
        ).toFirestore()['attachmentType'],
        'video',
      );
    },
  );

  late _Storage storage;
  late _Chat chat;

  Future<void> open(
    WidgetTester tester, {
    String? serviceId,
    List<ChatMessage>? cachedMessages,
    Stream<List<ChatMessage>>? messageUpdates,
  }) async {
    storage = _Storage();
    chat = _Chat()
      ..previousMessages = cachedMessages
      ..messageUpdates = messageUpdates;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthController>(create: (_) => _Auth()),
          Provider<StorageRepository>.value(value: storage),
          Provider<ChatRepository>.value(value: chat),
        ],
        child: MaterialApp(
          home: ChatScreen(conversationId: 'alice_bob', serviceId: serviceId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('cached messages render before the live stream responds', (
    tester,
  ) async {
    final updates = StreamController<List<ChatMessage>>();
    addTearDown(updates.close);
    final cached = ChatMessage(
      id: 'cached',
      senderId: 'alice',
      text: 'Already loaded message',
      sentAt: DateTime(2026),
    );
    await open(
      tester,
      cachedMessages: [cached],
      messageUpdates: updates.stream,
    );
    expect(find.text('Already loaded message'), findsOneWidget);
    updates.add([
      ChatMessage(
        id: 'live',
        senderId: 'alice',
        text: 'New live message',
        sentAt: DateTime(2026),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New live message'), findsOneWidget);
    expect(find.text('Already loaded message'), findsNothing);
  });

  Future<void> pick(WidgetTester tester, String? name) async {
    storage.selection = name == null
        ? []
        : [PickedFile(name: name, bytes: Uint8List(10))];
    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video or file'));
    await tester.pumpAndSettle();
  }

  for (final origin in [null, 'debug-code']) {
    testWidgets(
      'service context is sent once per service visit (origin=$origin)',
      (tester) async {
        await open(tester, serviceId: origin);
        expect(chat.sends, 0);
        await tester.enterText(find.byType(TextField), 'I am interested');
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'Can you help with Python?',
        );
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(chat.serviceContexts, [origin, null]);
      },
    );
  }

  testWidgets('failed first message retains service context for retry', (
    tester,
  ) async {
    await open(tester, serviceId: 'debug-code');
    await pick(tester, 'report.pdf');
    chat.fail = true;
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    chat.fail = false;
    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(chat.serviceContexts, ['debug-code', 'debug-code']);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('photo draft fits at width $width and sends only on request', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester);
      storage.selection = [
        PickedFile(
          name: 'photo.png',
          bytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
          ),
        ),
      ];
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(storage.uploads, 0);
      expect(chat.sends, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(chat.attachment!.isImage, isTrue);
      expect(chat.sends, 1);
    });
  }

  testWidgets('pick, cancel, replace and remove never upload or send', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'caption');
    await pick(tester, 'first.pdf');
    expect(find.text('first.pdf'), findsOneWidget);
    await pick(tester, null);
    expect(find.text('first.pdf'), findsOneWidget);
    await pick(tester, 'second.mp4');
    expect(find.text('first.pdf'), findsNothing);
    expect(find.text('second.mp4'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pumpAndSettle();
    expect(find.text('second.mp4'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'caption',
    );
    expect(storage.uploads, 0);
    expect(chat.sends, 0);
  });

  testWidgets(
    'caption and attachment send once, failure retains upload for retry',
    (tester) async {
      await open(tester);
      await pick(tester, 'clip.mp4');
      await tester.enterText(find.byType(TextField), 'Here is the clip');
      chat.fail = true;
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(storage.uploads, 1);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Here is the clip',
      );
      chat.fail = false;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      chat.gate = Completer<void>();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded),
            )
            .onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(storage.uploads, 1);
      expect(chat.sends, 2);
      expect(chat.caption, 'Here is the clip');
      expect(chat.attachment!.isVideo, isTrue);
      chat.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('clip.mp4'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'attachment without caption survives upload failure and retries',
    (tester) async {
      await open(tester);
      await pick(tester, 'report.pdf');
      storage.fail = true;
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(chat.sends, 0);
      expect(find.text('report.pdf'), findsOneWidget);
      storage.fail = false;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(chat.sends, 1);
      expect(chat.caption, '');
      expect(find.text('report.pdf'), findsNothing);
    },
  );
}
