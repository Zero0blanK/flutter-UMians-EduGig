import 'dart:math';

/// Mirrors FEATURED_PER_PAGE in functions/policy.js.
const featuredRotationPageSize = 3;

/// A session chooses a uniform starting seller in the server's fair rotation.
/// Subsequent pages continue around that rotation once, without repetitions.
List<int> featuredPositions({
  required int sessionSeed,
  required int sellerCount,
  required int pageIndex,
  int pageSize = featuredRotationPageSize,
}) {
  if (sellerCount <= 0 || pageIndex < 0) return const [];
  final consumed = pageIndex * pageSize;
  if (consumed >= sellerCount) return const [];
  final start = Random(sessionSeed).nextInt(sellerCount);
  return List.generate(
    min(pageSize, sellerCount - consumed),
    (index) => (start + consumed + index) % sellerCount,
  );
}
