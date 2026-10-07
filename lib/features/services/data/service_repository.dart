import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../domain/freelance_service.dart';
import '../domain/featured_rotation.dart';

/// How the marketplace orders results.
///
/// Every option needs a composite index per equality-filter combination, so
/// the list is kept deliberately short: alphabetical order was dropped because
/// no one shops a marketplace by title.
enum ServiceSort {
  newest('createdAt', true, 'Newest'),
  priceLowToHigh('startingPrice', false, 'Price: low to high'),
  priceHighToLow('startingPrice', true, 'Price: high to low');

  const ServiceSort(this.field, this.descending, this.label);

  final String field;
  final bool descending;
  final String label;
}

/// One page of marketplace results, plus the cursor needed to fetch the next.
class ServicePage {
  const ServicePage({
    required this.items,
    required this.lastDocument,
    required this.exhausted,
  });

  final List<FreelanceService> items;

  /// Pass back as `startAfter` to continue; null when the page was empty.
  final DocumentSnapshot? lastDocument;

  /// True when a short page proves there is nothing more to load.
  final bool exhausted;
}

/// A bounded slice of the current featured rotation. An empty projection page
/// means the client has reached the end of the active seller pool.
class FeaturedServicePage {
  const FeaturedServicePage({required this.items, required this.exhausted});

  final List<FreelanceService> items;
  final bool exhausted;
}

/// One field of a composite index, as `firestore.indexes.json` spells it.
class IndexField {
  const IndexField(this.path, this.mode);

  final String path;

  /// `ASCENDING`, `DESCENDING`, or `CONTAINS` (array-contains-any counts as
  /// CONTAINS for indexing).
  final String mode;

  @override
  bool operator ==(Object other) =>
      other is IndexField && other.path == path && other.mode == mode;

  @override
  int get hashCode => Object.hash(path, mode);

  @override
  String toString() => '$path $mode';
}

class ServiceRepository {
  ServiceRepository(this._firestore);

  final FirebaseFirestore _firestore;

  static const pageSize = 20;
  int? _fallbackSession;
  Future<List<FreelanceService>>? _fallbackPool;

  /// Every composite index the marketplace queries below can ask for, in the
  /// field order Firestore wants (equality, array-contains, then the sort).
  ///
  /// The emulator never enforces indexes, so a query shape missing from
  /// `firestore.indexes.json` passes every local suite and fails in
  /// production with FAILED_PRECONDITION. `test/index_coverage_test.dart`
  /// checks this list against the file; keep it in step with
  /// [fetchPublished]. Featured cards use document reads from a backend
  /// projection and need no composite service index.
  static List<List<IndexField>> indexShapes() {
    const status = IndexField('status', 'ASCENDING');
    const category = IndexField('categoryId', 'ASCENDING');
    const keywords = IndexField('keywords', 'CONTAINS');
    return [
      for (final byCategory in [false, true])
        for (final bySearch in [false, true])
          for (final sort in ServiceSort.values)
            [
              status,
              if (byCategory) category,
              if (bySearch) keywords,
              IndexField(
                sort.field,
                sort.descending ? 'DESCENDING' : 'ASCENDING',
              ),
            ],
    ];
  }

  /// Firestore's ceiling for `array-contains-any` values.
  static const maxSearchTerms = 10;

  String newServiceId() =>
      _firestore.collection(FirestorePaths.services).doc().id;

  /// Public marketplace query. Only published services are ever returned;
  /// security rules enforce this independently of the query filters.
  ///
  /// Firestore has no full-text search, so [search] matches the derived
  /// `keywords` tokens. That finds a word anywhere in the title or skills —
  /// the previous prefix match on `titleLower` could not find "poster" inside
  /// "Event poster for your student org".
  Future<ServicePage> fetchPublished({
    String? categoryId,
    String? search,
    ServiceSort sort = ServiceSort.newest,
    DocumentSnapshot? startAfter,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _firestore
          .collection(FirestorePaths.services)
          .where('status', isEqualTo: ServiceStatus.published.name);

      if (categoryId != null && categoryId.isNotEmpty) {
        query = query.where('categoryId', isEqualTo: categoryId);
      }

      final terms = FreelanceService.keywordsFor(search ?? '', const []);
      if (terms.isNotEmpty) {
        // array-contains-any is capped by Firestore; a search box never needs
        // more terms than this, and the cap keeps the query legal.
        query = query.where(
          'keywords',
          arrayContainsAny: terms.take(maxSearchTerms).toList(),
        );
      }

      query = query.orderBy(sort.field, descending: sort.descending);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }
      final snapshot = await query.limit(pageSize).get();
      return ServicePage(
        items: snapshot.docs.map(FreelanceService.fromFirestore).toList(),
        // The caller needs the raw document to continue after it. Returning
        // only models made the cursor unobtainable, so paging silently
        // re-fetched page one and appended it again on every scroll.
        lastDocument: snapshot.docs.isEmpty ? null : snapshot.docs.last,
        exhausted: snapshot.docs.length < pageSize,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Reads one bounded page from the server's fair featured rotation.
  Future<FeaturedServicePage> fetchFeatured({
    String? categoryId,
    int pageIndex = 0,
    int sessionSeed = 0,
    Set<String> excludedSellerIds = const {},
  }) async {
    try {
      final scopeId = categoryId == null || categoryId.isEmpty
          ? 'all'
          : 'category_${base64Url.encode(utf8.encode(categoryId)).replaceAll('=', '')}';
      Map<String, dynamic>? root;
      try {
        root =
            (await _firestore.doc('featuredRotations/${scopeId}__page_0').get())
                .data();
      } on FirebaseException catch (failure) {
        if (failure.code != 'permission-denied') rethrow;
      }
      final rootIds = (root?['serviceIds'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList();
      if (rootIds.isEmpty) {
        return await _fetchFallbackFeatured(
          categoryId: categoryId,
          pageIndex: pageIndex,
          sessionSeed: sessionSeed,
          excludedSellerIds: excludedSellerIds,
        );
      }
      final pageCount = root?['pageCount'] as int? ?? 1;
      final pages = <int, List<String>>{0: rootIds};
      Future<List<String>> readPage(int index) async {
        if (pages.containsKey(index)) return pages[index]!;
        final data =
            (await _firestore
                    .doc('featuredRotations/${scopeId}__page_$index')
                    .get())
                .data();
        return pages[index] =
            (data?['serviceIds'] as List<dynamic>? ?? const [])
                .whereType<String>()
                .toList();
      }

      // Older projections lack the pool size; the last page gives its exact
      // size, including a partial final page, without favouring full pages.
      final sellerCount =
          root?['sellerCount'] as int? ??
          (pageCount - 1) * featuredRotationPageSize +
              (await readPage(pageCount - 1)).length;
      final positions = featuredPositions(
        sessionSeed: sessionSeed,
        sellerCount: sellerCount,
        pageIndex: pageIndex,
      );
      final ids = <String>[];
      for (final position in positions) {
        final page = await readPage(position ~/ featuredRotationPageSize);
        if (position % featuredRotationPageSize < page.length) {
          ids.add(page[position % featuredRotationPageSize]);
        }
      }
      final snapshots = await Future.wait(ids.map(_readActiveFeatured));
      final sellers = Set<String>.of(excludedSellerIds);
      final active = <FreelanceService>[];
      for (final service in snapshots) {
        if (service != null &&
            (categoryId == null ||
                categoryId.isEmpty ||
                service.categoryId == categoryId) &&
            sellers.add(service.sellerId)) {
          active.add(service);
        }
      }
      return FeaturedServicePage(
        items: active,
        exhausted: (pageIndex + 1) * featuredRotationPageSize >= sellerCount,
      );
    } on Exception catch (failure) {
      throw AppFailure.from(failure);
    }
  }

  Future<FeaturedServicePage> _fetchFallbackFeatured({
    required String? categoryId,
    required int pageIndex,
    required int sessionSeed,
    required Set<String> excludedSellerIds,
  }) async {
    // Load once per session when projections are unavailable. This includes
    // the entire active pool, rather than repeatedly reading the first 60.
    if (_fallbackSession != sessionSeed || _fallbackPool == null) {
      _fallbackSession = sessionSeed;
      _fallbackPool = _loadFallbackPool(sessionSeed);
    }
    final List<FreelanceService> pool;
    try {
      pool = await _fallbackPool!;
    } catch (_) {
      _fallbackPool = null;
      rethrow;
    }
    final eligible = pool
        .where(
          (service) =>
              service.isFeatured &&
              (categoryId == null ||
                  categoryId.isEmpty ||
                  service.categoryId == categoryId),
        )
        .toList();
    final candidates = eligible
        .skip(pageIndex * featuredRotationPageSize)
        .take(featuredRotationPageSize)
        .where((service) => !excludedSellerIds.contains(service.sellerId))
        .toList();
    final items = (await Future.wait(
      candidates.map((service) => _readActiveFeatured(service.id)),
    )).whereType<FreelanceService>().toList();
    return FeaturedServicePage(
      items: items,
      exhausted: (pageIndex + 1) * featuredRotationPageSize >= eligible.length,
    );
  }

  Future<List<FreelanceService>> _loadFallbackPool(int seed) async {
    final snapshot = await _firestore
        .collection(FirestorePaths.services)
        .where('status', isEqualTo: ServiceStatus.published.name)
        .where('featuredUntil', isGreaterThan: Timestamp.now())
        .orderBy('featuredUntil', descending: true)
        .get();
    final bySeller = <String, List<FreelanceService>>{};
    for (final document in snapshot.docs) {
      final service = FreelanceService.fromFirestore(document);
      (bySeller[service.sellerId] ??= []).add(service);
    }
    final random = Random(seed);
    final sellers = bySeller.keys.toList()..sort();
    final pool = [
      for (final seller in sellers)
        bySeller[seller]![random.nextInt(bySeller[seller]!.length)],
    ];
    pool.shuffle(random);
    return pool;
  }

  /// Revalidate saved placements so paused or expired listings are omitted.
  Future<List<FreelanceService>> fetchFeaturedSelection(
    List<String> ids,
  ) async {
    final selected = await Future.wait([
      for (final id in ids.where((id) => id.isNotEmpty && !id.contains('/')))
        _readActiveFeatured(id),
    ]);
    return selected.whereType<FreelanceService>().toList();
  }

  Future<FreelanceService?> _readActiveFeatured(String id) async {
    try {
      final snapshot = await _firestore
          .doc('${FirestorePaths.services}/$id')
          .get();
      if (!snapshot.exists) return null;
      final service = FreelanceService.fromFirestore(snapshot);
      return service.status == ServiceStatus.published && service.isFeatured
          ? service
          : null;
    } on FirebaseException catch (failure) {
      // A placement may be paused or removed between rotation refreshes.
      // Service read rules then deny access; skip that card, not the section.
      if (failure.code == 'permission-denied' || failure.code == 'not-found') {
        return null;
      }
      rethrow;
    }
  }

  Stream<List<FreelanceService>> watchMine(
    String sellerId, {
    int limit = pageSize,
  }) {
    return _firestore
        .collection(FirestorePaths.services)
        .where('sellerId', isEqualTo: sellerId)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(FreelanceService.fromFirestore).toList());
  }

  Stream<List<FreelanceService>> watchPublishedBySeller(
    String sellerId, {
    int limit = pageSize,
  }) {
    return _firestore
        .collection(FirestorePaths.services)
        .where('sellerId', isEqualTo: sellerId)
        .where('status', isEqualTo: ServiceStatus.published.name)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(FreelanceService.fromFirestore).toList());
  }

  Future<FreelanceService> fetchById(String id) async {
    try {
      final doc = _firestore.doc('${FirestorePaths.services}/$id');
      final snapshot = await doc.get();
      if (!snapshot.exists) throw const NotFoundFailure();
      return FreelanceService.fromFirestore(snapshot);
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Creates or updates a service. `sellerId` always comes from the signed-in
  /// user server-side in rules; a client cannot create services for others.
  Future<void> save(FreelanceService service, {required bool isNew}) async {
    _validate(service);
    try {
      await _firestore
          .doc('${FirestorePaths.services}/${service.id}')
          .set(service.toFirestore(isNew: isNew), SetOptions(merge: false));
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Publishes, pauses, or archives a service. Ownership is enforced by
  /// security rules; this took a `sellerId` it never read, which implied a
  /// check that happens elsewhere.
  Future<void> setStatus({
    required String serviceId,
    required ServiceStatus status,
  }) async {
    try {
      await _firestore.doc('${FirestorePaths.services}/$serviceId').update({
        'status': status.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  void _validate(FreelanceService service) {
    if (service.title.trim().isEmpty || service.title.trim().length > 80) {
      throw const InvalidInputFailure('Title must be 1-80 characters.');
    }
    if (service.description.trim().length < 20 ||
        service.description.length > 4000) {
      throw const InvalidInputFailure(
        'Description must be 20-4000 characters.',
      );
    }
    if (service.startingPrice < 1 || service.startingPrice > 1000000) {
      throw const InvalidInputFailure(
        'Price must be between ₱1 and ₱1,000,000.',
      );
    }
    if (service.deliveryDays < 1 || service.deliveryDays > 90) {
      throw const InvalidInputFailure('Delivery must be 1-90 days.');
    }
    if (service.revisionCount < 0 || service.revisionCount > 10) {
      throw const InvalidInputFailure('Revisions must be 0-10.');
    }
  }
}
