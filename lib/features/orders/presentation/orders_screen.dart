import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/capped_list.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/order_repository.dart';
import '../domain/order_transitions.dart';
import 'widgets/order_status_chip.dart';

/// The Orders tab: everything the student is buying and everything they are
/// selling, with the ones waiting on them first.
///
/// One stream feeds both sides; the tabs and the filter chips are views of
/// it, so switching costs no reads. "Needs you" is the filter that matters
/// most and it is the first chip; its count rides on the tab label so a
/// seller with three unanswered requests sees the three before tapping.
class OrdersTab extends StatefulWidget {
  const OrdersTab({super.key});

  @override
  State<OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<OrdersTab> {
  /// Held rather than rebuilt in `build`: a fresh stream object each rebuild
  /// tears down and re-establishes the Firestore listener.
  Stream<CappedList<WorkOrder>>? _orders;
  String? _loadedFor;
  int _listLimit = 50;
  bool _loadingMore = false;
  bool _hasMore = false;

  void _loadMore() {
    final uid = _loadedFor;
    if (uid == null || _loadingMore || !_hasMore) return;
    setState(() {
      _listLimit += 50;
      _loadingMore = true;
      _orders = context
          .read<OrderRepository>()
          .watchInvolving(uid, limit: _listLimit)
          .map((page) {
            _loadingMore = false;
            return page;
          });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _listLimit = 50;
      _loadingMore = false;
      _orders = context.read<OrderRepository>().watchInvolving(
        uid,
        limit: _listLimit,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _loadedFor;
    final stream = _orders;
    if (uid == null || stream == null) return const LoadingView();
    return StreamBuilder<CappedList<WorkOrder>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _loadingMore = false;
          return Scaffold(
            appBar: AppBar(title: const Text('Orders')),
            body: const ErrorView(message: 'Could not load orders.'),
          );
        }
        final page = snapshot.data;
        _hasMore = page?.truncated ?? false;
        final orders = page?.items ?? const <WorkOrder>[];
        int needing(OrderRole role) => orders
            .where((o) => o.roleOf(uid) == role && _needsMe(o, role))
            .length;
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.axis == Axis.vertical &&
                notification.metrics.extentAfter < 300) {
              _loadMore();
            }
            return false;
          },
          child: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Orders'),
                bottom: TabBar(
                  tabs: [
                    _CountedTab(
                      label: 'Buying',
                      count: needing(OrderRole.client),
                    ),
                    _CountedTab(
                      label: 'Selling',
                      count: needing(OrderRole.freelancer),
                    ),
                  ],
                ),
              ),
              body: page == null
                  ? const LoadingView(skeleton: true)
                  : TabBarView(
                      children: [
                        for (final role in OrderRole.values)
                          _OrderList(
                            orders: orders
                                .where((o) => o.roleOf(uid) == role)
                                .toList(),
                            role: role,
                            truncated: page.truncated,
                            onLoadMore: _loadMore,
                            loadingMore: _loadingMore,
                          ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// True when the next move on this order is [role]'s: a request to answer,
/// a delivery to approve, a revision to make. Cancelling is always possible
/// and never counts.
bool _needsMe(WorkOrder order, OrderRole role) => switch (role) {
  OrderRole.freelancer =>
    order.status == OrderStatus.pending ||
        order.status == OrderStatus.accepted ||
        order.status == OrderStatus.revisionRequested,
  OrderRole.client => order.status == OrderStatus.submitted,
};

enum _Filter {
  needsMe('Needs you'),
  active('Active'),
  done('Done'),
  all('All');

  const _Filter(this.label);

  final String label;

  bool matches(WorkOrder order, OrderRole role) => switch (this) {
    _Filter.needsMe => _needsMe(order, role),
    _Filter.active => !order.status.isFinished,
    _Filter.done => order.status.isFinished,
    _Filter.all => true,
  };
}

class _CountedTab extends StatelessWidget {
  const _CountedTab({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Badge.count(count: count),
          ],
        ],
      ),
    );
  }
}

class _OrderList extends StatefulWidget {
  const _OrderList({
    required this.orders,
    required this.role,
    required this.truncated,
    required this.onLoadMore,
    required this.loadingMore,
  });

  final List<WorkOrder> orders;
  final OrderRole role;

  /// True when the query hit its ceiling and older orders exist unlisted.
  final bool truncated;
  final VoidCallback onLoadMore;
  final bool loadingMore;

  @override
  State<_OrderList> createState() => _OrderListState();
}

class _OrderListState extends State<_OrderList>
    with AutomaticKeepAliveClientMixin {
  _Filter _filter = _Filter.active;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final role = widget.role;
    final shown = widget.orders.where((o) => _filter.matches(o, role)).toList();
    final columns = Breakpoints.columns(context, minTile: 420);

    final chips = SliverToBoxAdapter(
      child: ChipStrip(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        children: [
          for (final filter in _Filter.values)
            ChoiceChip(
              label: Text(
                filter == _Filter.all
                    ? filter.label
                    : '${filter.label} · ${widget.orders.where((o) => filter.matches(o, role)).length}',
              ),
              selected: _filter == filter,
              onSelected: (_) => setState(() => _filter = filter),
            ),
        ],
      ),
    );

    if (widget.orders.isEmpty) {
      return CustomScrollView(
        slivers: [
          if (widget.truncated)
            SliverToBoxAdapter(
              child: TextButton(
                onPressed: widget.loadingMore ? null : widget.onLoadMore,
                child: Text(
                  widget.loadingMore
                      ? 'Loading older orders...'
                      : 'Load older orders',
                ),
              ),
            ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(
              icon: role == OrderRole.client
                  ? Icons.shopping_bag_outlined
                  : Icons.storefront_outlined,
              title: role == OrderRole.client
                  ? 'Nothing ordered yet'
                  : 'No orders for your services yet',
              message: role == OrderRole.client
                  ? 'Find a classmate\'s service on Home and order it; it will show up here.'
                  : 'Publish a service so classmates can order from you.',
              actionLabel: role == OrderRole.client
                  ? 'Browse services'
                  : 'My services',
              onAction: () => role == OrderRole.client
                  ? context.go('/')
                  : context.push('/my-services'),
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        chips,
        if (shown.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(
              icon: Icons.filter_list_off_rounded,
              title: switch (_filter) {
                _Filter.needsMe => 'Nothing needs you right now',
                _Filter.active => 'No active orders',
                _Filter.done => 'Nothing finished yet',
                _Filter.all => 'No orders',
              },
              message: 'Try another filter.',
              actionLabel: 'Show all',
              onAction: () => setState(() => _filter = _Filter.all),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            sliver: columns == 1
                ? SliverList.separated(
                    itemCount: shown.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) =>
                        _OrderCard(order: shown[i], role: role),
                  )
                : SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      mainAxisExtent:
                          190 * MediaQuery.textScalerOf(context).scale(14) / 14,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) =>
                        _OrderCard(order: shown[i], role: role),
                  ),
          ),
        if (widget.truncated)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: widget.loadingMore ? null : widget.onLoadMore,
              child: Text(
                widget.loadingMore ? 'Loading?' : 'Load older records',
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              role == OrderRole.client
                  ? 'You are the buyer on these.'
                  : 'You are the seller on these.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }
}

/// Relative due date, because "due in 3 days" is what a seller acts on;
/// an absolute date makes them do the arithmetic themselves.
String _dueLabel(DateTime deadline) {
  final days = deadline.difference(DateTime.now()).inDays;
  if (days < 0) return 'Overdue';
  if (days == 0) return 'Due today';
  if (days == 1) return 'Due tomorrow';
  return 'Due in ${days}d';
}

/// One order: the service, the other party, where it stands, what it costs,
/// and when it is due. A tone-coloured edge lets a column be scanned.
class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.role});

  final WorkOrder order;
  final OrderRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (tone, _) = orderStatusVisual(order.status);
    final edge = switch (tone) {
      Tone.neutral => scheme.outlineVariant,
      Tone.active => scheme.primary,
      Tone.attention => scheme.tertiary,
      Tone.success => scheme.secondary,
      Tone.danger => scheme.error,
    };
    final needsMe = _needsMe(order, role);
    final other = role == OrderRole.client
        ? order.freelancerId
        : order.clientId;
    final overdue =
        order.deadline != null &&
        !order.status.isFinished &&
        order.deadline!.isBefore(DateTime.now());

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/order/${order.id}'),
        // The edge stretches to the card's height; in a list that height is
        // the content's, which stretch alone cannot know.
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: edge),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              order.serviceTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '₱${NumberFormat.decimalPattern().format(order.price)}',
                            style: AppTheme.price(context, size: 17),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          OrderStatusChip(status: order.status, dense: true),
                          if (needsMe) ...[
                            const StatusPill(
                              label: 'Your move',
                              tone: Tone.attention,
                              icon: Icons.touch_app_rounded,
                              dense: true,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          UserAvatarFor(uid: other, radius: 9),
                          const SizedBox(width: 5),
                          Expanded(
                            child: UserName(
                              uid: other,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (order.deadline != null &&
                              !order.status.isFinished)
                            Text(
                              _dueLabel(order.deadline!),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: overdue ? scheme.error : null,
                                fontWeight: overdue ? FontWeight.w700 : null,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
