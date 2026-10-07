import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

/// Five stars, filled to [rating].
///
/// The star gold was written out as a raw hex in two screens, which drifted
/// from the one used on the marketplace cards. It lives in
/// [AppTheme.rating] now so all three agree and both themes are handled.
class RatingStars extends StatelessWidget {
  const RatingStars({super.key, required this.rating, this.size = 14});

  final int rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    final gold = AppTheme.rating(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            i < rating ? Icons.star_rounded : Icons.star_outline_rounded,
            size: size,
            color: i < rating ? gold : Theme.of(context).colorScheme.outline,
          ),
      ],
    );
  }
}

/// An average and how many reviews it rests on: `★ 4.8 (12)`.
///
/// The count is not decoration — a 5.0 from one client and a 4.8 from forty
/// are different claims, and the summary that showed only the average asked
/// the reader to take the first as seriously as the second.
class RatingLabel extends StatelessWidget {
  const RatingLabel({
    super.key,
    required this.average,
    required this.count,
    this.size = 15,
  });

  final double average;
  final int count;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: size, color: AppTheme.rating(context)),
        const SizedBox(width: 3),
        Text(
          average.toStringAsFixed(1),
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        Text(' ($count)', style: theme.textTheme.bodySmall),
      ],
    );
  }
}
