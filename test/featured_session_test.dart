import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/marketplace/domain/featured_session.dart';

void main() {
  test(
    'today suppression ends at local midnight including month boundaries',
    () {
      final checkedAt = DateTime(2026, 10, 31, 23, 45);
      final until = FeaturedSession.nextDay(checkedAt);
      expect(until, DateTime(2026, 11, 1));
      final relaunched = FeaturedSession()..suppressedUntil = until;
      expect(relaunched.canShowShowcase(checkedAt), isFalse);
      expect(
        relaunched.canShowShowcase(until.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(relaunched.canShowShowcase(until), isTrue);
    },
  );

  test(
    'featured selection expires at 30 minutes independently of the popup',
    () {
      final selectedAt = DateTime(2026, 10, 7, 12);
      final session = FeaturedSession()
        ..selectedAt = selectedAt
        ..showcaseShown = true;

      expect(session.isFresh(selectedAt), isTrue);
      expect(
        session.isFresh(
          selectedAt.add(const Duration(minutes: 29, seconds: 59)),
        ),
        isTrue,
      );
      expect(
        session.isFresh(selectedAt.add(const Duration(minutes: 30))),
        isFalse,
      );
      expect(session.showcaseShown, isTrue);
      expect(FeaturedSession().showcaseShown, isFalse);
      expect(
        session.isFresh(selectedAt.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    },
  );
}
