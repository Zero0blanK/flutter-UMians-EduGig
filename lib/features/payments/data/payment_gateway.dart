import '../../orders/domain/order.dart';
import '../domain/commission.dart';
import '../domain/payment.dart';

/// What the client should do next to actually pay.
///
/// Sealed because the two modes demand genuinely different UI: one opens a
/// hosted checkout page, the other shows settlement instructions. Modelling
/// that as a sum type means a screen cannot forget to handle a case.
sealed class CheckoutIntent {
  const CheckoutIntent();
}

/// Gateway mode: send the client to a hosted Xendit invoice page.
final class RedirectCheckout extends CheckoutIntent {
  const RedirectCheckout({required this.checkoutUrl, required this.reference});

  final Uri checkoutUrl;

  /// The gateway's id for this checkout, stored for reconciliation.
  final String reference;
}

/// Manual mode: nothing to redirect to; the client pays off-platform and the
/// freelancer confirms receipt in the app.
final class ManualCheckout extends CheckoutIntent {
  const ManualCheckout({required this.instructions});

  final String instructions;
}

/// A source of payment intents. Two implementations exist so the no-backend
/// build and the gateway build differ by one binding in `main.dart` rather
/// than by conditionals scattered through the UI.
abstract interface class PaymentGateway {
  PaymentMethod get method;

  /// Prepares payment for [order] through [channel]. Implementations must
  /// not write to Firestore — persistence belongs to `PaymentRepository`,
  /// which stays the single writer for payment documents.
  Future<CheckoutIntent> startCheckout({
    required WorkOrder order,
    required CommissionBreakdown breakdown,
    required PaymentChannel channel,
  });

  /// Asks the gateway, through the backend, whether [orderId]'s pending
  /// payment has gone through, and returns the record's status afterwards.
  /// Null when there is nothing to ask: manual settlements have no gateway.
  Future<PaymentStatus?> syncWithGateway(String orderId);
}
