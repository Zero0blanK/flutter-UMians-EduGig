import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:student_freelance_services/features/admin/data/admin_repository.dart';
import 'package:student_freelance_services/features/admin/domain/admin_access.dart';
import 'package:student_freelance_services/features/auth/presentation/auth_controller.dart';
import 'package:student_freelance_services/features/chat/data/chat_repository.dart';
import 'package:student_freelance_services/features/orders/data/order_repository.dart';
import 'package:student_freelance_services/features/orders/domain/delivery.dart';
import 'package:student_freelance_services/features/orders/domain/order.dart';
import 'package:student_freelance_services/features/orders/presentation/order_detail_screen.dart';
import 'package:student_freelance_services/features/payments/data/payment_repository.dart';
import 'package:student_freelance_services/features/payments/domain/commission.dart';
import 'package:student_freelance_services/features/payments/domain/payment.dart';
import 'package:student_freelance_services/features/payments/payment_config.dart';

class _Auth extends ChangeNotifier implements AuthController {
  @override
  String get uid => 'buyer';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Orders extends Fake implements OrderRepository {
  final events = StreamController<WorkOrder>.broadcast();

  @override
  Stream<WorkOrder> watchById(String orderId) => events.stream;

  @override
  Stream<List<Delivery>> watchDeliveries(String orderId) => Stream.value([]);
}

class _Payments extends Fake implements PaymentRepository {
  final events = StreamController<Payment?>.broadcast();

  @override
  Stream<Payment?> watchForOrder(String orderId) => events.stream;

  @override
  PaymentConfig get config => const PaymentConfig(backendUrl: '');

  @override
  CommissionBreakdown breakdownFor(WorkOrder order) =>
      config.commissionPolicy.breakdownOf(order.price);
}

class _Admin extends Fake implements AdminRepository {
  @override
  Future<AdminAccess?> access(String uid) async => null;
}

class _Chat extends Fake implements ChatRepository {
  @override
  Future<PeerSummary> summaryOf(String uid) async =>
      PeerSummary(name: uid, verified: false);

  @override
  Future<String> displayNameOf(String uid) async => uid;
}

final _order = WorkOrder(
  id: 'order1',
  serviceId: 'service1',
  serviceTitle: 'Slide deck redesign',
  clientId: 'buyer',
  freelancerId: 'seller',
  price: 500,
  currency: 'PHP',
  deliveryDays: 3,
  revisionCount: 1,
  requirements: 'Redesign the presentation slides.',
  status: OrderStatus.accepted,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

final _paid = Payment(
  orderId: 'order1',
  clientId: 'buyer',
  freelancerId: 'seller',
  amount: 500,
  currency: 'PHP',
  commission: 25,
  netToFreelancer: 475,
  status: PaymentStatus.paid,
  method: PaymentMethod.manual,
  verified: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<void> _pumpScreen(
  WidgetTester tester,
  _Orders orders,
  _Payments payments,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(orders.events.close);
  addTearDown(payments.events.close);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>(create: (_) => _Auth()),
        Provider<OrderRepository>.value(value: orders),
        Provider<PaymentRepository>.value(value: payments),
        Provider<AdminRepository>.value(value: _Admin()),
        Provider<ChatRepository>.value(value: _Chat()),
      ],
      child: const MaterialApp(home: OrderDetailScreen(orderId: 'order1')),
    ),
  );
}

void main() {
  testWidgets('paid snapshot before the order loads reaches the payment UI', (
    tester,
  ) async {
    final orders = _Orders();
    final payments = _Payments();
    await _pumpScreen(tester, orders, payments);
    payments.events.add(_paid);
    await tester.pump();
    orders.events.add(_order);
    await tester.pumpAndSettle();

    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('Checking payment status…'), findsNothing);
    expect(find.text('Pay ₱500'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing payment snapshot resolves to unpaid', (tester) async {
    final orders = _Orders();
    final payments = _Payments();
    await _pumpScreen(tester, orders, payments);
    payments.events.add(null);
    await tester.pump();
    orders.events.add(_order);
    await tester.pumpAndSettle();

    expect(find.text('Unpaid'), findsOneWidget);
    expect(find.text('Pay ₱500'), findsOneWidget);
    expect(find.text('Checking payment status…'), findsNothing);
  });

  testWidgets('a stalled read offers retry and recovers on a payment event', (
    tester,
  ) async {
    final orders = _Orders();
    final payments = _Payments();
    await _pumpScreen(tester, orders, payments);
    orders.events.add(_order);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));

    expect(find.text('Checking payment status…'), findsNothing);
    expect(find.text('Retry payment status'), findsOneWidget);
    expect(find.text('Pay ₱500'), findsNothing);
    await tester.tap(find.text('Retry payment status'));
    await tester.pump();
    payments.events.add(_paid);
    await tester.pumpAndSettle();

    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('Retry payment status'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
