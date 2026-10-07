import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/lily.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../data/wallet_repository.dart';
import '../domain/wallet.dart';

/// Money the platform holds for this freelancer, and the way to get it out.
///
/// Balances come from `wallets/{uid}`, written only by the backend. The card
/// offers exactly two actions: set where the money goes, and ask for it.
class WalletCard extends StatefulWidget {
  const WalletCard({super.key});

  @override
  State<WalletCard> createState() => _WalletCardState();
}

class _WalletCardState extends State<WalletCard> {
  Stream<Wallet>? _wallet;
  Stream<List<Payout>>? _payouts;
  String? _loadedFor;
  bool _requesting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      final repository = context.read<WalletRepository>();
      _wallet = repository.watchWallet(uid);
      _payouts = repository.watchPayouts(uid);
    }
  }

  Future<void> _requestPayout(Wallet wallet) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Request ${pesos(wallet.available)}?'),
        content: Text(
          'Your whole available balance is sent to your '
          '${wallet.payoutAccount!.typeLabel} '
          '(${wallet.payoutAccount!.accountNumber}). Check the number: a '
          'transfer to the wrong account cannot be recalled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Request payout'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _requesting = true);
    try {
      final result = await context.read<WalletRepository>().requestPayout();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${pesos(result.amount)}: ${result.message}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = _wallet;
    if (stream == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final repository = context.read<WalletRepository>();

    return LilyPanel(
      child: Padding(
        padding: EdgeInsets.zero,
        child: StreamBuilder<Wallet>(
          stream: stream,
          builder: (context, snapshot) {
            final wallet = snapshot.data ?? Wallet.empty(_loadedFor ?? '');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.account_balance_wallet_outlined, size: 18),
                    const SizedBox(width: 8),
                    Text('Balance', style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 12),
                StatGrid(
                  minTile: 120,
                  tiles: [
                    StatTile(
                      emphasis: true,
                      label: 'Available',
                      value: pesos(wallet.available),
                      icon: Icons.account_balance_wallet_outlined,
                    ),
                    if (wallet.clearing > 0)
                      StatTile(
                        label: 'Clearing',
                        value: pesos(wallet.clearing),
                        icon: Icons.hourglass_top_rounded,
                      ),
                    if (wallet.owed > 0)
                      StatTile(
                        label: 'Owed',
                        value: pesos(wallet.owed),
                        icon: Icons.remove_circle_outline_rounded,
                      ),
                    StatTile(
                      label: 'Being sent',
                      value: pesos(wallet.pendingPayout),
                      icon: Icons.outbox_outlined,
                    ),
                    StatTile(
                      label: 'Paid out',
                      value: pesos(wallet.totalPaidOut),
                      icon: Icons.check_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  snapshot.hasError
                      ? 'Could not load your balance right now.'
                      : 'Payments land here when a client accepts your work. '
                            'Payouts start at ${pesos(WalletPolicy.minimumPayout)} '
                            'and go to your GCash, Maya or bank account.'
                            '${wallet.isNewSeller ? ' Your first ${WalletPolicy.newSellerClearedReleases} payments clear after ${WalletPolicy.newSellerClearanceDays} days.' : ''}'
                            '${wallet.owed > 0 ? ' A payment was charged back after it was released; ${pesos(wallet.owed)} is deducted from your next releases.' : ''}'
                            ' Request a payout before you graduate: a balance untouched for ${WalletPolicy.dormantAfterDays} days is flagged so staff can reach you.',
                  style: theme.textTheme.bodySmall,
                ),
                if (!(context.watch<AuthController>().profile?.isAdult ??
                    false)) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Payouts are available to students aged 18 and over. Add '
                    'your birth date in Edit profile if it is missing.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _AccountLine(account: wallet.payoutAccount),
                if (repository.payoutsAvailable) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.outbox_outlined),
                    label: Text(
                      wallet.pendingPayout > 0
                          ? 'Payout on its way'
                          : 'Request payout',
                    ),
                    onPressed:
                        wallet.canRequestPayout &&
                            !_requesting &&
                            (context.read<AuthController>().profile?.isAdult ??
                                false)
                        ? () => _requestPayout(wallet)
                        : null,
                  ),
                ],
                if (_payouts != null) _RecentPayouts(stream: _payouts!),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The saved payout account, or the prompt to add one; either opens the
/// payout account page, where the method is chosen and the details typed.
class _AccountLine extends StatelessWidget {
  const _AccountLine({required this.account});

  final PayoutAccount? account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = account == null;
    return Material(
      color: missing
          ? theme.colorScheme.tertiary.withValues(alpha: 0.10)
          : theme.colorScheme.surfaceContainer.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(AppTheme.radiusControl),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/wallet/account'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              Icon(
                missing
                    ? Icons.add_card_rounded
                    : Icons.account_balance_outlined,
                size: 20,
                color: missing
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      missing ? 'Add a payout account' : account!.typeLabel,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      missing
                          ? 'GCash, Maya or a bank account'
                          : '${account!.maskedNumber} · ${account!.accountName}',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentPayouts extends StatelessWidget {
  const _RecentPayouts({required this.stream});

  final Stream<List<Payout>> stream;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Payout>>(
      stream: stream,
      builder: (context, snapshot) {
        final payouts = snapshot.data ?? const <Payout>[];
        if (payouts.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Recent payouts', style: theme.textTheme.labelLarge),
              for (final payout in payouts.take(5))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${pesos(payout.amount)} · ${payout.status.label}'
                          '${payout.reference == null ? '' : ' · ref ${payout.reference}'}',
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        DateFormat.MMMd().format(payout.requestedAt),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
