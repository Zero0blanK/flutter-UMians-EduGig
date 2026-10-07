import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/core/platform/platform_repository.dart';
import 'package:student_freelance_services/features/admin/domain/admin_access.dart';
import 'package:student_freelance_services/features/auth/domain/um_account.dart';
import 'package:student_freelance_services/features/offers/domain/offer.dart';
import 'package:student_freelance_services/features/services/domain/freelance_service.dart';

FreelanceService _listing({
  PricingMode mode = PricingMode.fixed,
  bool requiresContact = false,
}) => FreelanceService(
  id: 's',
  sellerId: 'seller',
  title: 'Logo',
  description: 'A logo and a brand sheet for your org.',
  categoryId: 'design',
  skills: const [],
  startingPrice: 800,
  currency: 'PHP',
  deliveryDays: 5,
  revisionCount: 2,
  status: ServiceStatus.published,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  pricingMode: mode,
  requiresContact: requiresContact,
);

void main() {
  group('UM accounts', () {
    test('only the university domain is accepted, case-insensitively', () {
      expect(UmAccount.isUmEmail('a.nerosa.545679@umindanao.edu.ph'), isTrue);
      expect(UmAccount.isUmEmail('A.Nerosa.545679@UMindanao.edu.ph'), isTrue);
      expect(UmAccount.isUmEmail('registrar@umindanao.edu.ph'), isTrue);
      expect(UmAccount.isUmEmail('april@gmail.com'), isFalse);
      expect(
        UmAccount.isUmEmail('a.b.123456@umindanao.edu.ph.evil.com'),
        isFalse,
      );
      expect(UmAccount.isUmEmail(null), isFalse);
    });

    test('a student address yields its number; a staff address does not', () {
      expect(
        UmAccount.studentIdOf('a.nerosa.545679@umindanao.edu.ph'),
        '545679',
      );
      expect(
        UmAccount.isStudentEmail('a.nerosa.545679@umindanao.edu.ph'),
        isTrue,
      );
      expect(UmAccount.studentIdOf('registrar@umindanao.edu.ph'), isNull);
      expect(UmAccount.studentIdOf('a.nerosa.54567@umindanao.edu.ph'), isNull);
      expect(UmAccount.studentIdOf('a.nerosa.545679@gmail.com'), isNull);
    });
  });

  group('pricing modes', () {
    test(
      'only a fixed-price listing without contact-first is orderable directly',
      () {
        expect(_listing().canOrderDirectly, isTrue);
        expect(
          _listing(mode: PricingMode.negotiable).canOrderDirectly,
          isFalse,
        );
        expect(_listing(requiresContact: true).canOrderDirectly, isFalse);
        expect(
          _listing(
            mode: PricingMode.negotiable,
            requiresContact: true,
          ).canOrderDirectly,
          isFalse,
        );
      },
    );

    test('unknown wire values read as fixed, never as negotiable', () {
      expect(PricingMode.fromName('nonsense'), PricingMode.fixed);
      expect(PricingMode.fromName(null), PricingMode.fixed);
      expect(PricingMode.fromName('negotiable'), PricingMode.negotiable);
    });

    test('a listing save carries the pricing fields', () {
      final data = _listing(
        mode: PricingMode.negotiable,
        requiresContact: true,
      ).toFirestore(isNew: true);
      expect(data['pricingMode'], 'negotiable');
      expect(data['requiresContact'], isTrue);
    });
  });

  group('offers', () {
    test('an unanswered offer expires; a decided one does not', () {
      Offer offer(OfferStatus status, DateTime expiresAt) => Offer(
        id: 'o',
        serviceId: 's',
        serviceTitle: 'Logo',
        freelancerId: 'f',
        clientId: 'c',
        conversationId: 'c_f',
        price: 1200,
        deliveryDays: 7,
        revisionCount: 3,
        scope: 'Primary logo and a brand sheet.',
        status: status,
        createdAt: DateTime(2026),
        expiresAt: expiresAt,
      );
      final past = DateTime.now().subtract(const Duration(days: 1));
      final future = DateTime.now().add(const Duration(days: 1));
      expect(offer(OfferStatus.pending, past).isExpired, isTrue);
      expect(offer(OfferStatus.pending, future).isExpired, isFalse);
      expect(offer(OfferStatus.accepted, past).isExpired, isFalse);
      expect(offer(OfferStatus.ordered, past).isExpired, isFalse);
      expect(Offer.validity, const Duration(days: 7));
    });

    test('unknown statuses degrade to pending, never to accepted', () {
      expect(OfferStatus.fromName('nonsense'), OfferStatus.pending);
      expect(OfferStatus.fromName('accepted'), OfferStatus.accepted);
    });
  });

  group('staff access', () {
    test('the main admin can do everything; staff only what is listed', () {
      const boss = AdminAccess(
        uid: 'a',
        role: AdminRole.admin,
        permissions: {},
      );
      const staff = AdminAccess(
        uid: 's',
        role: AdminRole.staff,
        permissions: {AdminPermission.servicesModerate},
      );
      for (final p in AdminPermission.values) {
        expect(boss.can(p), isTrue, reason: p.wireName);
      }
      expect(boss.canManageStaff, isTrue);
      expect(staff.can(AdminPermission.servicesModerate), isTrue);
      expect(staff.can(AdminPermission.payoutsSettle), isFalse);
      expect(staff.canManageStaff, isFalse);
    });

    test('permission wire names match the rules and backend list', () {
      expect(AdminPermission.values.map((p) => p.wireName).toList(), [
        'users.manage',
        'services.moderate',
        'categories.manage',
        'orders.manage',
        'disputes.resolve',
        'payouts.settle',
        'refunds.handle',
        'verification.decide',
        'reports.view',
        'settings.manage',
      ]);
      expect(AdminPermission.fromWire('everything'), isNull);
    });

    test('audit entries read aloud', () {
      final entry = AuditEntry(
        id: 'x',
        actorId: 'u',
        action: 'order.status_changed',
        createdAt: DateTime(2026),
      );
      expect(entry.label, 'Order status changed');
    });
  });

  group('categories', () {
    test('staff entries override, retire and extend the built-in list', () {
      final merged = PlatformSettingsRepository.mergeCategories([
        const Category(
          id: 'design',
          label: 'Design & branding',
          active: true,
          sortOrder: 0,
        ),
        const Category(
          id: 'other',
          label: 'Other',
          active: false,
          sortOrder: 99,
        ),
        const Category(
          id: '3d-printing',
          label: '3D printing',
          active: true,
          sortOrder: 3,
        ),
        const Category(
          id: 'retired-new',
          label: 'Nope',
          active: false,
          sortOrder: 4,
        ),
      ]);
      final ids = merged.map((c) => c.id).toList();
      expect(ids, contains('3d-printing'));
      expect(ids, isNot(contains('other')));
      expect(ids, isNot(contains('retired-new')));
      expect(
        merged.firstWhere((c) => c.id == 'design').label,
        'Design & branding',
      );
      // Placed by sortOrder among the built-ins (writing is 2, video is 4),
      // not appended at the end.
      expect(ids.indexOf('3d-printing'), greaterThan(ids.indexOf('writing')));
      expect(ids.indexOf('3d-printing'), lessThan(ids.indexOf('photography')));
    });

    test('with no staff entries the built-in list is used as-is', () {
      final merged = PlatformSettingsRepository.mergeCategories(const []);
      expect(merged.length, 8);
      expect(merged.first.id, 'tutoring');
    });
  });
}
