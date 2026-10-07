import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../data/review_repository.dart';
import 'review_tile.dart';

/// Every review of a service or a student, on a page of its own.
///
/// The breakdown at the top doubles as the filter: tap a bar (or a chip) to
/// see only that star. Sort is newest, highest, lowest. Pages of twenty load
/// as the reader scrolls; the distribution is five count aggregates, so the
/// page costs the same for ten reviews as for ten thousand.
class ReviewsScreen extends StatefulWidget {
  const ReviewsScreen({super.key, required this.target, this.title});

  final ReviewTarget target;
  final String? title;

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  final _scroll = ScrollController();
  late Future<RatingDistribution> _distribution;

  ReviewSort _sort = ReviewSort.newest;
  int? _stars;

  final _items = <ReviewSummary>[];
  ReviewPage? _last;
  bool _loading = false;
  AppFailure? _failure;

  /// Bumped on every sort/filter change so a page that comes back for an
  /// older query is dropped instead of appended to the new list.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _distribution = context.read<ReviewRepository>().distributionOf(
      widget.target,
    );
    _scroll.addListener(_onScroll);
    _loadMore();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  void _restart({ReviewSort? sort, int? stars, bool clearStars = false}) {
    setState(() {
      _sort = sort ?? _sort;
      if (clearStars) {
        _stars = null;
      } else if (stars != null) {
        _stars = stars;
      }
      _generation++;
      _items.clear();
      _last = null;
      _failure = null;
      _loading = false;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || (_last?.exhausted ?? false) || _failure != null) return;
    final generation = _generation;
    setState(() => _loading = true);
    try {
      final page = await context.read<ReviewRepository>().fetchReviews(
        target: widget.target,
        sort: _sort,
        rating: _stars,
        startAfter: _last?.lastDocument,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _last = page;
        _loading = false;
      });
    } on AppFailure catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failure = failure;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exhausted = _last?.exhausted ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? 'Reviews')),
      body: ContentWidth(
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(
                child: FutureBuilder<RatingDistribution>(
                  future: _distribution,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return ErrorView(
                        message: 'Could not load the rating breakdown.',
                        onRetry: () => setState(() {
                          _distribution = context
                              .read<ReviewRepository>()
                              .distributionOf(widget.target);
                        }),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const SkeletonBox(height: 120, radius: 20);
                    }
                    return LilyPanel(
                      child: RatingBreakdown(
                        distribution: snapshot.data!,
                        selected: _stars,
                        onSelect: (stars) => stars == null
                            ? _restart(clearStars: true)
                            : _restart(stars: stars),
                      ),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: ChipStrip(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  for (final sort in ReviewSort.values)
                    ChoiceChip(
                      label: Text(sort.label),
                      selected: _sort == sort,
                      onSelected: (_) => _restart(sort: sort),
                    ),
                  if (_stars != null)
                    InputChip(
                      avatar: const Icon(Icons.star_rounded, size: 16),
                      label: Text('$_stars star${_stars == 1 ? '' : 's'}'),
                      selected: true,
                      onDeleted: () => _restart(clearStars: true),
                    ),
                ],
              ),
            ),
            if (_failure != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorView(
                  message: _failure!.message,
                  onRetry: () => _restart(),
                ),
              )
            else if (_items.isEmpty && exhausted)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(
                  icon: Icons.reviews_outlined,
                  title: _stars == null
                      ? 'No reviews yet'
                      : 'No $_stars-star reviews',
                  message: _stars == null
                      ? 'Reviews appear here once an order is completed.'
                      : 'Clear the filter to see every review.',
                  actionLabel: _stars == null ? null : 'Clear filter',
                  onAction: _stars == null
                      ? null
                      : () => _restart(clearStars: true),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                sliver: SliverList.separated(
                  itemCount: _items.length + (exhausted ? 0 : 1),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    if (index >= _items.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                        ),
                      );
                    }
                    return ReviewTile(review: _items[index]);
                  },
                ),
              ),
            if (_items.isNotEmpty && exhausted)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Text(
                    'That is every review.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
