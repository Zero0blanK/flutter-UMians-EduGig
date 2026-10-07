import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/paginated_list.dart';
import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../data/wallet_repository.dart';
import '../domain/wallet.dart';
import 'wallet_card.dart';

/// Money, on its own page: the balance and payout controls, what has been
/// earned over all, and the ledger of every movement. It used to be three
/// cards stacked in the middle of the profile.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Future<EarningsSummary>? _earnings;
  String? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _earnings = context.read<PaymentRepository>().earningsOf(uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _loadedFor;
    final earnings = _earnings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/transactions'),
            icon: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('History'),
          ),
        ],
      ),
      body: ContentWidth(
        child: uid == null || earnings == null
            ? const LoadingView()
            : PaginatedList<LedgerEntry>(
                key: ValueKey(uid),
                load: (limit) => context.read<WalletRepository>().watchLedger(
                  uid,
                  limit: limit,
                ),
                emptyMessage: 'No movements yet. Releases, payouts and refunds are listed here.',
                header: Column(
                  children: [
                    const WalletCard(),
                    const SectionHeader('Earnings so far'),
                    _Earnings(future: earnings),
                    const SectionHeader('Activity'),
                  ],
                ),
                itemBuilder: (context, entry) => _LedgerRow(entry: entry),
              ),
      ),
    );
  }
}

class _Earnings extends StatelessWidget {
  const _Earnings({required this.future});

  final Future<EarningsSummary> future;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<EarningsSummary>(
      future: future,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const SkeletonBox(height: 90, radius: 16);
        }
        final earnings = snapshot.data ?? EarningsSummary.empty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatGrid(
              minTile: 110,
              tiles: [
                StatTile(
                  label: 'You received',
                  value: pesos(earnings.net),
                  icon: Icons.savings_outlined,
                  emphasis: true,
                ),
                StatTile(
                  label: 'Paid orders',
                  value: '${earnings.orderCount}',
                  icon: Icons.receipt_long_outlined,
                ),
                StatTile(
                  label: 'Commission',
                  value: pesos(earnings.commission),
                  icon: Icons.percent_rounded,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              snapshot.hasError
                  ? 'Could not load earnings right now.'
                  : earnings.orderCount == 0
                  ? 'Earnings appear here once a client has paid for your work.'
                  : 'Clients paid ${pesos(earnings.gross)} in total, of which '
                        '${pesos(earnings.commission)} was platform commission.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final positive = entry.amount > 0;
    final (icon, tint) = switch (entry.type) {
      'release' => (Icons.south_west_rounded, scheme.secondary),
      'refund' => (Icons.undo_rounded, scheme.error),
      'payout_requested' => (Icons.north_east_rounded, scheme.primary),
      'payout_paid' => (Icons.check_rounded, scheme.secondary),
      'payout_rejected' => (Icons.replay_rounded, scheme.tertiary),
      _ => (Icons.swap_horiz_rounded, scheme.outline),
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      leading: IconDisc(icon: icon, tint: tint, size: 38),
      title: Text(entry.label, style: theme.textTheme.titleSmall),
      subtitle: Text(
        [
          DateFormat.yMMMd().add_jm().format(entry.createdAt),
          if (entry.note != null && entry.note!.isNotEmpty) entry.note!,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '${positive ? '+' : ''}${pesos(entry.amount)}',
        style: theme.textTheme.titleSmall?.copyWith(
          color: positive ? scheme.secondary : scheme.onSurface,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
