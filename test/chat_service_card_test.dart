import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_freelance_services/features/chat/domain/chat_models.dart';
import 'package:student_freelance_services/features/chat/presentation/chat_service_card.dart';

void main() {
  for (final foreground in [Colors.white, Colors.black]) {
    testWidgets('service card opens the listing with foreground $foreground', (
      tester,
    ) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: ChatServiceCard(
                reference: const ChatServiceReference(
                  id: 'debug-code',
                  title: 'Debug my code',
                ),
                foreground: foreground,
              ),
            ),
          ),
          GoRoute(
            path: '/service/:id',
            builder: (_, state) => Scaffold(
              body: Text('Service detail: ${state.pathParameters['id']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Debug my code'));
      await tester.pumpAndSettle();
      expect(find.text('Service detail: debug-code'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'plain messages omit service metadata while contextual messages retain it',
    () {
      ChatMessage message([ChatServiceReference? reference]) => ChatMessage(
        id: 'message',
        senderId: 'buyer',
        text: 'I am interested',
        sentAt: DateTime(2026),
        serviceReference: reference,
      );
      expect(message().toFirestore().containsKey('serviceId'), isFalse);
      final saved = message(
        const ChatServiceReference(id: 'debug-code', title: 'Debug my code'),
      ).toFirestore();
      expect(saved['serviceId'], 'debug-code');
      expect(saved['serviceTitle'], 'Debug my code');
      expect(saved['text'], 'I am interested');
    },
  );
}
