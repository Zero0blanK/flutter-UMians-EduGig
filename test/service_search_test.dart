import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/services/data/service_repository.dart';
import 'package:student_freelance_services/features/services/domain/freelance_service.dart';

FreelanceService serviceWith({int sum = 0, int count = 0}) => FreelanceService(
  id: 's1',
  sellerId: 'seller',
  title: 'Event poster for your student org',
  description: 'x' * 40,
  categoryId: 'design',
  skills: const ['Illustrator', 'Layout'],
  startingPrice: 600,
  currency: 'PHP',
  deliveryDays: 3,
  revisionCount: 2,
  status: ServiceStatus.published,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  ratingSum: sum,
  ratingCount: count,
);

void main() {
  group('search keywords', () {
    test('tokenises the title so a word can be found mid-phrase', () {
      final keywords = FreelanceService.keywordsFor(
        'Event poster for your student org',
        const [],
      );
      // The old prefix match on titleLower could not find this.
      expect(keywords, contains('poster'));
      expect(keywords, contains('student'));
    });

    test('includes skills and lowercases everything', () {
      final keywords = FreelanceService.keywordsFor('Mix and master', const [
        'Ableton',
        'Sound Design',
      ]);
      expect(keywords, containsAll(['ableton', 'sound', 'design', 'master']));
      expect(keywords.every((k) => k == k.toLowerCase()), isTrue);
    });

    test('drops one-character noise and de-duplicates', () {
      final keywords = FreelanceService.keywordsFor(
        'A design a day, design!',
        const ['design'],
      );
      expect(keywords.where((k) => k == 'design').length, 1);
      expect(keywords, isNot(contains('a')));
    });

    test('handles punctuation and empty input without throwing', () {
      expect(FreelanceService.keywordsFor('', const []), isEmpty);
      expect(
        FreelanceService.keywordsFor('C++/Python (beginner)', const []),
        containsAll(['python', 'beginner']),
      );
    });

    test('stays within the array-contains-any ceiling when queried', () {
      final many = List.generate(80, (i) => 'skill$i');
      final keywords = FreelanceService.keywordsFor('title here', many);
      expect(keywords.length, lessThanOrEqualTo(40));
      expect(
        keywords.take(ServiceRepository.maxSearchTerms).length,
        lessThanOrEqualTo(10),
      );
    });
  });

  group('rating counters', () {
    test('averages from the stored totals', () {
      final service = serviceWith(sum: 14, count: 3);
      expect(service.hasRating, isTrue);
      expect(service.averageRating, closeTo(4.67, 0.01));
    });

    test('an unrated service reads as zero, never divides by zero', () {
      final service = serviceWith();
      expect(service.hasRating, isFalse);
      expect(service.averageRating, 0);
    });

    test('counters round-trip through toFirestore for a seller edit', () {
      // A seller edit rewrites the whole document; rules reject any change to
      // the score, so these must survive the round trip untouched.
      final map = serviceWith(sum: 14, count: 3).toFirestore(isNew: false);
      expect(map['ratingSum'], 14);
      expect(map['ratingCount'], 3);
    });

    test('toFirestore derives keywords rather than trusting a stored list', () {
      final map = serviceWith().toFirestore(isNew: true);
      expect(map['keywords'], contains('poster'));
      expect(map['titleLower'], 'event poster for your student org');
    });
  });

  group('sort options', () {
    test('every sort names a field the indexes cover', () {
      for (final sort in ServiceSort.values) {
        expect(['createdAt', 'startingPrice'], contains(sort.field));
        expect(sort.label, isNotEmpty);
      }
    });
  });

}
