import '../../../core/backend/backend_client.dart';
import '../../../core/errors/app_failure.dart';
import '../../orders/domain/order.dart';
import '../domain/commission.dart';
import '../domain/payment.dart';
import 'payment_gateway.dart';

/// Gateway mode. Talks to **our own backend**, never to Xendit directly.
///
/// This indirection is the whole security model, not an architectural
/// nicety. Xendit's secret key (`xnd_…`) is required to create an invoice,
/// and a Flutter build cannot hold one. The key therefore lives only on the
/// backend, which:
///
///  1. authenticates the caller with their Firebase ID token,
///  2. reads the order from Firestore and derives the amount **server-side**
///     (a client-supplied amount would let a buyer pay ₱1 for a ₱5000 order),
///  3. creates the Xendit invoice with the secret key, and
///  4. later receives Xendit's token-verified callback, writes the confirmed
///     payment with the Admin SDK, and **holds** the money until the order
///     completes.
class XenditGateway implements PaymentGateway {
  XenditGateway(this._backend);

  final BackendClient _backend;

  @override
  PaymentMethod get method => PaymentMethod.xendit;

  @override
  Future<CheckoutIntent> startCheckout({
    required WorkOrder order,
    required CommissionBreakdown breakdown,
    required PaymentChannel channel,
  }) async {
    // Only the order id and the chosen channel are sent. Amount, commission,
    // and participants are all re-derived by the backend from the trusted
    // order document, so tampering with this request cannot change what is
    // charged.
    final body = await _backend.post(
      '/checkout',
      body: {'orderId': order.id, 'method': channel.wireName},
    );
    return parseRedirect(body);
  }

  @override
  Future<PaymentStatus?> syncWithGateway(String orderId) async {
    final body = await _backend.post('/payments/$orderId/sync');
    final status = body['status'];
    return status is String ? PaymentStatus.fromName(status) : null;
  }

  /// Turns an invoice response into a redirect, refusing anything that is
  /// not an HTTPS destination: a downgraded URL here would send card details
  /// over an insecure channel.
  static RedirectCheckout parseRedirect(Map<String, dynamic> body) {
    final url = body['checkoutUrl'] as String?;
    final reference = body['reference'] as String?;
    if (url == null || reference == null) throw const PaymentGatewayFailure();
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.isScheme('https')) {
      throw const PaymentGatewayFailure();
    }
    return RedirectCheckout(checkoutUrl: parsed, reference: reference);
  }
}
