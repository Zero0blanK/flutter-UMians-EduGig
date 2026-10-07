import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../orders/data/order_repository.dart';
import '../data/offer_repository.dart';
import '../domain/offer.dart';

String _pesos(int amount) => '₱${NumberFormat.decimalPattern().format(amount)}';

/// The offer as it appears in the conversation.
///
/// Streams the offer document rather than reading the message, so the card
/// the freelancer sent yesterday shows today's status. The client's Accept
/// goes straight to placing the order: the order is created from the offer's
/// figures and the client lands on it, where payment is the next step.
class OfferCard extends StatefulWidget {
  const OfferCard({super.key, required this.offerId, required this.myUid});

  final String offerId;
  final String myUid;

  @override
  State<OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<OfferCard> {
  late final Stream<Offer?> _offer = context.read<OfferRepository>().watch(
    widget.offerId,
  );
  bool _busy = false;

  Future<void> _accept(Offer offer) async {
    final requirements = await showDialog<String>(
      context: context,
      builder: (_) => _RequirementsDialog(offer: offer),
    );
    if (requirements == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final orderId = await context.read<OrderRepository>().createFromOffer(
        offer: offer,
        buyerId: widget.myUid,
        requirements: requirements,
      );
      if (!mounted) return;
      context.push('/order/$orderId');
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(Offer offer, OfferStatus outcome) async {
    setState(() => _busy = true);
    try {
      await context.read<OfferRepository>().close(
        offerId: offer.id,
        actorId: widget.myUid,
        outcome: outcome,
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<Offer?>(
      stream: _offer,
      builder: (context, snapshot) {
        final offer = snapshot.data;
        if (offer == null) {
          return Text(
            snapshot.hasError ? 'Offer unavailable.' : 'Loading offer…',
            style: theme.textTheme.bodySmall,
          );
        }
        final isClient = widget.myUid == offer.clientId;
        final status = offer.isExpired ? OfferStatus.expired : offer.status;
        return Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: status == OfferStatus.pending
                  ? theme.colorScheme.primary.withValues(alpha: 0.5)
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.request_quote_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Offer for ${offer.serviceTitle}',
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _pesos(offer.price),
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${offer.deliveryDays}-day delivery · '
                '${offer.revisionCount} revision${offer.revisionCount == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(offer.scope, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(
                status == OfferStatus.pending
                    ? 'Valid until ${DateFormat.yMMMd().format(offer.expiresAt)}'
                    : status.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: status == OfferStatus.pending
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ..._actions(context, offer, status, isClient),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _actions(
    BuildContext context,
    Offer offer,
    OfferStatus status,
    bool isClient,
  ) {
    if (status == OfferStatus.ordered && offer.orderId != null) {
      return [
        OutlinedButton.icon(
          icon: const Icon(Icons.receipt_long_outlined, size: 18),
          label: const Text('View order'),
          onPressed: () => context.push('/order/${offer.orderId}'),
        ),
      ];
    }
    if (status == OfferStatus.accepted && isClient) {
      // Accepted but the order write did not land; finish it.
      return [
        FilledButton(
          onPressed: _busy ? null : () => _accept(offer),
          child: const Text('Place the order'),
        ),
      ];
    }
    if (status != OfferStatus.pending) return const [];
    if (isClient) {
      return [
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _accept(offer),
                child: const Text('Accept & order'),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _close(offer, OfferStatus.declined),
              child: const Text('Decline'),
            ),
          ],
        ),
      ];
    }
    return [
      TextButton(
        onPressed: _busy ? null : () => _close(offer, OfferStatus.withdrawn),
        child: const Text('Withdraw offer'),
      ),
    ];
  }
}

/// The client's requirements for the order about to be created. The offer
/// already holds the freelancer's scope; this is the client's side of it.
class _RequirementsDialog extends StatefulWidget {
  const _RequirementsDialog({required this.offer});

  final Offer offer;

  @override
  State<_RequirementsDialog> createState() => _RequirementsDialogState();
}

class _RequirementsDialogState extends State<_RequirementsDialog> {
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
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Order at ${_pesos(widget.offer.price)}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The order is created with exactly these terms: '
            '${_pesos(widget.offer.price)}, ${widget.offer.deliveryDays} days, '
            '${widget.offer.revisionCount} revisions. Payment comes next, '
            'once the freelancer accepts the order.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(
              labelText: 'Your requirements',
              hintText:
                  'Files, references, deadlines, anything agreed in chat…',
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
          onPressed: _controller.text.trim().length >= 10
              ? () => Navigator.pop(context, _controller.text.trim())
              : null,
          child: const Text('Accept and place order'),
        ),
      ],
    );
  }
}
