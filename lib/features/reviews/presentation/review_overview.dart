import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/lily.dart';
import '../../../core/widgets/rating.dart';
import '../data/review_repository.dart';
import 'review_tile.dart';

/// The concise reviews block on a service page or a student's profile:
/// the average, how many, the two latest, and the way to the full page.
///
/// The detail page used to carry the whole list, which pushed the price and
/// the order button below five reviews. The list lives on [ReviewsScreen]
/// now; this block only says enough to decide whether to go there.
class ReviewOverview extends StatefulWidget {
  const ReviewOverview({
    super.key,
    required this.target,
    this.average,
    this.count,
  });

  final ReviewTarget target;

  /// Known counters, when the caller already holds the document that carries
  /// them (a service). Null reads them from the distribution.
  final double? average;
  final int? count;

  @override
  State<ReviewOverview> createState() => _ReviewOverviewState();
}

class _ReviewOverviewState extends State<ReviewOverview> {
  late final Stream<List<ReviewSummary>> _latest;
  late final Future<RatingDistribution> _distribution;

  @override
  void initState() {
    super.initState();
    final repository = context.read<ReviewRepository>();
    _latest = widget.target.isService
        ? repository.watchForService(widget.target.id, limit: 2)
        : repository.watchForUser(widget.target.id, limit: 2);
    _distribution = repository.distributionOf(widget.target);
  }

  String get _route => widget.target.isService
      ? '/service/${widget.target.id}/reviews'
      : '/user/${widget.target.id}/reviews';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<RatingDistribution>(
      future: _distribution,
      builder: (context, distribution) {
        final dist = distribution.data ?? RatingDistribution.empty;
        final count = widget.count ?? dist.total;
        final average = widget.average ?? dist.average;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Reviews',
              actionLabel: count > 0 ? 'View all' : null,
              onAction: count > 0 ? () => context.push(_route) : null,
            ),
            if (count == 0)
              Text(
                'No reviews yet. The first completed order can leave one.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Row(
                children: [
                  Text(
                    average.toStringAsFixed(1),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RatingStars(rating: average.round(), size: 18),
                      Text(
                        'from $count review${count == 1 ? '' : 's'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (distribution.hasData) _MiniBars(distribution: dist),
                ],
              ),
              const SizedBox(height: 14),
              StreamBuilder<List<ReviewSummary>>(
                stream: _latest,
                builder: (context, snapshot) {
                  final items = snapshot.data;
                  if (items == null) {
                    return const SkeletonList(
                      count: 2,
                      height: 96,
                      padding: EdgeInsets.zero,
                    );
                  }
                  return Column(
                    children: [
                      for (final review in items) ...[
                        ReviewTile(review: review, compact: true),
                        const SizedBox(height: 8),
                      ],
                    ],
                  );
                },
              ),
              if (count > 2)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push(_route),
                    icon: const Icon(Icons.reviews_outlined, size: 18),
                    label: Text('View all $count reviews'),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Five thin bars, one per star, tall enough to read the shape of the
/// distribution at a glance and nothing more; the full breakdown is a tap
/// away.
class _MiniBars extends StatelessWidget {
  const _MiniBars({required this.distribution});

  final RatingDistribution distribution;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var stars = 5; stars >= 1; stars--)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$stars', style: theme.textTheme.labelSmall),
                const SizedBox(width: 4),
                SizedBox(
                  width: 64,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: distribution.shareOf(stars),
                      minHeight: 4,
                      color: theme.colorScheme.tertiary,
                      backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
