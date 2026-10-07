import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/appearance_card.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/verified_badge.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../admin/data/admin_repository.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../../reviews/data/review_repository.dart';
import '../../wallet/data/wallet_repository.dart';
import '../../wallet/domain/wallet.dart';

/// The Me tab: who you are, three numbers, and the doors to everything
/// that is yours. Money, Pro and settings each have their own page now;
/// this one is a hub, not a scroll of cards.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Future<EarningsSummary>? _earnings;
  Future<RatingDistribution>? _ratings;
  Stream<Wallet>? _wallet;
  Future<bool>? _isAdmin;
  String? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // watch, not read: everything must reload if the signed-in user changes.
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _earnings = context.read<PaymentRepository>().earningsOf(uid);
      _ratings = context.read<ReviewRepository>().distributionOf(
        ReviewTarget.seller(uid),
      );
      _wallet = context.read<WalletRepository>().watchWallet(uid);
      _isAdmin = context.read<AdminRepository>().isAdmin(uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final profile = auth.profile;
    final uid = auth.uid;
    final theme = Theme.of(context);

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          PageHero(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: ContentWidth(
              child: Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: kToolbarHeight,
                      child: AppBar(
                        backgroundColor: Colors.transparent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        scrolledUnderElevation: 0,
                        automaticallyImplyLeading: false,
                        title: const Text('Profile'),
                        actions: [
                          const ThemeToggleButton(),
                          IconButton(
                            tooltip: 'Notifications',
                            icon: const Icon(Icons.notifications_outlined),
                            onPressed: () => context.push('/notifications'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _HeroHeader(profile: profile, fallbackName: uid ?? ''),
                ],
              ),
            ),
          ),
          ContentWidth(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_earnings != null && _ratings != null && _wallet != null)
                    _Stats(
                      earnings: _earnings!,
                      ratings: _ratings!,
                      wallet: _wallet!,
                    ),
                  const SectionHeader('Your work'),
                  LilyPanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Column(
                      children: [
                        NavTile(
                          icon: Icons.storefront_outlined,
                          title: 'My services',
                          subtitle: 'Create and manage what you sell',
                          tint: theme.colorScheme.primary,
                          onTap: () => context.push('/my-services'),
                        ),
                        NavTile(
                          icon: Icons.account_balance_wallet_outlined,
                          title: 'Wallet',
                          subtitle: 'Balance, payouts and activity',
                          tint: theme.colorScheme.secondary,
                          trailing: _wallet == null
                              ? null
                              : _WalletPeek(stream: _wallet!),
                          onTap: () => context.push('/wallet'),
                        ),
                        NavTile(
                          icon: Icons.receipt_long_outlined,
                          title: 'Transactions',
                          subtitle: 'Every payment sent, received or refunded',
                          tint: theme.colorScheme.secondary,
                          onTap: () => context.push('/transactions'),
                        ),
                        if (uid != null)
                          NavTile(
                            icon: Icons.reviews_outlined,
                            title: 'Reviews received',
                            subtitle: 'What clients said about your work',
                            tint: theme.colorScheme.tertiary,
                            onTap: () => context.push('/user/$uid/reviews'),
                          ),
                        NavTile(
                          icon: Icons.workspace_premium_outlined,
                          title: (profile?.isPro ?? false) ? 'Pro' : 'Get Pro',
                          subtitle: (profile?.isPro ?? false)
                              ? 'Active until ${DateFormat.yMMMd().format(profile!.proUntil!)}'
                              : 'Featured listings and the verified badge',
                          tint: theme.colorScheme.tertiary,
                          onTap: () => context.push('/pro'),
                        ),
                      ],
                    ),
                  ),
                  const SectionHeader('Account'),
                  LilyPanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Column(
                      children: [
                        NavTile(
                          icon: Icons.edit_outlined,
                          title: 'Edit profile',
                          subtitle: 'Name, bio, course and skills',
                          onTap: () => context.push('/profile/edit'),
                        ),
                        if (uid != null)
                          NavTile(
                            icon: Icons.badge_outlined,
                            title: 'My public profile',
                            subtitle: 'How classmates see you',
                            onTap: () => context.push('/user/$uid'),
                          ),
                        if (_isAdmin != null)
                          FutureBuilder<bool>(
                            future: _isAdmin,
                            builder: (context, snapshot) {
                              // The membership check is a convenience, not a
                              // control: rules refuse every console query
                              // for anyone without `admins/{uid}`.
                              if (snapshot.data != true) {
                                return const SizedBox.shrink();
                              }
                              return NavTile(
                                icon: Icons.shield_outlined,
                                title: 'Admin console',
                                subtitle:
                                    'Queues, users, listings and settings',
                                tint: theme.colorScheme.primary,
                                onTap: () => context.push('/admin'),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  const SectionHeader('Appearance'),
                  const AppearanceCard(),
                  const SizedBox(height: 24),
                  Center(
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text('Log out'),
                      onPressed: () => _confirmLogout(context, auth),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, AuthController auth) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You can sign back in with your UM Google account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await auth.signOut();
    } on AppFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }
}

/// Who you are, on the lily. The one place a student's own name is the
/// subject of the screen rather than a field in a row.
class _HeroHeader extends StatelessWidget {
  const _HeroHeader({required this.profile, required this.fallbackName});

  final UserProfile? profile;

  /// Shown before the profile document arrives, so the header never collapses.
  final String fallbackName;

  @override
  Widget build(BuildContext context) {
    final name = profile?.displayName ?? fallbackName;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final line = [if (profile?.email != null) profile!.email!].join(' · ');
    final academics = profile?.academics ?? '';

    return Row(
      children: [
        Container(
          width: 68,
          height: 68,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.6),
              width: 2,
            ),
            // The photo Google supplied at sign-in, when there is one.
            image: profile?.photoUrl == null
                ? null
                : DecorationImage(
                    image: NetworkImage(profile!.photoUrl!),
                    fit: BoxFit.cover,
                  ),
          ),
          child: profile?.photoUrl != null
              ? null
              : Text(
                  initial,
                  style: const TextStyle(
                    fontFamily: 'Bricolage',
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
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
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OnHero.title,
                    ),
                  ),
                  if (profile?.hasVerifiedBadge ?? false) ...[
                    const SizedBox(width: 8),
                    const VerifiedBadge(size: 22),
                  ],
                ],
              ),
              if (line.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  line,
                  style: OnHero.subtitle,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (academics.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(academics, style: OnHero.subtitle),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Three numbers a seller checks: what they have earned, how they are
/// rated, and what is sitting in the wallet.
class _Stats extends StatelessWidget {
  const _Stats({
    required this.earnings,
    required this.ratings,
    required this.wallet,
  });

  final Future<EarningsSummary> earnings;
  final Future<RatingDistribution> ratings;
  final Stream<Wallet> wallet;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EarningsSummary>(
      future: earnings,
      builder: (context, earned) => FutureBuilder<RatingDistribution>(
        future: ratings,
        builder: (context, rated) => StreamBuilder<Wallet>(
          stream: wallet,
          builder: (context, held) {
            final e = earned.data;
            final r = rated.data;
            final w = held.data;
            return StatGrid(
              minTile: 110,
              tiles: [
                StatTile(
                  label: 'Earned',
                  value: e == null ? '–' : pesos(e.net),
                  icon: Icons.savings_outlined,
                  emphasis: true,
                  caption: e == null
                      ? null
                      : '${e.orderCount} paid order${e.orderCount == 1 ? '' : 's'}',
                ),
                StatTile(
                  label: 'Rating',
                  value: r == null || r.total == 0
                      ? '–'
                      : r.average.toStringAsFixed(1),
                  icon: Icons.star_rounded,
                  caption: r == null
                      ? null
                      : r.total == 0
                      ? 'no reviews yet'
                      : '${r.total} review${r.total == 1 ? '' : 's'}',
                ),
                StatTile(
                  label: 'Available',
                  value: w == null ? '–' : pesos(w.available),
                  icon: Icons.account_balance_wallet_outlined,
                  caption: w != null && w.clearing > 0
                      ? '${pesos(w.clearing)} clearing'
                      : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WalletPeek extends StatelessWidget {
  const _WalletPeek({required this.stream});

  final Stream<Wallet> stream;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<Wallet>(
      stream: stream,
      builder: (context, snapshot) {
        final wallet = snapshot.data;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (wallet != null)
              Text(
                pesos(wallet.available),
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: theme.colorScheme.outline),
          ],
        );
      },
    );
  }
}
