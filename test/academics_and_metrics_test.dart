import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/core/constants/academics.dart';
import 'package:student_freelance_services/features/admin/domain/platform_metrics.dart';
import 'package:student_freelance_services/features/auth/domain/user_profile.dart';
import 'package:student_freelance_services/features/orders/domain/order.dart';

void main() {
  group('colleges', () {
    test('every college has a unique id and at least one program', () {
      final ids = kColleges.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate college id');
      for (final college in kColleges) {
        expect(college.programs, isNotEmpty, reason: college.id);
        expect(college.short, isNotEmpty);
      }
    });

    test('ids match the closed set mirrored into security rules', () {
      // Rules validate collegeId against this exact list. If they drift, a
      // student picks a college the database then refuses to store.
      expect(kCollegeIds..sort(), [
        'cae',
        'case',
        'cbae',
        'cce',
        'cee',
        'chse',
        'cte',
      ]);
    });

    test('lookup tolerates unset and unknown ids', () {
      expect(collegeById('cce')?.short, 'CCE');
      expect(collegeById(null), isNull);
      expect(collegeById(''), isNull);
      expect(collegeById('hogwarts'), isNull);
      expect(programsFor('nope'), isEmpty);
    });

    test('summary degrades gracefully when half the pair is missing', () {
      expect(
        academicSummary(collegeId: 'cce', program: 'BS Computer Science'),
        'BS Computer Science · CCE',
      );
      expect(academicSummary(collegeId: 'cce'), 'CCE');
      expect(academicSummary(program: 'BS Nursing'), 'BS Nursing');
      expect(academicSummary(), '');
    });
  });

  group('profile academics', () {
    UserProfile profileWith({String? college, String? program}) => UserProfile(
      uid: 'u1',
      displayName: 'Maya Robles',
      bio: '',
      skills: const [],
      createdAt: DateTime(2026),
      collegeId: college,
      program: program,
    );

    test('reads back the college object', () {
      final profile = profileWith(
        college: 'cce',
        program: 'BS Computer Science',
      );
      expect(profile.college?.name, 'College of Computing Education');
      expect(profile.academics, 'BS Computer Science · CCE');
    });

    test('an older profile without either field is still valid', () {
      final profile = profileWith();
      expect(profile.college, isNull);
      expect(profile.academics, '');
    });

    test(
      'omits the fields from writes when unset, rather than writing null',
      () {
        // Rules bound these when present; writing an explicit null would be a
        // value the validator has to special-case for no benefit.
        expect(profileWith().toUpdate().containsKey('collegeId'), isFalse);
        expect(profileWith(college: 'cce').toUpdate()['collegeId'], 'cce');
      },
    );
  });

  group('platform metrics', () {
    PlatformMetrics metrics({
      int orders = 0,
      Map<OrderStatus, int> byStatus = const {},
      int settled = 0,
      int gross = 0,
      int commission = 0,
    }) => PlatformMetrics(
      users: 0,
      services: 0,
      publishedServices: 0,
      orders: orders,
      reviews: 0,
      ordersByStatus: byStatus,
      settledPayments: settled,
      grossMerchandiseValue: gross,
      commissionEarned: commission,
      paidOutToFreelancers: gross - commission,
    );

    test('rates are zero on an empty platform, never NaN', () {
      final m = metrics();
      expect(m.completionRate, 0);
      expect(m.disputeRate, 0);
      expect(m.averageOrderValue, 0);
    });

    test('completion and dispute rates are shares of all orders', () {
      final m = metrics(
        orders: 20,
        byStatus: {OrderStatus.completed: 15, OrderStatus.disputed: 1},
      );
      expect(m.completionRate, 75);
      expect(m.disputeRate, closeTo(5, 0.001));
    });

    test('revenue figures reconcile by construction', () {
      final m = metrics(settled: 4, gross: 4800, commission: 480);
      expect(
        m.commissionEarned + m.paidOutToFreelancers,
        m.grossMerchandiseValue,
      );
      expect(m.averageOrderValue, 1200);
    });

    test('an absent status reads as zero', () {
      expect(metrics().countOf(OrderStatus.disputed), 0);
    });
  });

  group('audit entries', () {
    test('render a dotted action as a sentence', () {
      final action = AdminAction(
        id: 'a1',
        actorId: 'admin',
        action: 'dispute.completed',
        targetType: 'order',
        targetId: 'o1',
        note: '',
        createdAt: DateTime(2026),
      );
      expect(action.label, 'Dispute completed');
    });

    test('an unexpected shape falls back to the raw value', () {
      final action = AdminAction(
        id: 'a1',
        actorId: 'admin',
        action: 'legacy',
        targetType: 'order',
        targetId: 'o1',
        note: '',
        createdAt: DateTime(2026),
      );
      expect(action.label, 'legacy');
    });
  });
}
