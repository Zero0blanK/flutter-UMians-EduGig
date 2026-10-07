import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:student_freelance_services/core/errors/app_failure.dart';
import 'package:student_freelance_services/features/auth/domain/user_profile.dart';
import 'package:student_freelance_services/features/auth/presentation/auth_controller.dart';
import 'package:student_freelance_services/features/payments/data/payment_gateway.dart';
import 'package:student_freelance_services/features/payments/domain/payment.dart';
import 'package:student_freelance_services/features/pro/data/pro_repository.dart';
import 'package:student_freelance_services/features/pro/presentation/pro_card.dart';
import 'package:student_freelance_services/features/wallet/data/wallet_repository.dart';
import 'package:student_freelance_services/features/wallet/domain/wallet.dart';
import 'package:student_freelance_services/features/wallet/presentation/payout_account_screen.dart';

class _Auth extends Fake implements AuthController {
  @override
  String get uid => 'student';

  @override
  UserProfile? get profile => null;
}

class _Pro extends Fake implements ProRepository {
  final checkouts = <PaymentChannel>[];

  @override
  bool get isAvailable => true;

  @override
  Future<RedirectCheckout> startCheckout(PaymentChannel channel) async {
    checkouts.add(channel);
    // Stop before opening an external browser; this suite tests the setup gate.
    throw const NetworkFailure();
  }
}

class _Wallets extends Fake implements WalletRepository {
  _Wallets({this.account});
  PayoutAccount? account;
  bool failSave = false;

  @override
  Stream<Wallet> watchWallet(String uid) => Stream.value(
    Wallet(
      uid: uid,
      available: 0,
      pendingPayout: 0,
      totalReleased: 0,
      totalPaidOut: 0,
      payoutAccount: account,
    ),
  );

  @override
  Future<void> savePayoutAccount({
    required String uid,
    required PayoutAccount account,
  }) async {
    if (failSave) throw const NetworkFailure();
    this.account = account;
  }
}

Future<GoRouter> _pump(WidgetTester tester, _Wallets wallets, _Pro pro) async {
  await tester.binding.setSurfaceSize(const Size(430, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            const Scaffold(body: SingleChildScrollView(child: ProCard())),
      ),
      GoRoute(
        path: '/wallet/account',
        builder: (_, state) => PayoutAccountScreen(
          initialType: state.uri.queryParameters['type'],
          returnOnSave: state.uri.queryParameters['setup'] == 'pro',
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<AuthController>.value(value: _Auth()),
        Provider<ProRepository>.value(value: pro),
        Provider<WalletRepository>.value(value: wallets),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _choose(WidgetTester tester, PaymentChannel channel) async {
  await tester.tap(find.text('Get Pro for ₱99'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(channel.label));
  await tester.pumpAndSettle();
  await tester.tap(
    find.text(
      channel == PaymentChannel.other
          ? 'Continue to payment'
          : 'Continue with ${channel.label}',
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final channel in [PaymentChannel.gcash, PaymentChannel.maya]) {
    testWidgets('${channel.label} setup saves before starting Pro checkout', (
      tester,
    ) async {
      final wallets = _Wallets();
      final pro = _Pro();
      await _pump(tester, wallets, pro);
      await _choose(tester, channel);
      expect(find.text('Payout account'), findsOneWidget);
      expect(find.text(channel.label), findsOneWidget);
      expect(pro.checkouts, isEmpty);
      await tester.enterText(find.byType(TextField).at(0), 'Student Name');
      await tester.enterText(find.byType(TextField).at(1), '09123456789');
      await tester.tap(find.text('Save and continue to Pro'));
      await tester.pumpAndSettle();
      expect(wallets.account?.type, channel.wireName);
      expect(pro.checkouts, [channel]);
      expect(find.text('Payout account'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a complete matching account proceeds without setup', (
    tester,
  ) async {
    final pro = _Pro();
    await _pump(
      tester,
      _Wallets(
        account: const PayoutAccount(
          type: 'gcash',
          accountName: 'Student',
          accountNumber: '09123456789',
        ),
      ),
      pro,
    );
    await _choose(tester, PaymentChannel.gcash);
    expect(find.text('Payout account'), findsNothing);
    expect(pro.checkouts, [PaymentChannel.gcash]);
  });

  testWidgets(
    'a different saved method opens setup and cancellation stops checkout',
    (tester) async {
      final pro = _Pro();
      final router = await _pump(
        tester,
        _Wallets(
          account: const PayoutAccount(
            type: 'gcash',
            accountName: 'Student',
            accountNumber: '09123456789',
          ),
        ),
        pro,
      );
      await _choose(tester, PaymentChannel.maya);
      expect(find.text('Payout account'), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(pro.checkouts, isEmpty);
    },
  );

  testWidgets('an incomplete account and failed save cannot start checkout', (
    tester,
  ) async {
    final pro = _Pro();
    final wallets = _Wallets(
      account: const PayoutAccount(
        type: 'gcash',
        accountName: '',
        accountNumber: '09123456789',
      ),
    )..failSave = true;
    await _pump(tester, wallets, pro);
    await _choose(tester, PaymentChannel.gcash);
    await tester.enterText(find.byType(TextField).at(0), 'Student Name');
    await tester.tap(find.text('Save and continue to Pro'));
    await tester.pumpAndSettle();
    expect(find.text('Payout account'), findsOneWidget);
    expect(pro.checkouts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card checkout uses the gateway form directly', (tester) async {
    final pro = _Pro();
    await _pump(tester, _Wallets(), pro);
    await _choose(tester, PaymentChannel.card);
    expect(find.text('Payout account'), findsNothing);
    expect(pro.checkouts, [PaymentChannel.card]);
  });
}
