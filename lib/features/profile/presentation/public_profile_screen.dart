import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../../core/widgets/verified_badge.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../chat/presentation/open_chat.dart';
import '../../marketplace/presentation/widgets/service_card.dart';
import '../../reviews/data/review_repository.dart';
import '../../reviews/presentation/review_overview.dart';
import '../../services/data/service_repository.dart';
import '../../services/domain/freelance_service.dart';

/// Another student's public page: who they are, what others said about
/// them, what they offer. Everything here is already readable by signed-in
/// students under the rules; the screen gathers it.
class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key, required this.uid});

  final String uid;

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  late Future<UserProfile> _profile;
  late Stream<List<FreelanceService>> _services;
  int _listLimit = 20;
  bool _loadingMore = false;
  bool _hasMore = false;

  void _loadMore() {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _listLimit += 20;
      _loadingMore = true;
      _loadServices();
    });
  }

  void _loadServices() {
    _services = context
        .read<ServiceRepository>()
        .watchPublishedBySeller(widget.uid, limit: _listLimit)
        .map((items) {
          if (mounted && _loadingMore) setState(() => _loadingMore = false);
          _hasMore = items.length >= _listLimit;
          return items;
        });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _profile = context.read<AuthRepository>().loadProfile(widget.uid);
    _loadServices();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().uid;
    final isMe = me == widget.uid;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification.metrics.extentAfter < 300) {
          _loadMore();
        }
        return false;
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: FutureBuilder<UserProfile>(
          future: _profile,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _Plain(
                child: ErrorView(
                  message: snapshot.error is NotFoundFailure
                      ? 'This student no longer has a profile.'
                      : 'Could not load this profile.',
                  onRetry: () => setState(_load),
                ),
              );
            }
            if (!snapshot.hasData) return const _Plain(child: LoadingView());
            final profile = snapshot.data!;

            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: PageHero(
                    padding: const EdgeInsets.fromLTRB(
                      20,
                      kToolbarHeight + 4,
                      20,
                      28,
                    ),
                    child: ContentWidth(
                      child: _HeroHeader(
                        profile: profile,
                        onMessage: isMe ? null : () => _message(context),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: ContentWidth(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (profile.bio.isNotEmpty ||
                              profile.skills.isNotEmpty) ...[
                            const SectionHeader('About'),
                            LilyPanel(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (profile.bio.isNotEmpty)
                                    Text(
                                      profile.bio,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium,
                                    ),
                                  if (profile.skills.isNotEmpty) ...[
                                    if (profile.bio.isNotEmpty)
                                      const SizedBox(height: 12),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        for (final skill in profile.skills.take(
                                          8,
                                        ))
                                          Chip(label: Text(skill)),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                          ReviewOverview(
                            target: ReviewTarget.seller(widget.uid),
                          ),
                          SectionHeader(
                            isMe ? 'Your listings' : 'What they offer',
                          ),
                          _ServicesBlock(
                            services: _services,
                            isMe: isMe,
                            limit: _listLimit,
                            loadingMore: _loadingMore,
                            onLoadMore: _loadMore,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _message(BuildContext context) =>
      openChatWith(context, widget.uid);
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({required this.profile, this.onMessage});

  final UserProfile profile;
  final VoidCallback? onMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.6),
                  width: 2,
                ),
              ),
              child: UserAvatar(
                name: profile.displayName,
                radius: 30,
                photoUrl: profile.photoUrl,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(profile.displayName, style: OnHero.title),
                      ),
                      if (profile.hasVerifiedBadge) ...[
                        const SizedBox(width: 8),
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: VerifiedBadge(size: 22),
                        ),
                      ],
                    ],
                  ),
                  if (profile.publicRole == 'Admin' ||
                      profile.publicRole == 'Moderator') ...[
                    const SizedBox(height: 6),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: Text(
                          profile.publicRole!,
                          style: OnHero.subtitle,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  if (profile.email?.isNotEmpty == true) ...[
                    SelectableText(profile.email!, style: OnHero.subtitle),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (profile.program?.isNotEmpty == true)
                        Text(
                          'Program: ${profile.program}',
                          style: OnHero.subtitle,
                        ),
                      if (profile.college != null)
                        Text(
                          'Department: ${profile.college!.name}',
                          style: OnHero.subtitle,
                        ),
                      Text(
                        'Joined ${DateFormat.yMMMM().format(profile.createdAt)}',
                        style: OnHero.subtitle,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (onMessage != null) ...[
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: Text('Message ${profile.displayName.split(' ').first}'),
            onPressed: onMessage,
          ),
        ],
      ],
    );
  }
}

/// The hero is white-on-red; a state view under a transparent app bar needs
/// the ordinary ground and an ordinary bar, so give it a plain one.
class _Plain extends StatelessWidget {
  const _Plain({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppBar(),
        Expanded(child: child),
      ],
    );
  }
}

class _ServicesBlock extends StatelessWidget {
  const _ServicesBlock({
    required this.services,
    required this.isMe,
    required this.limit,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final Stream<List<FreelanceService>> services;
  final bool isMe;
  final int limit;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<FreelanceService>>(
      stream: services,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text(
            'Could not load listings.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        if (!snapshot.hasData) {
          return const SkeletonList(
            count: 2,
            height: 120,
            padding: EdgeInsets.zero,
          );
        }
        final items = snapshot.data!;
        if (items.isEmpty) {
          return Text(
            isMe
                ? 'You have nothing published yet.'
                : 'Nothing published right now.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final service in items)
              ServiceCard(
                service: service,
                margin: const EdgeInsets.only(bottom: 10),
                showSeller: false,
                featured: service.isFeatured,
              ),
            if (items.length >= limit || loadingMore)
              TextButton(
                onPressed: loadingMore ? null : onLoadMore,
                child: Text(loadingMore ? 'Loading?' : 'Load more listings'),
              ),
          ],
        );
      },
    );
  }
}
