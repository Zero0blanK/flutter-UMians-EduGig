import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../app/theme/app_theme.dart';
import '../../../../core/constants/firestore_paths.dart';
import '../../../../core/widgets/lily.dart';
import '../../../../core/widgets/user_name.dart';
import '../../../services/domain/freelance_service.dart';
import 'category_visuals.dart';

/// A listing. Answers, in the order a student asks: what is it, who is
/// selling, are they any good, and what does it cost.
///
/// A neutral bar on the left edge gives listings a consistent visual anchor;
/// the seller's initial sits in the same colour. Price uses neutral ink and
/// tabular figures so a column of cards lines up. A featured card wears a
/// pin and a lily-tinted border, and says so.
class ServiceCard extends StatelessWidget {
  const ServiceCard({
    super.key,
    required this.service,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 10),
    this.showSeller = true,
    this.featured = false,
    this.compact = false,
  });

  final FreelanceService service;
  final EdgeInsets margin;
  final bool showSeller;
  final bool featured;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = categoryVisualOf(
      service.categoryId,
      brightness: theme.brightness,
    );

    if (compact) {
      return _CompactServiceCard(
        service: service,
        margin: margin,
        featured: featured,
        visual: visual,
      );
    }

    return Padding(
      padding: margin,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          side: featured
              ? BorderSide(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                )
              : theme.brightness == Brightness.dark
              ? BorderSide(color: theme.colorScheme.outlineVariant)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: () => context.push('/service/${service.id}'),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 5, color: visual.tint),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _Tag(
                              label: categoryLabelOf(service.categoryId),
                              icon: visual.icon,
                              tint: visual.tint,
                            ),
                            if (featured) ...[
                              _Tag(
                                label: 'Featured',
                                icon: Icons.push_pin_rounded,
                                tint: theme.colorScheme.primary,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight:
                                      44 *
                                      MediaQuery.textScalerOf(context)
                                          .scale(16) /
                                      16,
                                ),
                                child: Text(
                                  service.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    service.pricingMode ==
                                            PricingMode.negotiable
                                        ? 'from'
                                        : 'price',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                  Text(
                                    '₱${NumberFormat.decimalPattern().format(service.startingPrice)}',
                                    style: AppTheme.price(context, size: 18),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (showSeller) ...[
                                    Row(
                                      children: [
                                        UserAvatarFor(
                                          uid: service.sellerId,
                                          radius: 12,
                                          ring: visual.tint,
                                        ),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: UserName(
                                            uid: service.sellerId,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: theme
                                                      .colorScheme
                                                      .onSurface,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                  ],
                                  Row(
                                    children: [
                                      if (service.hasRating) ...[
                                        Icon(
                                          Icons.star_rounded,
                                          size: 15,
                                          color: AppTheme.rating(context),
                                        ),
                                        const SizedBox(width: 2),
                                        Flexible(
                                          child: Text(
                                            '${service.averageRating.toStringAsFixed(1)} (${service.ratingCount})',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                  color: theme
                                                      .colorScheme
                                                      .onSurface,
                                                ),
                                          ),
                                        ),
                                      ] else
                                        Text(
                                          'New',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            _DeliveryDuration(days: service.deliveryDays),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactServiceCard extends StatelessWidget {
  const _CompactServiceCard({
    required this.service,
    required this.margin,
    required this.featured,
    required this.visual,
  });

  final FreelanceService service;
  final EdgeInsets margin;
  final bool featured;
  final ({IconData icon, Color tint}) visual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: margin,
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          side: featured
              ? BorderSide(
                  color: theme.colorScheme.primary.withValues(alpha: 0.35),
                )
              : theme.brightness == Brightness.dark
              ? BorderSide(color: theme.colorScheme.outlineVariant)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: () => context.push('/service/${service.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(visual.icon, size: 16, color: visual.tint),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        categoryLabelOf(service.categoryId),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: visual.tint,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (featured)
                      Icon(
                        Icons.push_pin_rounded,
                        size: 15,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  service.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        service.pricingMode == PricingMode.negotiable
                            ? 'From ${_peso(service.startingPrice)}'
                            : _peso(service.startingPrice),
                        style: AppTheme.price(context, size: 16),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: _DeliveryDuration(days: service.deliveryDays),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    UserAvatarFor(
                      uid: service.sellerId,
                      radius: 10,
                      ring: visual.tint,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: UserName(
                        uid: service.sellerId,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeliveryDuration extends StatelessWidget {
  const _DeliveryDuration({required this.days});

  final int days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = '$days ${days == 1 ? 'day' : 'days'}';
    return Semantics(
      label: 'Delivery in $label',
      child: SizedBox(
        width: 20 + MediaQuery.textScalerOf(context).scale(56),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _peso(int amount) => '₱${NumberFormat.decimalPattern().format(amount)}';

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.icon, required this.tint});

  final String label;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tint),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: tint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kept for callers that need the tag outside a card.
class CategoryTag extends StatelessWidget {
  const CategoryTag({super.key, required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context) {
    final visual = categoryVisualOf(
      categoryId,
      brightness: Theme.of(context).brightness,
    );
    return _Tag(
      label: categoryLabelOf(categoryId),
      icon: visual.icon,
      tint: visual.tint,
    );
  }
}

/// A tinted disc holding a category's icon, for headers.
class CategoryDisc extends StatelessWidget {
  const CategoryDisc({super.key, required this.categoryId, this.size = 44});

  final String categoryId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visual = categoryVisualOf(
      categoryId,
      brightness: Theme.of(context).brightness,
    );
    return IconDisc(icon: visual.icon, tint: visual.tint, size: size);
  }
}
