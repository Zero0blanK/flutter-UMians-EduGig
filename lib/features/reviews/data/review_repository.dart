import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../notifications/data/notification_repository.dart';
import '../../notifications/domain/app_notification.dart';
import '../../orders/domain/order.dart';
import '../../services/domain/freelance_service.dart';

class ReviewRepository {
  ReviewRepository(this._firestore);

  final FirebaseFirestore _firestore;

  static const maxCommentLength = 1000;

  /// Creates the review and notifies the freelancer; the backend pushes it.
  ///
  /// Deliberately writes nothing to the order document. Orders accept updates
  /// to status/deadline/updatedAt and nothing else, so an extra `hasReview`
  /// flag was rejected by security rules and took the whole transaction — and
  /// therefore every review — down with it. Whether an order has been reviewed
  /// is already answered by whether `reviews/{orderId}` exists.
  ///
  /// The review document id equals the order id: Firestore rejects the second
  /// create of the same id, making duplicate reviews impossible even under
  /// concurrent submissions.
  Future<void> submitReview({
    required WorkOrder order,
    required int rating,
    required String comment,
  }) async {
    if (!order.status.isCompletedStatus || rating < 1 || rating > 5) {
      throw const InvalidInputFailure('This order cannot be reviewed.');
    }
    final text = comment.trim();
    if (text.isEmpty || text.length > maxCommentLength) {
      throw InvalidInputFailure(
        'Reviews must be 1-$maxCommentLength characters.',
      );
    }

    final reviewRef = _firestore.doc('${FirestorePaths.reviews}/${order.id}');
    final serviceRef = _firestore.doc(
      '${FirestorePaths.services}/${order.serviceId}',
    );

    try {
      // Friendly message for the common case; the real guarantee is that the
      // review id equals the order id and rules allow create only, so a second
      // submission is refused server-side even if this read races.
      if ((await reviewRef.get()).exists) {
        throw const InvalidInputFailure(
          'This order has already been reviewed.',
        );
      }

      // One atomic write: the review, and the service's rating counters.
      //
      // Security rules bind them together — the counter increment must match
      // the rating in the review being created in this very batch, and the
      // review must not already exist. That is what lets the totals live on
      // the service document without a trusted server to maintain them, and
      // it means a marketplace page needs no extra reads to show a score.
      final batch = _firestore.batch();
      batch.set(reviewRef, {
        'orderId': order.id,
        'serviceId': order.serviceId,
        'reviewerId': order.clientId,
        'revieweeId': order.freelancerId,
        'rating': rating,
        'comment': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(serviceRef, {
        'ratingSum': FieldValue.increment(rating),
        'ratingCount': FieldValue.increment(1),
        'lastReviewId': order.id,
      });
      await batch.commit();

      try {
        await NotificationRepository(_firestore).create(
          toUid: order.freelancerId,
          type: AppNotificationType.reviewReceived,
          title: 'You received a new review',
          orderId: order.id,
        );
      } on AppFailure {
        // Notification failures never roll back a legitimate review.
      }
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Rating for one service, read straight off its counters.
  ///
  /// Previously an aggregate query over every review of the service, run once
  /// per detail view. The counters are maintained atomically by
  /// [submitReview] and guarded by rules, so this is now a single document
  /// read — and the marketplace needs none at all, because the service
  /// documents it already loaded carry the totals.
  Future<ServiceRating> ratingOf(String serviceId) async {
    try {
      final snapshot = await _firestore
          .doc('${FirestorePaths.services}/$serviceId')
          .get();
      if (!snapshot.exists) return const ServiceRating(average: 0, count: 0);
      final service = FreelanceService.fromFirestore(snapshot);
      return ServiceRating(
        average: service.averageRating,
        count: service.ratingCount,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Stream<List<ReviewSummary>> watchForUser(
    String revieweeId, {
    int limit = 20,
  }) {
    return _watchByField('revieweeId', revieweeId, limit);
  }

  Stream<List<ReviewSummary>> watchForService(
    String serviceId, {
    int limit = 20,
  }) {
    return _watchByField('serviceId', serviceId, limit);
  }

  Stream<List<ReviewSummary>> _watchByField(
    String field,
    String value,
    int limit,
  ) {
    return _firestore
        .collection(FirestorePaths.reviews)
        .where(field, isEqualTo: value)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map(ReviewSummary.fromFirestore).toList(),
        );
  }

  static const pageSize = 20;

  /// One page of reviews for a service or a seller, sorted and optionally
  /// narrowed to one star rating, with the cursor to continue from.
  ///
  /// Every sort × filter shape has a composite index in
  /// `firestore.indexes.json`; the emulator does not enforce them, so a new
  /// shape here needs an entry there before it works in production.
  Future<ReviewPage> fetchReviews({
    required ReviewTarget target,
    ReviewSort sort = ReviewSort.newest,
    int? rating,
    DocumentSnapshot? startAfter,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _firestore
          .collection(FirestorePaths.reviews)
          .where(target.field, isEqualTo: target.id);
      if (rating != null) query = query.where('rating', isEqualTo: rating);
      query = switch (sort) {
        ReviewSort.newest => query.orderBy('createdAt', descending: true),
        ReviewSort.highest =>
          query
              .orderBy('rating', descending: true)
              .orderBy('createdAt', descending: true),
        ReviewSort.lowest =>
          query.orderBy('rating').orderBy('createdAt', descending: true),
      };
      if (startAfter != null) query = query.startAfterDocument(startAfter);
      final snapshot = await query.limit(pageSize).get();
      return ReviewPage(
        items: snapshot.docs.map(ReviewSummary.fromFirestore).toList(),
        lastDocument: snapshot.docs.isEmpty ? null : snapshot.docs.last,
        exhausted: snapshot.docs.length < pageSize,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// How many reviews of each star a service or seller has, 5 down to 1.
  /// Five count aggregates: the cost does not grow with the review count.
  Future<RatingDistribution> distributionOf(ReviewTarget target) async {
    try {
      final counts = await Future.wait([
        for (var stars = 5; stars >= 1; stars--)
          _firestore
              .collection(FirestorePaths.reviews)
              .where(target.field, isEqualTo: target.id)
              .where('rating', isEqualTo: stars)
              .count()
              .get()
              .then((s) => s.count ?? 0),
      ]);
      return RatingDistribution(counts);
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }
}

/// Which collection of reviews: a listing's, or everything a seller earned.
class ReviewTarget {
  const ReviewTarget.service(this.id) : field = 'serviceId';
  const ReviewTarget.seller(this.id) : field = 'revieweeId';

  final String field;
  final String id;

  bool get isService => field == 'serviceId';
}

enum ReviewSort {
  newest('Newest'),
  highest('Highest rated'),
  lowest('Lowest rated');

  const ReviewSort(this.label);

  final String label;
}

class ReviewPage {
  const ReviewPage({
    required this.items,
    required this.lastDocument,
    required this.exhausted,
  });

  final List<ReviewSummary> items;
  final DocumentSnapshot? lastDocument;
  final bool exhausted;
}

/// Counts per star, index 0 = five stars … index 4 = one star.
class RatingDistribution {
  const RatingDistribution(this.counts);

  static const empty = RatingDistribution([0, 0, 0, 0, 0]);

  final List<int> counts;

  int get total => counts.fold(0, (a, b) => a + b);

  int countOf(int stars) => counts[5 - stars];

  double shareOf(int stars) => total == 0 ? 0 : countOf(stars) / total;

  double get average => total == 0
      ? 0
      : [for (var s = 5; s >= 1; s--) s * countOf(s)].fold(0, (a, b) => a + b) /
            total;
}

extension on OrderStatus {
  bool get isCompletedStatus => this == OrderStatus.completed;
}

class ServiceRating {
  const ServiceRating({required this.average, required this.count});

  final double average;
  final int count;
}

class ReviewSummary {
  const ReviewSummary({
    required this.id,
    required this.reviewerId,
    required this.rating,
    required this.comment,
    required this.createdAt,
    this.serviceId,
    this.revieweeId,
  });

  /// Equals the order id.
  final String id;
  final String reviewerId;
  final int rating;
  final String comment;
  final DateTime createdAt;
  final String? serviceId;
  final String? revieweeId;

  factory ReviewSummary.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return ReviewSummary.fromMap(doc.id, data);
  }

  factory ReviewSummary.fromMap(String id, Map<String, dynamic> data) {
    return ReviewSummary(
      id: id,
      reviewerId: data['reviewerId'] as String,
      rating: (data['rating'] as num?)?.toInt() ?? 0,
      comment: data['comment'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      serviceId: data['serviceId'] as String?,
      revieweeId: data['revieweeId'] as String?,
    );
  }
}
