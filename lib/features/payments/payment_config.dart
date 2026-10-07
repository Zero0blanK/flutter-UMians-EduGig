import '../../core/config/app_environment.dart';
import 'domain/commission.dart';
import 'domain/payment.dart';

/// Chooses which payment backend the app runs against.
///
/// Production and development builds talk to the deployed `api` function
/// ([PaymentConfig.deployedBackendUrl]) and run in [PaymentMode.xendit]:
/// checkout, payouts, Pro and the staff queues all work out of the box.
/// The emulator build has no backend and falls back to [PaymentMode.manual],
/// which stays fully runnable with no server, no gateway account, and no
/// card. Either can be overridden at build time:
///
/// ```sh
/// flutter run --dart-define=PAYMENTS_API_URL=https://other-backend.example.com
/// flutter run --dart-define=PAYMENTS_API_URL=manual   # force the no-backend path
/// ```
///
/// Nothing secret is configured here. The Xendit **secret key never reaches
/// this app** — it lives only on the backend. See `functions/README.md`.
enum PaymentMode {
  /// Free-tier fallback. Money is settled off-platform (GCash, bank transfer,
  /// cash) and confirmed in-app by the freelancer who received it.
  manual,

  /// Gateway mode. The backend creates a Xendit invoice and a token-verified
  /// callback confirms settlement server-side.
  xendit,
}

class PaymentConfig {
  const PaymentConfig({
    required this.backendUrl,
    this.commissionPolicy = CommissionPolicy.standard,
  });

  /// The `api` Cloud Function of this Firebase project, as deployed by
  /// `firebase deploy --only functions` (region `asia-southeast1`).
  static const deployedBackendUrl =
      'https://asia-southeast1-student-freelance-services.cloudfunctions.net/api';

  /// Reads the build-time configuration: an explicit `PAYMENTS_API_URL`
  /// wins; `manual` forces the no-backend path; otherwise the deployed
  /// backend, except in the emulator environment, which has none.
  factory PaymentConfig.fromEnvironment() {
    const explicit = String.fromEnvironment('PAYMENTS_API_URL');
    if (explicit == 'manual') return const PaymentConfig(backendUrl: '');
    if (explicit.isNotEmpty) return const PaymentConfig(backendUrl: explicit);
    return PaymentConfig(
      backendUrl: kAppEnvironment.usesEmulator ? '' : deployedBackendUrl,
    );
  }

  /// Base URL of the trusted payments backend; empty in manual mode.
  final String backendUrl;

  /// Commission charged on each order. See [CommissionPolicy].
  final CommissionPolicy commissionPolicy;

  PaymentMode get mode =>
      backendUrl.isEmpty ? PaymentMode.manual : PaymentMode.xendit;

  PaymentMethod get method => switch (mode) {
    PaymentMode.manual => PaymentMethod.manual,
    PaymentMode.xendit => PaymentMethod.xendit,
  };

  /// Whether settlement can be proven rather than merely attested.
  ///
  /// Drives honest UI copy: manual mode must not present an attestation as if
  /// it were a verified gateway receipt.
  bool get isVerifiable => mode == PaymentMode.xendit;

  /// Short line shown in the payment UI so testers always know which mode is
  /// live — the single most confusing thing about a dual-backend build.
  String get modeDescription => switch (mode) {
    PaymentMode.manual =>
      'Direct settlement — pay the freelancer outside the app, then they '
          'confirm receipt here.',
    PaymentMode.xendit =>
      'Secure checkout via Xendit (GCash, Maya, cards). The platform holds '
          'the money and '
          'releases it to the freelancer once the work is accepted.',
  };
}
