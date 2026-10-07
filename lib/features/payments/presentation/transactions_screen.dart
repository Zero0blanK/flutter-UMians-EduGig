import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../pro/data/pro_repository.dart';
import '../../pro/domain/subscription.dart';
import '../data/payment_repository.dart';
import '../domain/payment.dart';

/// Every peso that moved for this student, newest first: order payments
/// they sent, order payments they received, and Pro months they bought,
/// each with where it stands (awaiting, paid and held, released, refunded,
/// failed). A row opens the order or the Pro page it belongs to.
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

enum _Filter {
  all('All'),
  sent('Sent'),
  received('Received');

  const _Filter(this.label);

  final String label;
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  Stream<List<Payment>>? _payments;
  Stream<List<Subscription>>? _subscriptions;
  String? _loadedFor;
  int _historyLimit = 50;
  bool _hasMore = false;
  bool _loadingMore = false;
  void _loadMore() {
    final uid = _loadedFor;
    if (uid == null || _loadingMore || !_hasMore) return;
    setState(() {
      _historyLimit += 50;
      _loadingMore = true;
      _payments = context
          .read<PaymentRepository>()
          .watchHistory(uid, limit: _historyLimit)
          .map((items) {
            _loadingMore = false;
            return items;
          });
      _subscriptions = context.read<ProRepository>().watchSubscriptions(
        uid,
        limit: _historyLimit,
      );
    });
  }

  _Filter _filter = _Filter.all;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _payments = context.read<PaymentRepository>().watchHistory(
        uid,
        limit: _historyLimit,
      );
      _subscriptions = context.read<ProRepository>().watchSubscriptions(
        uid,
        limit: _historyLimit,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _loadedFor;
    final payments = _payments;
    final subscriptions = _subscriptions;
    if (uid == null || payments == null || subscriptions == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Transactions')),
        body: const LoadingView(),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: ContentWidth(
        child: StreamBuilder<List<Payment>>(
          stream: payments,
          builder: (context, paid) => StreamBuilder<List<Subscription>>(
            stream: subscriptions,
            builder: (context, subs) {
              if (paid.hasError) {
                return const ErrorView(
                  message: 'Could not load your transactions.',
                );
              }
              if (!paid.hasData) return const LoadingView(skeleton: true);
              _hasMore =
                  (paid.data?.length ?? 0) >= _historyLimit ||
                  (subs.data?.length ?? 0) >= _historyLimit;
              final rows = [
                for (final p in paid.data!) _Row.payment(p, uid),
                // A Pro read can be denied on an older ruleset; the order
                // history still shows rather than the page failing.
                for (final s in subs.data ?? const <Subscription>[])
                  _Row.subscription(s),
              ]..sort((a, b) => b.when.compareTo(a.when));
              final shown = rows.where((r) => _filter.matches(r)).toList();

              if (rows.isEmpty) {
                return const EmptyView(
                  icon: Icons.receipt_long_outlined,
                  title: 'No transactions yet',
                  message:
                      'Payments you send and receive, and Pro months you '
                      'buy, are listed here with their status.',
                );
              }
              return NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.metrics.axis == Axis.vertical &&
                      notification.metrics.extentAfter < 300) {
                    _loadMore();
                  }
                  return false;
                },
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: ChipStrip(
                        children: [
                          for (final f in _Filter.values)
                            ChoiceChip(
                              label: Text(f.label),
                              selected: _filter == f,
                              onSelected: (_) => setState(() => _filter = f),
                            ),
                        ],
                      ),
                    ),
                    if (shown.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyView(
                          icon: Icons.filter_list_off_rounded,
                          message: 'Nothing under this filter.',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        sliver: SliverList.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) => _RowTile(row: shown[i]),
                        ),
                      ),
                    if (_hasMore)
                      SliverToBoxAdapter(
                        child: TextButton(
                          onPressed: _loadingMore ? null : _loadMore,
                          child: Text(
                            _loadingMore
                                ? 'Loading?'
                                : 'Load older transactions',
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

extension on _Filter {
  bool matches(_Row row) => switch (this) {
    _Filter.all => true,
    _Filter.sent => row.outgoing,
    _Filter.received => !row.outgoing,
  };
}

/// One line of history, whichever record it came from.
class _Row {
  const _Row({
    required this.title,
    required this.detail,
    required this.amount,
    required this.outgoing,
    required this.status,
    required this.tone,
    required this.icon,
    required this.when,
    required this.route,
  });

  factory _Row.payment(Payment p, String uid) {
    final buyer = p.clientId == uid;
    final gateway = p.method == PaymentMethod.xendit;
    final (String status, Tone tone) = switch (p.status) {
      PaymentStatus.pending => (
        buyer
            ? (gateway ? 'Awaiting confirmation' : 'Awaiting seller')
            : (gateway ? 'Buyer paying' : 'Confirm receipt'),
        Tone.attention,
      ),
      PaymentStatus.paid => switch (p.holdStatus) {
        HoldStatus.held => ('Paid · held until approval', Tone.active),
        HoldStatus.released => (
          buyer ? 'Paid · released to seller' : 'Released to your wallet',
          Tone.success,
        ),
        HoldStatus.refunded => ('Refunded', Tone.neutral),
        null => (
          gateway
              ? 'Paid'
              : buyer
              ? 'Confirmed by the seller'
              : 'Confirmed by you',
          Tone.success,
        ),
      },
      PaymentStatus.failed => ('Failed · nothing charged', Tone.danger),
      PaymentStatus.refunded => (
        buyer ? 'Refunded to you' : 'Refunded to the buyer',
        Tone.neutral,
      ),
    };
    final stuck =
        p.refundStatus == 'failed' || p.refundStatus == 'manual-required';
    return _Row(
      title: buyer ? 'Order payment' : 'Payment for your work',
      detail: [
        DateFormat.yMMMd().add_jm().format(p.updatedAt),
        gateway ? 'Xendit' : 'Direct',
        if (stuck) 'refund with staff',
      ].join(' · '),
      amount: buyer ? p.amount : p.netToFreelancer,
      outgoing: buyer,
      status: status,
      tone: tone,
      icon: buyer ? Icons.north_east_rounded : Icons.south_west_rounded,
      when: p.updatedAt,
      route: '/order/${p.orderId}',
    );
  }

  factory _Row.subscription(Subscription s) {
    final (String status, Tone tone) = switch (s.status) {
      'paid' => (
        s.periodEnd == null
            ? 'Active'
            : 'Active until ${DateFormat.yMMMd().format(s.periodEnd!)}',
        Tone.success,
      ),
      'failed' => ('Failed · nothing charged', Tone.danger),
      _ => ('Awaiting confirmation', Tone.attention),
    };
    return _Row(
      title: 'Pro subscription',
      detail: DateFormat.yMMMd().add_jm().format(s.paidAt ?? s.createdAt),
      amount: s.amount,
      outgoing: true,
      status: status,
      tone: tone,
      icon: Icons.workspace_premium_outlined,
      when: s.paidAt ?? s.createdAt,
      route: '/pro',
    );
  }

  final String title;
  final String detail;
  final int amount;
  final bool outgoing;
  final String status;
  final Tone tone;
  final IconData icon;
  final DateTime when;
  final String route;
}

class _RowTile extends StatelessWidget {
  const _RowTile({required this.row});

  final _Row row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = switch (row.tone) {
      Tone.neutral => scheme.outline,
      Tone.active => scheme.primary,
      Tone.attention => scheme.tertiary,
      Tone.success => scheme.secondary,
      Tone.danger => scheme.error,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => context.push(row.route),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          child: Row(
            children: [
              IconDisc(icon: row.icon, tint: tint, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      '${row.outgoing ? '−' : '+'}₱${NumberFormat.decimalPattern().format(row.amount)}',
                      style: AppTheme.price(
                        context,
                        size: 16,
                      ).copyWith(color: row.outgoing ? scheme.onSurface : null),
                    ),
                    const SizedBox(height: 2),
                    Text(row.detail, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    StatusPill(label: row.status, tone: row.tone, dense: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
