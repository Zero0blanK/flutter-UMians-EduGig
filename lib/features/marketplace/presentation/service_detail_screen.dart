import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/platform/platform_repository.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/rating.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../admin/domain/admin_access.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../chat/presentation/open_chat.dart';
import '../../reviews/data/review_repository.dart';
import '../../reviews/presentation/review_overview.dart';
import '../../services/data/service_repository.dart';
import '../../services/domain/freelance_service.dart';
import 'widgets/category_visuals.dart';
import 'widgets/service_card.dart';

/// A listing, laid out in the order a buyer decides: what it is and who
/// sells it, what it costs and how fast, what it includes, what others said.
///
/// The decision itself, order or message, never scrolls away: on a phone it
/// sits in a bar pinned to the bottom, on a wide window in a column on the
/// right. Reviews are an overview with a way to the full page, so the price
/// and the button are never buried under a list.
class ServiceDetailScreen extends StatefulWidget {
  const ServiceDetailScreen({super.key, required this.serviceId});

  final String serviceId;

  @override
  State<ServiceDetailScreen> createState() => _ServiceDetailScreenState();
}

class _ServiceDetailScreenState extends State<ServiceDetailScreen> {
  late Future<FreelanceService> _future;
  late final Stream<PlatformSettings> _settings = context
      .read<PlatformSettingsRepository>()
      .watch();

  @override
  void initState() {
    super.initState();
    _future = context.read<ServiceRepository>().fetchById(widget.serviceId);
  }

  void _reload() {
    setState(() {
      _future = context.read<ServiceRepository>().fetchById(widget.serviceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FreelanceService>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(appBar: AppBar(), body: const _DetailSkeleton());
        }
        if (snapshot.hasError) {
          final message = snapshot.error is AppFailure
              ? '${snapshot.error}'
              : null;
          return Scaffold(
            appBar: AppBar(),
            body: ErrorView(
              message: message ?? 'Something went wrong. Please try again.',
              onRetry: _reload,
            ),
          );
        }
        if (!snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyView(message: 'Service not found.'),
          );
        }
        return _ServiceDetail(service: snapshot.data!, settings: _settings);
      },
    );
  }
}

class _ServiceDetail extends StatelessWidget {
  const _ServiceDetail({required this.service, required this.settings});

  final FreelanceService service;
  final Stream<PlatformSettings> settings;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final isOwner = auth.uid == service.sellerId;
    final wide = Breakpoints.isWide(context);

    final action = StreamBuilder<PlatformSettings>(
      stream: settings,
      builder: (context, snapshot) => _ActionPanel(
        service: service,
        isOwner: isOwner,
        paused: snapshot.data?.ordersPaused ?? false,
        column: wide,
      ),
    );

    final body = CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 0,
          title: Text(
            service.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (isOwner)
              IconButton(
                tooltip: 'Edit listing',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => context.push('/service/${service.id}/edit'),
              ),
          ],
        ),
        SliverToBoxAdapter(child: _Header(service: service)),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, wide ? 32 : 24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Facts(service: service),
                const SectionHeader('About this service'),
                LilyPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        service.description,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (service.skills.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final skill in service.skills)
                              Chip(label: Text(skill)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SectionHeader('How ordering works'),
                _HowItWorks(service: service),
                ReviewOverview(
                  target: ReviewTarget.service(service.id),
                  average: service.averageRating,
                  count: service.ratingCount,
                ),
              ],
            ),
          ),
        ),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: body),
            SizedBox(
              width: 340,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 72, 24, 24),
                  child: action,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(body: body, bottomNavigationBar: action);
  }
}

/// Category colour, title, seller, and the score. The category tint sits
/// behind the header at low opacity: the marketplace card's colour bar,
/// opened up.
class _Header extends StatelessWidget {
  const _Header({required this.service});

  final FreelanceService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = categoryVisualOf(
      service.categoryId,
      brightness: theme.brightness,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            visual.tint.withValues(alpha: 0.14),
            visual.tint.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              CategoryTag(categoryId: service.categoryId),
              if (service.isFeatured)
                StatusPill(
                  label: 'Featured',
                  tone: Tone.attention,
                  icon: Icons.push_pin_rounded,
                  dense: true,
                ),
              if (!service.isPublished)
                StatusPill(
                  label: service.status.name,
                  tone: Tone.neutral,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(service.title, style: theme.textTheme.headlineMedium),
          const SizedBox(height: 14),
          Row(
            children: [
              UserAvatarFor(
                uid: service.sellerId,
                radius: 18,
                ring: visual.tint,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UserName(
                      uid: service.sellerId,
                      linkToProfile: true,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      categoryLabelOf(service.categoryId),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (service.hasRating)
                RatingLabel(
                  average: service.averageRating,
                  count: service.ratingCount,
                  size: 18,
                )
              else
                const StatusPill(
                  label: 'New seller',
                  tone: Tone.neutral,
                  dense: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.service});

  final FreelanceService service;

  @override
  Widget build(BuildContext context) {
    return StatGrid(
      minTile: 110,
      tiles: [
        StatTile(
          label: service.pricingMode == PricingMode.negotiable
              ? 'Starting from'
              : 'Price',
          value:
              '₱${NumberFormat.decimalPattern().format(service.startingPrice)}',
          icon: Icons.sell_outlined,
          emphasis: true,
          caption: service.pricingMode == PricingMode.negotiable
              ? 'agreed in chat'
              : null,
        ),
        StatTile(
          label: 'Delivery',
          value:
              '${service.deliveryDays} day${service.deliveryDays == 1 ? '' : 's'}',
          icon: Icons.schedule_rounded,
        ),
        StatTile(
          label: 'Revisions',
          value: '${service.revisionCount}',
          icon: Icons.replay_rounded,
        ),
      ],
    );
  }
}

/// The steps between here and a finished job, for this listing's path.
class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.service});

  final FreelanceService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = service.canOrderDirectly
        ? const [
            (Icons.shopping_bag_outlined, 'Order at the listed price'),
            (Icons.lock_outline_rounded, 'Pay in the app; the money is held'),
            (
              Icons.check_circle_outline_rounded,
              'Approve the delivery, funds release',
            ),
          ]
        : const [
            (Icons.forum_outlined, 'Message the seller about the job'),
            (Icons.local_offer_outlined, 'Accept the offer card they send'),
            (
              Icons.lock_outline_rounded,
              'Pay in the app; the money is held until you approve',
            ),
          ];
    return LilyPanel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!service.canOrderDirectly) ...[
            Text(
              service.pricingMode == PricingMode.negotiable
                  ? 'The price depends on the job.'
                  : 'The seller asks to discuss the job first.',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
          ],
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 10),
              child: Row(
                children: [
                  IconDisc(icon: steps[i].$1, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(steps[i].$2, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Price and the one thing to do next. A bottom bar on phones, a panel in
/// the side column on wide windows.
class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.service,
    required this.isOwner,
    required this.paused,
    required this.column,
  });

  final FreelanceService service;
  final bool isOwner;
  final bool paused;
  final bool column;

  Future<void> _message(BuildContext context) =>
      openChatWith(context, service.sellerId, serviceId: service.id);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final price = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          service.pricingMode == PricingMode.negotiable
              ? 'Starting from'
              : 'Price',
          style: theme.textTheme.labelMedium,
        ),
        Text(
          '₱${NumberFormat.decimalPattern().format(service.startingPrice)}',
          style: AppTheme.price(context, size: column ? 28 : 22),
        ),
      ],
    );

    final Widget primary;
    Widget? secondary;
    String? note;
    if (isOwner) {
      primary = FilledButton.icon(
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Edit listing'),
        onPressed: () => context.push('/service/${service.id}/edit'),
      );
    } else if (!service.isPublished) {
      primary = const FilledButton(
        onPressed: null,
        child: Text('Not available'),
      );
      note = 'This service is ${service.status.name} and not accepting orders.';
    } else if (service.canOrderDirectly) {
      // The rules refuse new orders while paused; the button says so instead
      // of failing.
      primary = FilledButton.icon(
        icon: const Icon(Icons.shopping_bag_outlined),
        label: Text(paused ? 'Ordering is paused' : 'Order now'),
        onPressed: paused
            ? null
            : () => context.push('/order/new/${service.id}'),
      );
      secondary = column
          ? OutlinedButton.icon(
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('Message seller'),
              onPressed: () => _message(context),
            )
          : IconButton.outlined(
              tooltip: 'Message seller',
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              onPressed: () => _message(context),
            );
    } else {
      // The only path is chat, then an offer card. The rules refuse a direct
      // order for this listing as well.
      primary = FilledButton.icon(
        icon: const Icon(Icons.forum_outlined),
        label: const Text('Message to get an offer'),
        onPressed: () => _message(context),
      );
    }

    if (column) {
      return LilyPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            price,
            const SizedBox(height: 16),
            primary,
            if (secondary != null) ...[const SizedBox(height: 8), secondary],
            if (note != null) ...[
              const SizedBox(height: 10),
              Text(note, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      );
    }

    return StickyActionBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              price,
              const SizedBox(width: 12),
              if (secondary != null) ...[secondary, const SizedBox(width: 8)],
              Expanded(child: primary),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(note, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(height: 22, width: 110, radius: 999),
          SizedBox(height: 14),
          SkeletonBox(height: 30, width: 260),
          SizedBox(height: 8),
          SkeletonBox(height: 30, width: 180),
          SizedBox(height: 18),
          SkeletonBox(height: 40, width: 200, radius: 20),
          SizedBox(height: 24),
          SkeletonBox(height: 80, radius: 16),
          SizedBox(height: 24),
          SkeletonBox(height: 160, radius: 28),
        ],
      ),
    );
  }
}
