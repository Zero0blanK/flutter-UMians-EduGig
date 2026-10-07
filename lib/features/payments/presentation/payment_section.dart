import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/lily.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../orders/domain/order.dart';
import '../data/payment_gateway.dart';
import '../data/payment_repository.dart';
import '../domain/payment.dart';
import '../payment_config.dart';
import 'payment_method_sheet.dart';

String pesos(int amount) => '₱${NumberFormat.decimalPattern().format(amount)}';

/// Payment panel shown on the order detail screen.
///
/// Renders the commission split for both parties, and offers whichever action
/// belongs to the viewer: the client pays, the freelancer confirms receipt.
///
/// Takes [payment] as a value rather than subscribing itself. The order screen
/// owns that stream, so the panel and the "Start working" gate read one
/// listener instead of opening two on the same document.
class PaymentSection extends StatelessWidget {
  const PaymentSection({
    super.key,
    required this.order,
    required this.myUid,
    required this.payment,
    this.loadFailed = false,
  });

  final WorkOrder order;
  final String myUid;

  /// Null while loading, and while the order is unpaid.
  final Payment? payment;
  final bool loadFailed;

  @override
  Widget build(BuildContext context) {
    final repository = context.watch<PaymentRepository>();
    final theme = Theme.of(context);

    if (loadFailed) {
      return const Text('Could not load payment details.');
    }

    final breakdown = repository.breakdownFor(order);
    final role = order.roleOf(myUid);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [_PaymentStatusChip(payment: payment)]),
        const SizedBox(height: 12),
        _BreakdownTable(
          gross: payment?.amount ?? breakdown.gross,
          commission: payment?.commission ?? breakdown.commission,
          net: payment?.netToFreelancer ?? breakdown.netToFreelancer,
          rateLabel: payment == null
              ? repository.config.commissionPolicy.rateLabel
              : null,
          role: role,
        ),
        if (payment?.reference != null) ...[
          const SizedBox(height: 8),
          Text(
            'Reference: ${payment!.reference}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        _ModeBanner(config: repository.config, payment: payment),
        const SizedBox(height: 12),
        ..._actions(context, repository, payment, role),
      ],
    );
  }

  List<Widget> _actions(
    BuildContext context,
    PaymentRepository repository,
    Payment? payment,
    OrderRole role,
  ) {
    // Nothing to collect until the freelancer has taken the job, and nothing
    // to collect once the order is dead.
    const payableStatuses = {
      OrderStatus.accepted,
      OrderStatus.inProgress,
      OrderStatus.submitted,
      OrderStatus.revisionRequested,
    };
    if (!payableStatuses.contains(order.status) && payment == null) {
      return [
        Text(
          order.status == OrderStatus.pending
              ? 'Payment opens once the freelancer accepts this order.'
              : 'No payment is due for this order.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];
    }

    if (payment?.status == PaymentStatus.refunded) {
      return [
        _Line(
          icon: Icons.undo_outlined,
          text: [
            role == OrderRole.client
                ? 'Refunded to you through the gateway'
                : 'Refunded to the client',
            if (payment!.refundedAt != null)
              'on ${DateFormat.yMMMd().add_jm().format(payment.refundedAt!)}',
          ].join(' '),
        ),
      ];
    }

    if (payment?.isSettled ?? false) {
      final settled = payment!;
      final when = settled.paidAt == null
          ? ''
          : ' on ${DateFormat.yMMMd().add_jm().format(settled.paidAt!)}';
      return [
        _Line(
          icon: Icons.verified_outlined,
          text: settled.verified
              ? 'Confirmed by the payment gateway$when'
              : 'Confirmed by the freelancer$when',
        ),
        // Where the money is now. An attestation has no hold; a gateway
        // payment sits with the platform until the client accepts the work.
        if (settled.holdStatus != null) ...[
          const SizedBox(height: 6),
          _Line(
            icon: switch (settled.holdStatus!) {
              HoldStatus.held => Icons.lock_clock_outlined,
              HoldStatus.released => Icons.account_balance_wallet_outlined,
              HoldStatus.refunded => Icons.undo_outlined,
            },
            text: switch ((settled.holdStatus!, role)) {
              (HoldStatus.held, OrderRole.client) =>
                'Held by the platform until you accept the delivery.',
              (HoldStatus.held, OrderRole.freelancer) =>
                'Held by the platform. Released to your balance when the '
                    'client accepts the delivery.',
              (HoldStatus.released, OrderRole.client) =>
                'Released to the freelancer.',
              (HoldStatus.released, OrderRole.freelancer) =>
                'Released to your balance'
                    '${settled.releasedAt == null ? '' : ' on ${DateFormat.yMMMd().format(settled.releasedAt!)}'}. '
                    'Request a payout from your profile.',
              (HoldStatus.refunded, _) => 'Refunded to the client.',
            },
          ),
        ],
        if (settled.refundStatus == 'failed' ||
            settled.refundStatus == 'manual-required') ...[
          const SizedBox(height: 6),
          _Line(
            icon: Icons.support_agent_outlined,
            text: 'A refund is being handled by staff.',
          ),
        ],
      ];
    }

    if (role == OrderRole.client) {
      final awaiting = payment?.status == PaymentStatus.pending;
      final failed = payment?.status == PaymentStatus.failed;
      final theme = Theme.of(context);

      // The amount-specific action in the order bar is the single entry point
      // for a first payment. Keeping another "Pay now" button here made the
      // same checkout appear twice on the screen.
      if (payment == null) {
        return [
          Text(
            'Use the payment action below to continue.',
            style: theme.textTheme.bodySmall,
          ),
        ];
      }

      // A gateway checkout is open: the answer comes from the gateway, so
      // the first thing to offer is asking it, not another checkout.
      if (awaiting && payment.method == PaymentMethod.xendit) {
        return [
          _Line(
            icon: Icons.hourglass_top_rounded,
            text:
                'Waiting for the gateway to confirm. Finished paying? Check '
                'now; it takes a second. Closed the page before paying? '
                'Reopen the checkout.',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Check payment status'),
                onPressed: () => _syncFlow(context, repository),
              ),
              OutlinedButton(
                onPressed: () => _payFlow(context, repository),
                child: const Text('Reopen checkout'),
              ),
            ],
          ),
        ];
      }

      return [
        FilledButton.icon(
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label: Text(
            failed
                ? 'Pay again'
                : awaiting
                ? 'Update payment details'
                : 'Continue payment',
          ),
          onPressed: () => _payFlow(context, repository),
        ),
        if (awaiting)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Waiting for the freelancer to confirm they received it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (failed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'The checkout expired or was declined. Nothing was charged.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ];
    }

    // Freelancer's side.
    if (payment == null) {
      return [
        Text(
          'Waiting for the client to pay.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];
    }
    if (payment.method == PaymentMethod.manual) {
      return [
        FilledButton.icon(
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('I received the payment'),
          onPressed: () => _confirmFlow(context, repository),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Only confirm once the money is actually in your account.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ];
    }
    return [
      Text(
        'Waiting for the gateway to confirm this payment.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  Future<void> _payFlow(BuildContext context, PaymentRepository repository) =>
      payForOrder(context, order, myUid: myUid);

  Future<void> _syncFlow(
    BuildContext context,
    PaymentRepository repository,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final status = await repository.syncPayment(order.id);
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(switch (status) {
            PaymentStatus.paid => 'Payment confirmed. Thank you.',
            PaymentStatus.failed =>
              'That checkout expired. Pay again to open a new one.',
            PaymentStatus.refunded => 'This payment was refunded.',
            PaymentStatus.pending || null =>
              'Not confirmed yet. If you just finished paying, give it a '
                  'moment and check again.',
          }),
        ),
      );
    } on AppFailure catch (failure) {
      messenger.showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  Future<void> _confirmFlow(
    BuildContext context,
    PaymentRepository repository,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirm payment received?'),
        content: const Text(
          'Only do this once the money has actually arrived. This cannot be '
          'undone, and the client is told the payment is settled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await repository.confirmManualReceipt(orderId: order.id, actorId: myUid);
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }
}

/// How the platform handles a client's money, in the words they agree to.
///
/// Deliberately says "held by the platform", never "escrow": the platform is
/// the merchant of record and pays the freelancer as a contractor, which is
/// what it can lawfully be without a custodial licence. The full text lives
/// in docs/PAYMENT_TERMS.md and this dialog must match it.
class PaymentTermsDialog extends StatelessWidget {
  const PaymentTermsDialog({super.key});

  static const points = [
    'You pay the full price now. The platform collects it and holds it while '
        'the work is done.',
    'The freelancer is paid, minus the platform commission, only when you '
        'accept the delivery. If you do not respond within 3 days of a '
        'delivery, the order completes on its own and they are paid. You are '
        'reminded a day before.',
    'If the order is cancelled or declined, you are refunded through the '
        'same payment method. Refunds take a few days to appear.',
    'If you dispute an order, staff decide between a full release, a full '
        'refund, and nothing in between, based on the chat and the delivery. '
        'Orders of ₱${DisputePolicy.secondOpinionFrom} or more need two staff '
        'members to agree.',
    'The platform is the merchant of record and pays freelancers as '
        'contractors. This is not an escrow or a bank account.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('How payment works'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final point in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(
                      child: Text(point, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('I understand, continue'),
        ),
      ],
    );
  }
}

/// Opens a hosted checkout page in the platform browser.
///
/// The app never handles card details itself, which keeps it out of PCI
/// scope entirely. If no browser can be launched (an emulator without one,
/// say) the URL is shown so it can be copied.
Future<void> openCheckout(BuildContext context, Uri checkoutUrl) async {
  final opened = await launchUrl(
    checkoutUrl,
    mode: LaunchMode.externalApplication,
  );
  if (opened || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Continue to checkout'),
      content: SelectableText('Complete your payment at:\n\n$checkoutUrl'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// One icon-and-sentence row.
class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

class _BreakdownTable extends StatelessWidget {
  const _BreakdownTable({
    required this.gross,
    required this.commission,
    required this.net,
    required this.rateLabel,
    required this.role,
  });

  final int gross;
  final int commission;
  final int net;
  final String? rateLabel;
  final OrderRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget line(String label, String value, {bool emphasis = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: emphasis
                ? theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  )
                : theme.textTheme.bodyMedium,
          ),
          Text(
            value,
            style: emphasis
                ? theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  )
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          line(
            role == OrderRole.client ? 'You pay' : 'Client pays',
            pesos(gross),
            emphasis: role == OrderRole.client,
          ),
          line(
            rateLabel == null
                ? 'Platform commission'
                : 'Platform commission ($rateLabel)',
            '− ${pesos(commission)}',
          ),
          const Divider(height: 14),
          line(
            role == OrderRole.freelancer
                ? 'You receive'
                : 'Freelancer receives',
            pesos(net),
            emphasis: role == OrderRole.freelancer,
          ),
        ],
      ),
    );
  }
}

class _PaymentStatusChip extends StatelessWidget {
  const _PaymentStatusChip({required this.payment});

  final Payment? payment;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = switch (payment?.status) {
      null => ('Unpaid', Tone.neutral, Icons.hourglass_empty_rounded),
      PaymentStatus.pending => (
        'Awaiting confirmation',
        Tone.attention,
        Icons.schedule_rounded,
      ),
      PaymentStatus.paid => ('Paid', Tone.success, Icons.check_rounded),
      PaymentStatus.failed => (
        'Failed',
        Tone.danger,
        Icons.error_outline_rounded,
      ),
      PaymentStatus.refunded => ('Refunded', Tone.neutral, Icons.undo_rounded),
    };
    return StatusPill(label: label, tone: tone, icon: icon, dense: true);
  }
}

/// Tells the viewer which payment backend is live, and — crucially — whether a
/// settled payment was proven or merely attested. Presenting an attestation
/// with the same confidence as a gateway receipt would be dishonest UI.
class _ModeBanner extends StatelessWidget {
  const _ModeBanner({required this.config, required this.payment});

  final PaymentConfig config;
  final Payment? payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unverifiedSettlement =
        (payment?.isSettled ?? false) && !payment!.verified;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          config.isVerifiable ? Icons.lock_outline : Icons.handshake_outlined,
          size: 16,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            unverifiedSettlement
                ? 'Settled outside the app and confirmed by the freelancer. '
                      'No gateway receipt backs this record.'
                : config.modeDescription,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ReferenceDialog extends StatefulWidget {
  const _ReferenceDialog({required this.amount});

  final int amount;

  @override
  State<_ReferenceDialog> createState() => _ReferenceDialogState();
}

class _ReferenceDialogState extends State<_ReferenceDialog> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Record ${pesos(widget.amount)} payment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Send the money to your freelancer first, then enter the '
            'reference number so they can match it.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: PaymentRepository.maxReferenceLength,
            decoration: const InputDecoration(
              labelText: 'Reference',
              hintText: 'e.g. GCash ref 1234567890',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Record payment'),
        ),
      ],
    );
  }
}

/// The one way a buyer pays an order, from the payment panel or the order
/// page's action bar: manual reference, or channel sheet + terms + hosted
/// checkout + a sync on return.
Future<void> payForOrder(
  BuildContext context,
  WorkOrder order, {
  required String myUid,
}) async {
  final repository = context.read<PaymentRepository>();
  final manual = repository.config.mode == PaymentMode.manual;
  String? reference;

  if (manual) {
    reference = await showDialog<String>(
      context: context,
      builder: (_) =>
          _ReferenceDialog(amount: repository.breakdownFor(order).gross),
    );
    if (reference == null || !context.mounted) return;
  }

  // Gateway mode: pick how to pay first, the way a delivery checkout does,
  // so the hosted page opens on that channel.
  PaymentChannel channel = PaymentChannel.other;
  if (!manual) {
    final chosen = await showPaymentMethodSheet(
      context,
      title: 'Pay for this order',
      amount: repository.breakdownFor(order).gross,
      note: 'Held by the platform until you approve the delivery.',
    );
    if (chosen == null || !context.mounted) return;
    channel = chosen;
  }

  // Gateway mode holds the client's money. Say exactly how that works
  // once, before the first checkout, and record that they read it.
  if (!manual) {
    final auth = context.read<AuthController>();
    if (!(auth.profile?.hasAcceptedPaymentTerms ?? false)) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (_) => const PaymentTermsDialog(),
      );
      if (accepted != true || !context.mounted) return;
      try {
        await auth.acceptPaymentTerms();
      } on AppFailure catch (failure) {
        if (context.mounted) showFailureSnackBar(context, failure);
        return;
      }
      if (!context.mounted) return;
    }
  }

  final messenger = ScaffoldMessenger.of(context);
  try {
    final intent = await repository.beginPayment(
      order: order,
      actorId: myUid,
      channel: channel,
      reference: reference,
    );
    if (!context.mounted) return;

    switch (intent) {
      case ManualCheckout(:final instructions):
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Payment recorded'),
            content: Text(instructions),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      case RedirectCheckout(:final checkoutUrl):
        await openCheckout(context, checkoutUrl);
        // Back from the browser: ask the gateway at once, so a finished
        // payment shows as paid without waiting for the callback.
        try {
          await repository.syncPayment(order.id);
        } on AppFailure {
          // The stream and the reconciler still settle it; nothing to say.
        }
    }
  } on AppFailure catch (failure) {
    messenger.showSnackBar(SnackBar(content: Text(failure.message)));
  }
}
