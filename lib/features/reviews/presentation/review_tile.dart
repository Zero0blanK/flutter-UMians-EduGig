import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/rating.dart';
import '../../../core/widgets/user_name.dart';
import '../data/review_repository.dart';

/// One review: who said it, how many stars, when, and the words.
///
/// The reviewer is named and linked. A review carried a reviewerId but was
/// shown anonymously before, which weakened the one trust signal it exists
/// to provide.
class ReviewTile extends StatelessWidget {
  const ReviewTile({super.key, required this.review, this.compact = false});

  final ReviewSummary review;

  /// Trim the comment to three lines: for an overview that links to the
  /// full page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                UserAvatarFor(uid: review.reviewerId, radius: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UserName(
                        uid: review.reviewerId,
                        linkToProfile: true,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 1),
                      Text(
                        DateFormat.yMMMd().format(review.createdAt),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                RatingStars(rating: review.rating, size: 16),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              review.comment,
              maxLines: compact ? 3 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// The big number, the stars under it, and one bar per star.
///
/// [average] and [count] come from the denormalised counters when the caller
/// has them (a service document) and from the distribution otherwise.
class RatingBreakdown extends StatelessWidget {
  const RatingBreakdown({
    super.key,
    required this.distribution,
    this.average,
    this.count,
    this.selected,
    this.onSelect,
  });

  final RatingDistribution distribution;
  final double? average;
  final int? count;

  /// A star the reader has filtered to; its bar is highlighted.
  final int? selected;
  final ValueChanged<int?>? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = count ?? distribution.total;
    final avg = average ?? distribution.average;
    final gold = AppTheme.rating(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          children: [
            Text(
              total == 0 ? '–' : avg.toStringAsFixed(1),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            RatingStars(rating: avg.round(), size: 16),
            const SizedBox(height: 4),
            Text(
              '$total review${total == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(width: 22),
        Expanded(
          child: Column(
            children: [
              for (var stars = 5; stars >= 1; stars--)
                _Bar(
                  stars: stars,
                  share: distribution.shareOf(stars),
                  count: distribution.countOf(stars),
                  color: gold,
                  dimmed: selected != null && selected != stars,
                  onTap: onSelect == null
                      ? null
                      : () => onSelect!(selected == stars ? null : stars),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.stars,
    required this.share,
    required this.count,
    required this.color,
    required this.dimmed,
    this.onTap,
  });

  final int stars;
  final double share;
  final int count;
  final Color color;
  final bool dimmed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: dimmed ? 0.4 : 1,
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: Text(
                  '$stars',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.star_rounded, size: 12, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: share),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: value,
                      minHeight: 8,
                      color: color,
                      backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 28,
                child: Text(
                  '$count',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
