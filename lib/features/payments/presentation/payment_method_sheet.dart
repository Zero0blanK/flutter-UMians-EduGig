import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/lily.dart';
import '../domain/payment.dart';

/// The checkout sheet: what is being paid, how much, and the way to pay it.
///
/// Picking a channel here means the hosted payment page opens straight on
/// GCash, Maya or the card form instead of a menu, the way a food-delivery
/// checkout does. Card details are still entered on the gateway's page,
/// never in this app.
///
/// Returns the chosen channel, or null when dismissed.
Future<PaymentChannel?> showPaymentMethodSheet(
  BuildContext context, {
  required String title,
  required int amount,
  required String note,
}) {
  return showModalBottomSheet<PaymentChannel>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _PaymentMethodSheet(title: title, amount: amount, note: note),
  );
}

class _PaymentMethodSheet extends StatefulWidget {
  const _PaymentMethodSheet({
    required this.title,
    required this.amount,
    required this.note,
  });

  final String title;
  final int amount;
  final String note;

  @override
  State<_PaymentMethodSheet> createState() => _PaymentMethodSheetState();
}

class _PaymentMethodSheetState extends State<_PaymentMethodSheet> {
  PaymentChannel _channel = PaymentChannel.gcash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.note, style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            LilyPanel(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Text('Total', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  Text(
                    '₱${NumberFormat.decimalPattern().format(widget.amount)}',
                    style: AppTheme.price(context, size: 22),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Pay with', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            for (final channel in PaymentChannel.values)
              _ChannelTile(
                channel: channel,
                selected: channel == _channel,
                onTap: () => setState(() => _channel = channel),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: const Icon(Icons.lock_outline_rounded),
              label: Text(
                _channel == PaymentChannel.other
                    ? 'Continue to payment'
                    : 'Continue with ${_channel.label}',
              ),
              onPressed: () => Navigator.pop(context, _channel),
            ),
            const SizedBox(height: 8),
            Text(
              'You will finish on Xendit\'s secure page. This app never sees '
              'your card or wallet details.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final PaymentChannel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, tint) = switch (channel) {
      PaymentChannel.gcash => (
        Icons.account_balance_wallet_rounded,
        scheme.onSurfaceVariant,
      ),
      PaymentChannel.maya => (
        Icons.smartphone_rounded,
        scheme.onSurfaceVariant,
      ),
      PaymentChannel.card => (Icons.credit_card_rounded, scheme.primary),
      PaymentChannel.other => (
        Icons.more_horiz_rounded,
        scheme.onSurfaceVariant,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.08)
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusControl),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                IconDisc(icon: icon, tint: tint, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(channel.label, style: theme.textTheme.titleSmall),
                      Text(channel.hint, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : scheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
