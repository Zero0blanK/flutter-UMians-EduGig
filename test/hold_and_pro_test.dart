import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_freelance_services/features/auth/domain/user_profile.dart';
import 'package:student_freelance_services/features/notifications/domain/app_notification.dart';
import 'package:student_freelance_services/features/notifications/notification_router.dart';
import 'package:student_freelance_services/features/orders/domain/order.dart';
import 'package:student_freelance_services/features/payments/domain/payment.dart';
import 'package:student_freelance_services/features/pro/domain/pro_policy.dart';
import 'package:student_freelance_services/features/wallet/domain/wallet.dart';
import 'package:student_freelance_services/core/storage/attachment.dart';

WorkOrder _order(OrderStatus status, {DateTime? updatedAt}) => WorkOrder(
  id: 'o1',
  serviceId: 's1',
  serviceTitle: 'Poster',
  clientId: 'buyer',
  freelancerId: 'seller',
  price: 500,
  currency: 'PHP',
  deliveryDays: 3,
  revisionCount: 1,
  requirements: 'An A3 poster for the org fair.',
  status: status,
  createdAt: DateTime(2026, 6, 1),
  updatedAt: updatedAt ?? DateTime(2026, 6, 10, 9),
);

UserProfile _profile({DateTime? proUntil, bool verified = false}) =>
    UserProfile(
      uid: 'u1',
      displayName: 'Maya',
      bio: '',
      skills: const [],
      createdAt: DateTime(2026),
      proUntil: proUntil,
      identityVerified: verified,
    );

void main() {
  group('auto-completion window', () {
    test('a submitted order names the moment it completes on its own', () {
      final order = _order(OrderStatus.submitted);
      expect(order.autoCompletesAt, DateTime(2026, 6, 13, 9));
      expect(kAutoCompleteAfter, const Duration(days: 3));
    });

    test('no other state has a deadline for the client', () {
      for (final status in OrderStatus.values) {
        if (status == OrderStatus.submitted) continue;
        expect(_order(status).autoCompletesAt, isNull, reason: '$status');
      }
    });
  });

  group('hold status', () {
    test('unknown wire values never read as released', () {
      expect(HoldStatus.fromName('released'), HoldStatus.released);
      expect(HoldStatus.fromName('nonsense'), isNull);
      expect(HoldStatus.fromName(null), isNull);
    });
  });

  group('verified badge', () {
    final future = DateTime.now().add(const Duration(days: 10));
    final past = DateTime.now().subtract(const Duration(days: 1));

    test('needs both a staff check and an active subscription', () {
      expect(
        _profile(proUntil: future, verified: true).hasVerifiedBadge,
        isTrue,
      );
    });

    test('is never shown for payment alone', () {
      // A badge that merely meant "paid ₱99" would be the fake trust signal
      // the platform exists to replace.
      expect(_profile(proUntil: future).hasVerifiedBadge, isFalse);
    });

    test('lapses with the subscription but the check itself is kept', () {
      final lapsed = _profile(proUntil: past, verified: true);
      expect(lapsed.hasVerifiedBadge, isFalse);
      expect(lapsed.identityVerified, isTrue);
      expect(lapsed.isPro, isFalse);
    });
  });

  group('Pro policy', () {
    test('never discounts the commission and caps featured listings', () {
      expect(ProPolicy.price, 99);
      expect(ProPolicy.featuredPerSeller, 2);
      expect(ProPolicy.featuredPerPage, 3);
    });
  });

  group('wallet', () {
    const account = PayoutAccount(
      type: 'gcash',
      accountName: 'Maya R',
      accountNumber: '09171234567',
    );

    test('a payout needs an account, a clear balance, and nothing pending', () {
      Wallet wallet({int available = 0, int pending = 0, PayoutAccount? acc}) =>
          Wallet(
            uid: 'u1',
            available: available,
            pendingPayout: pending,
            totalReleased: 0,
            totalPaidOut: 0,
            payoutAccount: acc,
          );
      expect(wallet(available: 300, acc: account).canRequestPayout, isTrue);
      expect(wallet(available: 299, acc: account).canRequestPayout, isFalse);
      expect(wallet(available: 900).canRequestPayout, isFalse);
      expect(
        wallet(available: 900, pending: 100, acc: account).canRequestPayout,
        isFalse,
      );
    });

    test('payout account types are a closed set', () {
      expect(PayoutAccount.fromMap({'type': 'paypal'}), isNull);
      expect(PayoutAccount.fromMap(account.toMap())?.typeLabel, 'GCash');
    });

    test('a bank account needs a supported bank before it can be paid to', () {
      const noBank = PayoutAccount(
        type: 'bank',
        accountName: 'Maya R',
        accountNumber: '123456789012',
      );
      const bdo = PayoutAccount(
        type: 'bank',
        accountName: 'Maya R',
        accountNumber: '123456789012',
        bankCode: 'PH_BDO',
      );
      const unknown = PayoutAccount(
        type: 'bank',
        accountName: 'Maya R',
        accountNumber: '123456789012',
        bankCode: 'PH_NOPE',
      );
      expect(noBank.isComplete, isFalse);
      expect(unknown.isComplete, isFalse);
      expect(bdo.isComplete, isTrue);
      expect(bdo.typeLabel, 'BDO');
      expect(bdo.toMap()['bankCode'], 'PH_BDO');
      expect(account.toMap().containsKey('bankCode'), isFalse);

      Wallet wallet(PayoutAccount acc) => Wallet(
        uid: 'u1',
        available: 900,
        pendingPayout: 0,
        totalReleased: 0,
        totalPaidOut: 0,
        payoutAccount: acc,
      );
      expect(wallet(noBank).canRequestPayout, isFalse);
      expect(wallet(bdo).canRequestPayout, isTrue);
    });

    test('payout statuses: open ones wait, closed ones are final', () {
      expect(PayoutStatus.requested.isOpen, isTrue);
      expect(PayoutStatus.processing.isOpen, isTrue);
      expect(PayoutStatus.paid.isOpen, isFalse);
      expect(PayoutStatus.failed.isOpen, isFalse);
      expect(PayoutStatus.fromName('nonsense'), PayoutStatus.requested);
    });
  });

  group('attachments', () {
    test('sizes read like a human wrote them', () {
      Attachment of(int size) =>
          Attachment(url: 'https://x', name: 'f', size: size, isImage: false);
      expect(of(512).sizeLabel, '512 B');
      expect(of(540 * 1024).sizeLabel, '540 KB');
      expect(of((2.3 * 1024 * 1024).round()).sizeLabel, '2.3 MB');
    });

    test('a map without a url is not an attachment', () {
      expect(Attachment.fromMap({'name': 'x'}), isNull);
      expect(Attachment.fromMap(null), isNull);
    });
  });

  group('age gate', () {
    UserProfile born(DateTime? date) => UserProfile(
      uid: 'u',
      displayName: 'x',
      bio: '',
      skills: const [],
      createdAt: DateTime(2026),
      birthDate: date,
    );

    test('eighteen by the day, never by default', () {
      final now = DateTime.now();
      final eighteenToday = DateTime(now.year - 18, now.month, now.day);
      expect(born(eighteenToday).isAdult, isTrue);
      expect(born(eighteenToday.add(const Duration(days: 1))).isAdult, isFalse);
      expect(born(null).isAdult, isFalse, reason: 'no date is not an adult');
    });

    test('an existing birth date is never overwritten by an edit', () {
      // Mirrors AuthController.updateProfile: current wins over argument.
      final current = born(DateTime(2000, 1, 1));
      final argument = DateTime(2010, 1, 1);
      expect(current.birthDate ?? argument, DateTime(2000, 1, 1));
    });
  });

  group('payout account numbers', () {
    test('must look like the thing they claim to be', () {
      expect(WalletPolicy.validAccountNumber('gcash', '09171234567'), isTrue);
      expect(WalletPolicy.validAccountNumber('maya', '09171234567'), isTrue);
      expect(WalletPolicy.validAccountNumber('gcash', '0917123456'), isFalse);
      expect(WalletPolicy.validAccountNumber('gcash', '08171234567'), isFalse);
      expect(WalletPolicy.validAccountNumber('bank', '1234567890'), isTrue);
      expect(WalletPolicy.validAccountNumber('bank', '12345'), isFalse);
      expect(WalletPolicy.validAccountNumber('paypal', '09171234567'), isFalse);
    });
  });

  group('wallet clearance', () {
    test('a new seller is one with fewer than three releases', () {
      Wallet w(int count) => Wallet(
        uid: 'u',
        available: 0,
        pendingPayout: 0,
        totalReleased: 0,
        totalPaidOut: 0,
        releaseCount: count,
      );
      expect(w(0).isNewSeller, isTrue);
      expect(w(2).isNewSeller, isTrue);
      expect(w(3).isNewSeller, isFalse);
      expect(WalletPolicy.newSellerClearanceDays, 7);
    });
  });

  group('server-written notification types', () {
    Widget host() => MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Scaffold()),
          GoRoute(
            path: '/order/:id',
            builder: (_, state) => Text('order:${state.pathParameters['id']}'),
          ),
          GoRoute(path: '/profile', builder: (_, _) => const Text('profile')),
          GoRoute(
            path: '/notifications',
            builder: (_, _) => const Text('notifications'),
          ),
        ],
      ),
    );

    test('every new wire name parses', () {
      for (final name in [
        'payment.released',
        'payment.refunded',
        'payout.paid',
        'payout.rejected',
        'pro.activated',
        'verification.approved',
        'verification.rejected',
        'order.auto_complete_reminder',
        'admin.refund_attention',
        'admin.payout_requested',
        'admin.verification_pending',
      ]) {
        expect(AppNotificationType.fromWire(name), isNotNull, reason: name);
      }
    });

    testWidgets(
      'money events open the order; account events open the profile',
      (tester) async {
        await tester.pumpWidget(host());
        NotificationRouter(tester.element(find.byType(Scaffold).first))
            .routeFromData({'type': 'payment.released', 'orderId': 'o1'});
        await tester.pumpAndSettle();
        expect(find.text('order:o1'), findsOneWidget);

        await tester.pumpWidget(host());
        NotificationRouter(tester.element(find.byType(Scaffold).first))
            .routeFromData({'type': 'payout.paid'});
        await tester.pumpAndSettle();
        expect(find.text('profile'), findsOneWidget);
      },
    );

    testWidgets('a push payload routes through the same table', (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Scaffold()),
          GoRoute(path: '/profile', builder: (_, _) => const Text('profile')),
          GoRoute(
            path: '/notifications',
            builder: (_, _) => const Text('notifications'),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      NotificationRouter.withRouter(router)
          .routeFromData({'type': 'verification.approved'});
      await tester.pumpAndSettle();
      expect(find.text('profile'), findsOneWidget);

      NotificationRouter.withRouter(router).routeFromData({'type': 'bogus'});
      await tester.pumpAndSettle();
      expect(find.text('notifications'), findsOneWidget);
    });
  });
}
