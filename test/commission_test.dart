import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/payments/domain/commission.dart';
import 'package:student_freelance_services/features/payments/domain/payment.dart';
import 'package:student_freelance_services/features/payments/payment_config.dart';

void main() {
  group('commission split', () {
    test('takes 5% of a round order value', () {
      final split = CommissionPolicy.standard.breakdownOf(500);
      expect(split.commission, 25);
      expect(split.netToFreelancer, 475);
    });

    test('rounds half-up without a fixed minimum on small orders', () {
      expect(CommissionPolicy.standard.breakdownOf(1750).commission, 88);
      expect(CommissionPolicy.standard.breakdownOf(1749).commission, 87);
      expect(CommissionPolicy.standard.breakdownOf(150).commission, 8);
      expect(CommissionPolicy.standard.breakdownOf(150).netToFreelancer, 142);
      expect(CommissionPolicy.standard.breakdownOf(10).commission, 1);
      expect(CommissionPolicy.standard.breakdownOf(1).commission, 0);
    });

    test('matches the backend twin in functions/policy.js', () {
      const cases = {150: 8, 175: 9, 300: 15, 500: 25, 1000: 50, 1755: 88};
      cases.forEach((gross, commission) {
        expect(
          CommissionPolicy.standard.breakdownOf(gross).commission,
          commission,
        );
      });
    });

    test('never invents or loses money at any price point', () {
      // The invariant the UI, the rules, and the backend all depend on.
      for (var gross = 0; gross <= 2000; gross++) {
        final split = CommissionPolicy.standard.breakdownOf(gross);
        expect(
          split.isBalanced,
          isTrue,
          reason: 'split of $gross did not reconstitute the gross',
        );
        expect(split.commission, greaterThanOrEqualTo(0));
        expect(split.netToFreelancer, greaterThanOrEqualTo(0));
      }
    });

    test('handles a zero-value order without dividing by anything', () {
      final split = CommissionPolicy.standard.breakdownOf(0);
      expect(split.commission, 0);
      expect(split.netToFreelancer, 0);
      expect(split.isBalanced, isTrue);
    });

    test('rejects a negative order value', () {
      expect(
        () => CommissionPolicy.standard.breakdownOf(-1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('labels rates readably', () {
      expect(CommissionPolicy.standard.rateLabel, '5%');
      expect(const CommissionPolicy(500).rateLabel, '5%');
      expect(const CommissionPolicy(250).rateLabel, '2.5%');
    });
  });

  group('payment configuration', () {
    test('falls back to manual settlement when no backend is configured', () {
      const config = PaymentConfig(backendUrl: '');
      expect(config.mode, PaymentMode.manual);
      expect(config.method, PaymentMethod.manual);
      // Manual settlement is an attestation, so the UI must not claim proof.
      expect(config.isVerifiable, isFalse);
    });

    test('switches to the gateway when a backend URL is supplied', () {
      const config = PaymentConfig(backendUrl: 'https://pay.example.com');
      expect(config.mode, PaymentMode.xendit);
      expect(config.method, PaymentMethod.xendit);
      expect(config.isVerifiable, isTrue);
    });
  });

  group('payment status', () {
    test('unknown wire values degrade to pending, never to paid', () {
      // A corrupted or future status must never read as settled money.
      expect(PaymentStatus.fromName('nonsense'), PaymentStatus.pending);
      expect(PaymentStatus.fromName(null), PaymentStatus.pending);
      expect(PaymentStatus.fromName('paid'), PaymentStatus.paid);
    });

    test('unknown methods degrade to manual', () {
      expect(PaymentMethod.fromName('nonsense'), PaymentMethod.manual);
      expect(PaymentMethod.fromName('xendit'), PaymentMethod.xendit);
      // A record from the previous gateway is not silently re-labelled.
      expect(PaymentMethod.fromName('payMongo'), PaymentMethod.manual);
    });
  });
}
