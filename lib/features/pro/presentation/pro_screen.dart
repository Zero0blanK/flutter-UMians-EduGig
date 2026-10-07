import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../auth/presentation/auth_controller.dart';
import '../domain/pro_policy.dart';
import 'pro_card.dart';

/// Pro, on its own page: what it buys, the subscription, and the identity
/// check behind the badge. The hero says the one thing worth knowing before
/// paying: commission does not change.
class ProScreen extends StatelessWidget {
  const ProScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<AuthController>().profile;
    final isPro = profile?.isPro ?? false;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          PageHero(
            padding: const EdgeInsets.fromLTRB(20, kToolbarHeight + 4, 20, 28),
            child: ContentWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const LilyMark(size: 44, onHero: true),
                      const SizedBox(width: 12),
                      Text(isPro ? 'You are Pro' : 'Pro', style: OnHero.title),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '₱${ProPolicy.price} for ${ProPolicy.periodDays} days, paid '
                    'up front, no auto-renewal. Commission stays at 5% '
                    'whether you are Pro or not.',
                    style: OnHero.subtitle,
                  ),
                ],
              ),
            ),
          ),
          ContentWidth(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LilyPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'What you get',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        _Perk(
                          icon: Icons.push_pin_rounded,
                          title: 'Featured listings',
                          body:
                              'Pin up to ${ProPolicy.featuredPerSeller} of your '
                              'services above the marketplace. Featured spots '
                              'rotate fairly among Pro sellers every hour.',
                        ),
                        const SizedBox(height: 12),
                        _Perk(
                          icon: Icons.verified_rounded,
                          title: 'Verified badge',
                          body:
                              'A check next to your name once staff have '
                              'confirmed your student ID. Shown while Pro is '
                              'active.',
                        ),
                        const SizedBox(height: 12),
                        _Perk(
                          icon: Icons.percent_rounded,
                          title: 'Same commission',
                          body:
                              'Pro never discounts the 5% commission. It buys '
                              'visibility and trust, not a cheaper cut.',
                        ),
                      ],
                    ),
                  ),
                  const SectionHeader('Subscription'),
                  const ProCard(),
                  const SectionHeader('Identity check'),
                  const VerificationCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Perk extends StatelessWidget {
  const _Perk({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconDisc(icon: icon, size: 36, tint: theme.colorScheme.tertiary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(body, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
