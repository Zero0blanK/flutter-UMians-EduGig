import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/core/config/app_environment.dart';
import 'package:student_freelance_services/features/payments/domain/payment.dart';
import 'package:student_freelance_services/features/payments/payment_config.dart';

void main() {
  test('a build with no APP_ENV is production and shows no demo accounts', () {
    // Tests run without --dart-define, so this is the default every
    // release build gets.
    expect(kAppEnvironment, AppEnvironment.production);
    expect(kAppEnvironment.demoLogin, isFalse);
    expect(kAppEnvironment.usesEmulator, isFalse);
    expect(checkAppEnvironment, returnsNormally);
  });

  test('only the emulator build is redirected; both non-production builds get demo accounts', () {
    expect(AppEnvironment.development.usesEmulator, isFalse);
    expect(AppEnvironment.development.demoLogin, isTrue);
    expect(AppEnvironment.emulator.usesEmulator, isTrue);
    expect(AppEnvironment.emulator.demoLogin, isTrue);
  });

  test('a production build talks to the deployed api by default', () {
    // Nothing to configure for real payments: the api URL is baked in, and
    // an emulator build (the only one without a backend) is the exception.
    final config = PaymentConfig.fromEnvironment();
    expect(config.backendUrl, PaymentConfig.deployedBackendUrl);
    expect(config.mode, PaymentMode.xendit);
    expect(config.isVerifiable, isTrue);
    expect(
      PaymentConfig.deployedBackendUrl,
      startsWith('https://asia-southeast1-'),
    );
  });

  test('payment channels carry the wire names the backend maps', () {
    expect(PaymentChannel.values.map((c) => c.wireName), [
      'gcash',
      'maya',
      'card',
      'any',
    ]);
  });
}
