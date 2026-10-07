import 'package:intl/intl.dart';

import '../../orders/domain/order.dart';
import '../domain/commission.dart';
import '../domain/payment.dart';
import 'payment_gateway.dart';

/// The no-backend fallback: no gateway, no server, no card.
///
/// The client settles off-platform and the **freelancer** — the party who
/// actually receives the money — confirms it in the app. Deliberately, the
/// payer cannot mark their own payment received; otherwise the record would
/// assert nothing at all.
///
/// This produces an *attestation*, not proof. Every record it creates carries
/// `verified: false`, and the UI labels it as such. Swapping in
/// [XenditGateway] upgrades the same flow to a callback-proven payment
/// without touching the order lifecycle.
class ManualPaymentGateway implements PaymentGateway {
  const ManualPaymentGateway();

  @override
  PaymentMethod get method => PaymentMethod.manual;

  @override
  Future<CheckoutIntent> startCheckout({
    required WorkOrder order,
    required CommissionBreakdown breakdown,
    required PaymentChannel channel,
  }) async {
    final money = NumberFormat.decimalPattern();
    return ManualCheckout(
      instructions:
          'Send ₱${money.format(breakdown.gross)} to your freelancer using '
          'GCash, bank transfer, or cash, then record the reference below. '
          'The order can start once they confirm they received it.\n\n'
          'Platform commission of ₱${money.format(breakdown.commission)} '
          '(${breakdown.rateBasisPoints ~/ 100}%) is settled separately while '
          'the app runs without a payment gateway.',
    );
  }

  @override
  Future<PaymentStatus?> syncWithGateway(String orderId) async => null;
}
