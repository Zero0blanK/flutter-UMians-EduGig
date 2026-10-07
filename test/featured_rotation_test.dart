import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/services/domain/featured_rotation.dart';

void main() {
  test('session rotation visits all 100 sellers exactly once', () {
    for (var seed = 0; seed < 100; seed++) {
      final positions = <int>[];
      for (var page = 0; page < 34; page++) {
        positions.addAll(
          featuredPositions(
            sessionSeed: seed,
            sellerCount: 100,
            pageIndex: page,
          ),
        );
      }
      expect(positions, hasLength(100));
      expect(positions.toSet(), hasLength(100));
      expect(
        featuredPositions(sessionSeed: seed, sellerCount: 100, pageIndex: 34),
        isEmpty,
      );
    }
  });

  test('sessions change the highlighted group and expose every seller', () {
    final appearances = List.filled(100, 0);
    final groups = <String>{};
    for (var seed = 0; seed < 1000; seed++) {
      final highlighted = [
        ...featuredPositions(sessionSeed: seed, sellerCount: 100, pageIndex: 0),
        ...featuredPositions(sessionSeed: seed, sellerCount: 100, pageIndex: 1),
      ].take(5).toList();
      groups.add(highlighted.join(','));
      for (final seller in highlighted) {
        appearances[seller]++;
      }
    }
    expect(groups.length, greaterThan(90));
    expect(appearances.every((count) => count > 0), isTrue);
    expect(
      featuredPositions(sessionSeed: 0, sellerCount: 0, pageIndex: 0),
      isEmpty,
    );
  });
}
