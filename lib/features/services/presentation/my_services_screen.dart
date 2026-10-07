import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/paginated_list.dart';
import '../../../core/widgets/rating.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../marketplace/presentation/widgets/service_card.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../../pro/data/pro_repository.dart';
import '../../pro/domain/pro_policy.dart';
import '../../services/data/service_repository.dart';
import '../../services/domain/freelance_service.dart';

/// A seller's listings. Live ones first, then paused, drafts and archived,
/// each with the number that matters (rating, price, delivery) and the
/// actions that apply to its state. The count line at the top says how many
/// are live and how many featured slots are used.
class MyServicesScreen extends StatefulWidget {
  const MyServicesScreen({
    super.key,
    required this.repository,
    required this.sellerId,
  });

  final ServiceRepository repository;
  final String sellerId;

  @override
  State<MyServicesScreen> createState() => _MyServicesScreenState();
}

class _MyServicesScreenState extends State<MyServicesScreen> {
  /// Held rather than rebuilt in `build`: a fresh stream object each rebuild
  /// tears down and re-establishes the Firestore listener.
  late final Future<EarningsSummary> _earnings;

  @override
  void initState() {
    super.initState();
    _earnings = context.read<PaymentRepository>().earningsOf(widget.sellerId);
  }

  static int _rank(ServiceStatus status) => switch (status) {
    ServiceStatus.published => 0,
    ServiceStatus.paused => 1,
    ServiceStatus.draft => 2,
    ServiceStatus.archived => 3,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPro = context.watch<AuthController>().profile?.isPro ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('My services')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/service/new'),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New service'),
      ),
      body: ContentWidth(
        child: PaginatedList<FreelanceService>(
          load: (limit) => widget.repository
              .watchMine(widget.sellerId, limit: limit)
              .map(
                (items) => [...items]
                  ..sort((a, b) => _rank(a.status).compareTo(_rank(b.status))),
              ),
          emptyMessage: 'No services yet. Create a listing to get started.',
          headerBuilder: (context, services) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${services.where((s) => s.isPublished).length} live of ${services.length}'
                '${isPro ? ' ? ${services.where((s) => s.isFeatured).length} of ${ProPolicy.featuredPerSeller} featured' : ''}',
                style: theme.textTheme.labelMedium,
              ),
              const SectionHeader(
                'Sales overview',
                subtitle: 'All-time settled payments for services you sold.',
              ),
              _SellerSalesOverview(future: _earnings),
              const SectionHeader('Your listings'),
            ],
          ),
          itemBuilder: (context, service) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MyServiceCard(
              service: service,
              onAction: (action) => _onAction(context, service, action),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    FreelanceService service,
    String action,
  ) async {
    try {
      switch (action) {
        case 'view':
          if (context.mounted) context.push('/service/${service.id}');
        case 'edit':
          if (context.mounted) context.push('/service/${service.id}/edit');
        case 'publish':
          // Rules refuse this for minors; saying why here is kinder than
          // "You are not allowed to do that".
          if (!(context.read<AuthController>().profile?.isAdult ?? false)) {
            throw const InvalidInputFailure(
              'Selling is open to students aged 18 and over. Add your birth '
              'date in Edit profile if it is missing.',
            );
          }
          await widget.repository.setStatus(
            serviceId: service.id,
            status: ServiceStatus.published,
          );
        case 'pause':
          await widget.repository.setStatus(
            serviceId: service.id,
            status: ServiceStatus.paused,
          );
        case 'archive':
          await widget.repository.setStatus(
            serviceId: service.id,
            status: ServiceStatus.archived,
          );
        case 'feature' || 'unfeature':
          await context.read<ProRepository>().setFeatured(
            serviceId: service.id,
            featured: action == 'feature',
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  action == 'feature'
                      ? 'Pinned above the marketplace for the rest of your '
                            'Pro month.'
                      : 'No longer featured.',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
      }
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }
}

/// Financial summary scoped to the signed-in seller's own settled payments.
/// The aggregate comes from immutable payment records rather than a mutable
/// profile total, so it cannot accidentally include other students' sales.
class _SellerSalesOverview extends StatelessWidget {
  const _SellerSalesOverview({required this.future});

  final Future<EarningsSummary> future;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<EarningsSummary>(
      future: future,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const SkeletonBox(height: 184, radius: 16);
        }
        final sales = snapshot.data ?? EarningsSummary.empty;
        return LilyPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatGrid(
                minTile: 145,
                tiles: [
                  StatTile(
                    label: 'Net earnings',
                    value: pesos(sales.net),
                    caption: 'Gross sales less commission',
                    icon: Icons.savings_outlined,
                    emphasis: true,
                  ),
                  StatTile(
                    label: 'Gross service sales',
                    value: pesos(sales.gross),
                    caption: 'Amount paid by clients',
                    icon: Icons.payments_outlined,
                  ),
                  StatTile(
                    label: 'Platform commission',
                    value: pesos(sales.commission),
                    caption: 'Deducted from gross sales',
                    icon: Icons.percent_rounded,
                  ),
                  StatTile(
                    label: 'Paid orders',
                    value: '${sales.orderCount}',
                    caption: 'Settled payment records',
                    icon: Icons.receipt_long_outlined,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                snapshot.hasError
                    ? 'Could not load your sales overview right now.'
                    : sales.orderCount == 0
                    ? 'Your sales appear here after a client has paid for one of your services.'
                    : 'Gross service sales = platform commission + your net earnings. '
                          'Use Wallet to see payout and release activity.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => context.push('/wallet'),
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: const Text('Open wallet'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MyServiceCard extends StatelessWidget {
  const _MyServiceCard({required this.service, required this.onAction});

  final FreelanceService service;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final live = service.isPublished;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onAction('edit'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CategoryDisc(categoryId: service.categoryId, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          service.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _ServiceStatusPill(status: service.status),
                            if (service.isFeatured)
                              const StatusPill(
                                label: 'Featured',
                                tone: Tone.attention,
                                icon: Icons.push_pin_rounded,
                                dense: true,
                              ),
                            if (service.pricingMode == PricingMode.negotiable)
                              const StatusPill(
                                label: 'Negotiable',
                                tone: Tone.neutral,
                                dense: true,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Actions',
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'view',
                        child: ListTile(
                          leading: Icon(Icons.visibility_outlined),
                          title: Text('View as buyer'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit'),
                        ),
                      ),
                      if (!live)
                        const PopupMenuItem(
                          value: 'publish',
                          child: ListTile(
                            leading: Icon(Icons.publish_outlined),
                            title: Text('Publish'),
                          ),
                        ),
                      if (live)
                        const PopupMenuItem(
                          value: 'pause',
                          child: ListTile(
                            leading: Icon(Icons.pause_circle_outline_rounded),
                            title: Text('Pause'),
                          ),
                        ),
                      // Pro only, and the backend says so if it is not; the
                      // menu offers it so a seller learns the feature exists.
                      if (live)
                        PopupMenuItem(
                          value: service.isFeatured ? 'unfeature' : 'feature',
                          child: ListTile(
                            leading: Icon(
                              service.isFeatured
                                  ? Icons.push_pin_outlined
                                  : Icons.push_pin_rounded,
                            ),
                            title: Text(
                              service.isFeatured
                                  ? 'Stop featuring'
                                  : 'Feature this listing (Pro)',
                            ),
                          ),
                        ),
                      if (service.status != ServiceStatus.archived)
                        const PopupMenuItem(
                          value: 'archive',
                          child: ListTile(
                            leading: Icon(Icons.archive_outlined),
                            title: Text('Archive'),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${service.priceQualifier.isEmpty ? '' : 'from '}₱${NumberFormat.decimalPattern().format(service.startingPrice)}',
                          style: AppTheme.price(context, size: 16),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.schedule_rounded,
                              size: 13,
                              color: scheme.outline,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '${service.deliveryDays}d',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        if (service.hasRating)
                          RatingLabel(
                            average: service.averageRating,
                            count: service.ratingCount,
                            size: 14,
                          )
                        else
                          Text(
                            'No reviews yet',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (!live)
                    TextButton(
                      onPressed: () => onAction('publish'),
                      child: const Text('Publish'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Listing-state pill: green when live, quiet otherwise.
class _ServiceStatusPill extends StatelessWidget {
  const _ServiceStatusPill({required this.status});

  final ServiceStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = switch (status) {
      ServiceStatus.draft => ('Draft', Tone.neutral, Icons.edit_note_rounded),
      ServiceStatus.published => (
        'Live',
        Tone.success,
        Icons.check_circle_rounded,
      ),
      ServiceStatus.paused => (
        'Paused',
        Tone.attention,
        Icons.pause_circle_filled_rounded,
      ),
      ServiceStatus.archived => (
        'Archived',
        Tone.neutral,
        Icons.archive_rounded,
      ),
    };
    return StatusPill(label: label, tone: tone, icon: icon, dense: true);
  }
}
