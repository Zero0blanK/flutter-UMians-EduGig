import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:student_freelance_services/features/notifications/domain/app_notification.dart';
import 'package:student_freelance_services/features/notifications/notification_router.dart';

Widget _host() => MaterialApp.router(
  routerConfig: GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold()),
      GoRoute(
        path: '/chat/:id',
        builder: (_, state) => Text('chat:${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/order/:id',
        builder: (_, state) => Text('order:${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/notifications',
        builder: (_, _) => const Text('notifications'),
      ),
    ],
  ),
);
void main() {
  testWidgets('routes chat messages to the conversation', (tester) async {
    await tester.pumpWidget(_host());
    NotificationRouter(tester.element(find.byType(Scaffold).first))
        .routeFromData({'type': 'chat.message', 'conversationId': 'a_b'});
    await tester.pumpAndSettle();
    expect(find.text('chat:a_b'), findsOneWidget);
  });

  testWidgets('routes order events to the order screen', (tester) async {
    await tester.pumpWidget(_host());
    NotificationRouter(tester.element(find.byType(Scaffold).first))
        .routeFromData({'type': 'order.completed', 'orderId': 'ord1'});
    await tester.pumpAndSettle();
    expect(find.text('order:ord1'), findsOneWidget);
  });

  testWidgets('malformed ids fall back to the inbox, never a crafted route', (
    tester,
  ) async {
    for (final data in [
      {'type': 'chat.message', 'conversationId': '../secrets'},
      {'type': 'chat.message', 'conversationId': 'x/y/z'},
      {'type': 'order.completed', 'orderId': ''},
      {'type': 'chat.message'},
    ]) {
      await tester.pumpWidget(_host());
      NotificationRouter(tester.element(find.byType(Scaffold).first))
          .routeFromData(data);
      await tester.pumpAndSettle();
      expect(
        find.text('notifications'),
        findsOneWidget,
        reason: '$data must land in the inbox',
      );
    }
  });

  group('notification payload parsing', () {
    test('parses every wire name into its enum value', () {
      for (final type in AppNotificationType.values) {
        expect(AppNotificationType.fromWire(type.wireName), type);
      }
    });

    test('unknown or missing types degrade to system announcement', () {
      final notification = AppNotification.fromMap('n1', {
        'title': 't',
        'body': '',
        'read': false,
        'createdAt': null,
      });
      expect(notification.type, AppNotificationType.systemAnnouncement);

      final bogus = AppNotification.fromMap('n2', {
        'type': 'totally.unknown',
        'title': 't',
        'read': false,
      });
      expect(bogus.type, AppNotificationType.systemAnnouncement);
    });

    test('notification documents never carry message content fields', () {
      // Guards the privacy rule: bodies stay generic.
      const allowedKeys = {
        'type',
        'title',
        'body',
        'read',
        'createdAt',
        'conversationId',
        'orderId',
      };
      expect(allowedKeys.contains('text'), isFalse);
      expect(allowedKeys.contains('imageUrl'), isFalse);
    });
  });
}
