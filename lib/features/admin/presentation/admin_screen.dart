import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/paginated_list.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../orders/domain/order.dart';
import '../../payments/domain/payment.dart';
import '../../pro/domain/pro_policy.dart';
import '../../wallet/domain/wallet.dart';
import '../data/admin_repository.dart';
import '../domain/admin_access.dart';
import '../domain/platform_metrics.dart';
import 'admin_management.dart';
import 'admin_queues.dart';
import 'admin_sales_report.dart';

String _peso(int amount) => '₱${NumberFormat.decimalPattern().format(amount)}';

/// Staff console. Builds one tab per permission the caller holds; the main
/// admin sees all of them plus Staff.
///
/// Reachable only when `admins/{uid}` exists. That check is a convenience —
/// every query behind this screen is refused by security rules for anyone
/// without the matching permission, so hiding a tab is not what makes it
/// safe.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.access});

  final AdminAccess access;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<PlatformMetrics> _metrics;
  late Stream<List<WorkOrder>> _disputes;
  late Stream<List<AdminAction>> _log;
  late Stream<List<Payout>> _payouts;
  late Stream<List<VerificationRequest>> _verifications;
  late Stream<List<Payment>> _refunds;
  late Future<MoneyHeld> _money;

  /// Open items per queue, held as plain numbers for the rail badge and the
  /// "needs attention" tiles. Queue content has its own Firestore listener:
  /// a lazily built StreamBuilder must receive an initial snapshot even when
  /// the badge listener connected earlier.
  final _counts = <String, int>{};
  final _subscriptions = <StreamSubscription<void>>[];

  int _index = 0;

  /// Sections a staff member has opened. Only those are built, so a section
  /// never subscribes to its streams before someone looks at it, and it
  /// keeps them once they have.
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final repository = context.read<AdminRepository>();
    final access = widget.access;
    if (access.can(AdminPermission.reportsView)) {
      _metrics = repository.metrics();
      _log = repository.watchActionLog();
      _money = repository.moneyHeld();
    }
    if (access.can(AdminPermission.disputesResolve)) {
      _disputes = repository.watchDisputes();
    }
    if (access.can(AdminPermission.payoutsSettle)) {
      _payouts = repository.watchPayoutQueue();
    }
    if (access.can(AdminPermission.verificationDecide)) {
      _verifications = repository.watchVerificationQueue();
    }
    if (access.can(AdminPermission.refundsHandle)) {
      _refunds = repository.watchRefundQueue();
    }

    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    void count(String key, Stream<int> stream) {
      _subscriptions.add(
        stream.listen((n) {
          if (!mounted || _counts[key] == n) return;
          setState(() => _counts[key] = n);
        }, onError: (_) {}),
      );
    }

    if (access.can(AdminPermission.disputesResolve)) {
      count('Disputes', _disputes.map((d) => d.length));
    }
    if (access.can(AdminPermission.payoutsSettle)) {
      count(
        'Payouts',
        _payouts.map(
          (p) => p.where((x) => x.status == PayoutStatus.requested).length,
        ),
      );
    }
    if (access.can(AdminPermission.refundsHandle)) {
      count('Refunds', _refunds.map((r) => r.length));
    }
    if (access.can(AdminPermission.verificationDecide)) {
      count('Verification', _verifications.map((v) => v.length));
    }
  }

  @override
  void didUpdateWidget(covariant AdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldAccess = oldWidget.access;
    final newAccess = widget.access;
    final permissionsChanged =
        oldAccess.uid != newAccess.uid ||
        oldAccess.role != newAccess.role ||
        oldAccess.permissions.length != newAccess.permissions.length ||
        !oldAccess.permissions.containsAll(newAccess.permissions);
    if (!permissionsChanged) return;
    _index = 0;
    _visited
      ..clear()
      ..add(0);
    _counts.clear();
    _load();
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

  List<_Section> _sections(AdminAccess access) => [
    if (access.can(AdminPermission.reportsView))
      _Section(
        'Overview',
        Icons.dashboard_outlined,
        _Overview(
          metrics: _metrics,
          log: _log,
          money: _money,
          queues: _queues(access),
          onOpen: _open,
          onOpenSales: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SalesReportScreen()),
          ),
        ),
      ),
    if (access.can(AdminPermission.usersManage) ||
        access.can(AdminPermission.servicesModerate))
      _Section(
        'Students',
        Icons.people_outline_rounded,
        UsersTab(
          canManageUsers: access.can(AdminPermission.usersManage),
          canModerateListings: access.can(AdminPermission.servicesModerate),
        ),
      ),
    if (access.can(AdminPermission.ordersManage))
      const _Section('Orders', Icons.receipt_long_outlined, OrdersTab()),
    if (access.can(AdminPermission.ordersManage))
      const _Section(
        'Transactions',
        Icons.swap_horiz_rounded,
        TransactionsTab(),
      ),
    if (access.can(AdminPermission.disputesResolve))
      _Section(
        'Disputes',
        Icons.gavel_rounded,
        const _Disputes(),
        count: _counts['Disputes'],
      ),
    if (access.can(AdminPermission.payoutsSettle))
      _Section(
        'Payouts',
        Icons.outbox_outlined,
        const PayoutQueue(),
        count: _counts['Payouts'],
      ),
    if (access.can(AdminPermission.refundsHandle))
      _Section(
        'Refunds',
        Icons.undo_rounded,
        const RefundQueue(),
        count: _counts['Refunds'],
      ),
    if (access.can(AdminPermission.verificationDecide))
      _Section(
        'Verification',
        Icons.verified_outlined,
        VerificationQueue(isMainAdmin: access.isMainAdmin),
        count: _counts['Verification'],
      ),
    if (access.can(AdminPermission.categoriesManage))
      const _Section('Categories', Icons.category_outlined, CategoriesTab()),
    if (access.can(AdminPermission.settingsManage))
      const _Section('Settings', Icons.tune_rounded, SettingsTab()),
    if (access.can(AdminPermission.reportsView))
      const _Section('Audit log', Icons.history_rounded, AuditTab()),
    if (access.canManageStaff)
      const _Section('Staff', Icons.admin_panel_settings_outlined, StaffTab()),
  ];

  /// The queues this person can act on, for the "needs attention" strip.
  List<_Queue> _queues(AdminAccess access) => [
    if (access.can(AdminPermission.disputesResolve))
      _Queue('Disputes', 'open dispute', _counts['Disputes']),
    if (access.can(AdminPermission.payoutsSettle))
      _Queue('Payouts', 'payout to send', _counts['Payouts']),
    if (access.can(AdminPermission.refundsHandle))
      _Queue('Refunds', 'stuck refund', _counts['Refunds']),
    if (access.can(AdminPermission.verificationDecide))
      _Queue('Verification', 'ID to check', _counts['Verification']),
  ];

  void _open(String label) {
    final sections = _sections(widget.access);
    final index = sections.indexWhere((s) => s.label == label);
    if (index >= 0) _select(index);
  }

  void _select(int index) => setState(() {
    _index = index;
    _visited.add(index);
  });

  @override
  Widget build(BuildContext context) {
    final access = widget.access;
    final sections = _sections(access);

    if (sections.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: const EmptyView(
          icon: Icons.lock_outline,
          title: 'No permissions yet',
          message:
              'You are staff, but the main admin has not assigned you '
              'anything to do.',
        ),
      );
    }
    final index = _index.clamp(0, sections.length - 1);
    final title = access.isMainAdmin ? 'Admin' : 'Staff console';
    final refresh = IconButton(
      tooltip: 'Refresh figures',
      icon: const Icon(Icons.refresh),
      onPressed: () => setState(_load),
    );

    // Lazily built: a section is instantiated the first time it is opened
    // and kept alive after, so switching back costs no reads.
    final body = IndexedStack(
      index: index,
      children: [
        for (var i = 0; i < sections.length; i++)
          _visited.contains(i) ? sections[i].body : const SizedBox.shrink(),
      ],
    );

    if (Breakpoints.isWide(context)) {
      final extended = MediaQuery.sizeOf(context).width >= 1280;
      return Scaffold(
        appBar: AppBar(title: Text(title), actions: [refresh]),
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: _select,
              extended: extended,
              minExtendedWidth: 210,
              labelType: extended
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              destinations: [
                for (final section in sections)
                  NavigationRailDestination(
                    icon: _Counted(
                      count: section.count,
                      child: Icon(section.icon),
                    ),
                    label: Text(section.label),
                  ),
              ],
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Expanded(child: ContentWidth(maxWidth: 960, child: body)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [refresh],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: ChipStrip(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            spacing: 6,
            children: [
              for (var i = 0; i < sections.length; i++)
                ChoiceChip(
                  avatar: Icon(sections[i].icon, size: 16),
                  label: _Counted(
                    count: sections[i].count,
                    inline: true,
                    child: Text(sections[i].label),
                  ),
                  selected: i == index,
                  showCheckmark: false,
                  onSelected: (_) => _select(i),
                ),
            ],
          ),
        ),
      ),
      body: body,
    );
  }
}

class _Section {
  const _Section(this.label, this.icon, this.body, {this.count});

  final String label;
  final IconData icon;
  final Widget body;

  /// Open items, for a badge on the destination. Null for sections that
  /// are not queues, or before the first snapshot.
  final int? count;
}

class _Queue {
  const _Queue(this.section, this.noun, this.count);

  final String section;
  final String noun;

  /// Null until the first snapshot arrives.
  final int? count;
}

/// A badge with the open count, or the bare child when there is nothing.
class _Counted extends StatelessWidget {
  const _Counted({
    required this.count,
    required this.child,
    this.inline = false,
  });

  final int? count;
  final Widget child;

  /// Put the number after the label instead of over the icon.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final n = count ?? 0;
    if (n == 0) return child;
    if (inline) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(width: 6),
          Badge.count(count: n),
        ],
      );
    }
    return Badge.count(count: n, child: child);
  }
}

/// What is waiting on staff right now, one tile per queue, each a door to
/// the section. Sits above the figures because it is the reason to open
/// the console.
class _NeedsAttention extends StatelessWidget {
  const _NeedsAttention({required this.queues, required this.onOpen});

  final List<_Queue> queues;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (queues.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          'Needs attention',
          padding: EdgeInsets.fromLTRB(0, 4, 0, 10),
        ),
        StatGrid(
          minTile: 150,
          tiles: [
            for (final queue in queues)
              Builder(
                builder: (context) {
                  final n = queue.count;
                  final open = n != null && n > 0;
                  return LilyPanel(
                    tint: open ? theme.colorScheme.tertiary : null,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    onTap: () => onOpen(queue.section),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(queue.section, style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          n == null ? '–' : '$n',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: open ? theme.colorScheme.tertiary : null,
                          ),
                        ),
                        Text(
                          n == null
                              ? 'loading'
                              : n == 0
                              ? 'clear'
                              : '${queue.noun}${n == 1 ? '' : 's'}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.metrics,
    required this.log,
    required this.money,
    required this.queues,
    required this.onOpen,
    required this.onOpenSales,
  });

  final Future<PlatformMetrics> metrics;
  final Stream<List<AdminAction>> log;
  final Future<MoneyHeld> money;
  final List<_Queue> queues;
  final ValueChanged<String> onOpen;
  final VoidCallback onOpenSales;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<PlatformMetrics>(
      future: metrics,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const ErrorView(
            message:
                'Could not load platform figures. Staff access is granted '
                'by an admins/{uid} document written with a service-account '
                'key.',
          );
        }
        if (!snapshot.hasData) return const LoadingView();
        final m = snapshot.data!;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _NeedsAttention(queues: queues, onOpen: onOpen),
            Text('Revenue', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Settled payments only. Money a client has promised but not yet '
              'sent is not counted here.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _Metric(
              label: 'Commission earned',
              value: _peso(m.commissionEarned),
              emphasis: true,
              caption: 'The platform\'s 5% share / View sales',
              onTap: onOpenSales,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: 'Gross value',
                    value: _peso(m.grossMerchandiseValue),
                    caption: 'Paid by clients / View sales',
                    onTap: onOpenSales,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Metric(
                    label: 'Paid to students',
                    value: _peso(m.paidOutToFreelancers),
                    caption: '${m.settledPayments} settled orders / View sales',
                    onTap: onOpenSales,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            StatGrid(
              minTile: 145,
              tiles: [
                _Metric(
                  label: 'Average order',
                  value: _peso(m.averageOrderValue),
                ),
                _Metric(
                  label: 'Completion rate',
                  value: '${m.completionRate.toStringAsFixed(0)}%',
                  caption: 'Of all orders ever placed',
                ),
                _Metric(
                  label: 'Dispute rate',
                  value: '${m.disputeRate.toStringAsFixed(1)}%',
                  caption: m.countOf(OrderStatus.disputed) == 0
                      ? 'None open'
                      : '${m.countOf(OrderStatus.disputed)} open',
                ),
              ],
            ),
            const Divider(height: 32),
            _MoneyHeldBlock(money: money),
            const Divider(height: 32),
            Text('Marketplace', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            StatGrid(
              minTile: 145,
              tiles: [
                _Metric(label: 'Students', value: '${m.users}'),
                _Metric(
                  label: 'Listings',
                  value: '${m.publishedServices}',
                  // Only worth saying when the two actually differ.
                  caption: m.services == m.publishedServices
                      ? null
                      : '${m.services} including drafts',
                ),
                _Metric(label: 'Orders', value: '${m.orders}'),
                _Metric(label: 'Reviews', value: '${m.reviews}'),
              ],
            ),
            const Divider(height: 32),
            Text('Orders by stage', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            _StatusBreakdown(metrics: m),
            const Divider(height: 32),
            Text('Recent staff actions', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Append-only. Entries cannot be edited or removed, including by '
              'the person who made them.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            _ActionLog(log: log),
          ],
        );
      },
    );
  }
}

/// A horizontal bar per order stage.
///
/// Deliberately not a pie or donut: the question staff ask is "where does work
/// pile up", which is a comparison of lengths, and lengths are easier to
/// compare than angles.
/// The platform's liabilities: money that belongs to someone else and must
/// be payable on demand. Reconcile against the gateway's settlement report
/// before every payout run; the two should agree to the peso.
class _MoneyHeldBlock extends StatelessWidget {
  const _MoneyHeldBlock({required this.money});

  final Future<MoneyHeld> money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<MoneyHeld>(
      future: money,
      builder: (context, snapshot) {
        final m = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Money held', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Belongs to students, not the platform. Check it against the '
              'Xendit balance before a payout run.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (snapshot.hasError)
              Text(
                'Could not load held money.',
                style: theme.textTheme.bodySmall,
              )
            else if (m == null)
              const LinearProgressIndicator(minHeight: 2)
            else ...[
              _Metric(
                label: 'Total liabilities',
                value: _peso(m.liabilities),
                emphasis: true,
                caption: 'Held on orders plus every wallet balance',
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      label: 'Held on orders',
                      value: _peso(m.heldGross),
                      caption: '${m.heldOrders} paid, not yet released',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(
                      label: 'Available to sellers',
                      value: _peso(m.walletAvailable),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      label: 'Clearing',
                      value: _peso(m.walletClearing),
                      caption: 'New sellers, 7 days',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(
                      label: 'Payouts requested',
                      value: _peso(m.walletPending),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(
                      label: 'Refunds stuck',
                      value: _peso(m.stuckRefundAmount),
                      caption: m.stuckRefunds == 0
                          ? 'None'
                          : '${m.stuckRefunds} need a human',
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _StatusBreakdown extends StatelessWidget {
  const _StatusBreakdown({required this.metrics});

  final PlatformMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries =
        OrderStatus.values
            .map((s) => (status: s, count: metrics.countOf(s)))
            .where((e) => e.count > 0)
            .toList()
          ..sort((a, b) => b.count.compareTo(a.count));

    if (entries.isEmpty) {
      return Text('No orders yet.', style: theme.textTheme.bodySmall);
    }
    final largest = entries.first.count;

    return Column(
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 132,
                  child: Text(
                    entry.status.label,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: entry.count / largest,
                      minHeight: 8,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: entry.status == OrderStatus.disputed
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    '${entry.count}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.caption,
    this.emphasis = false,
    this.onTap,
  });

  final String label;
  final String value;
  final String? caption;
  final bool emphasis;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tile = StatTile(
      label: label,
      value: value,
      caption: caption,
      emphasis: emphasis,
    );
    if (onTap == null) return tile;
    return Semantics(
      button: true,
      label: '$label. Open sales report.',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusControl),
        child: tile,
      ),
    );
  }
}

class _ActionLog extends StatelessWidget {
  const _ActionLog({required this.log});

  final Stream<List<AdminAction>> log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<AdminAction>>(
      stream: log,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <AdminAction>[];
        if (items.isEmpty) {
          return Text('Nothing yet.', style: theme.textTheme.bodySmall);
        }
        return Column(
          children: [
            for (final entry in items.take(10))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.label, style: theme.textTheme.titleSmall),
                          if (entry.note.isNotEmpty)
                            Text(entry.note, style: theme.textTheme.bodySmall),
                          UserName(
                            uid: entry.actorId,
                            prefix: 'by ',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      DateFormat.yMMMd().add_jm().format(entry.createdAt),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Disputes extends StatelessWidget {
  const _Disputes();
  @override
  Widget build(BuildContext context) => PaginatedList<WorkOrder>(
    load: (limit) =>
        context.read<AdminRepository>().watchDisputes(limit: limit),
    emptyMessage: 'No open disputes. Nothing needs your attention.',
    itemBuilder: (context, order) =>
        _DisputeCard(order: order, me: context.read<AuthController>().uid),
  );
}

class _DisputeCard extends StatelessWidget {
  const _DisputeCard({required this.order, required this.me});

  final WorkOrder order;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    order.serviceTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(_peso(order.price), style: AppTheme.price(context)),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                UserName(
                  uid: order.clientId,
                  prefix: 'Buyer: ',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(width: 12),
                UserName(
                  uid: order.freelancerId,
                  prefix: 'Seller: ',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(order.requirements, style: theme.textTheme.bodySmall),
            if (order.disputeReason case final reason?) ...[
              const SizedBox(height: 8),
              Text('Reported problem', style: theme.textTheme.labelMedium),
              const SizedBox(height: 2),
              Text(reason, style: theme.textTheme.bodySmall),
            ],
            if (DisputePolicy.needsSecondOpinion(order.price)) ...[
              const SizedBox(height: 8),
              _SecondOpinionNote(order: order, me: me),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final openOrder = OutlinedButton.icon(
                  onPressed: () =>
                      context.push('/order/${order.id}?staffView=true'),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Review order'),
                );
                final refund = OutlinedButton.icon(
                  onPressed: () => _act(context, OrderStatus.cancelled),
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: Text(_label(OrderStatus.cancelled, 'Refund buyer')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                );
                final release = FilledButton.icon(
                  onPressed: () => _act(context, OrderStatus.completed),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: Text(
                    _label(OrderStatus.completed, 'Release to seller'),
                  ),
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      openOrder,
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: refund),
                          const SizedBox(width: 8),
                          Expanded(child: release),
                        ],
                      ),
                    ],
                  );
                }
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [openOrder, refund, release],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Below the threshold a button closes the dispute; above it the same
  /// button either proposes or, when another staff member already proposed
  /// this outcome, confirms.
  bool _closes(OrderStatus outcome) =>
      me != null && order.canResolveDispute(me!, outcome);

  String _label(OrderStatus outcome, String plain) {
    if (!DisputePolicy.needsSecondOpinion(order.price)) return plain;
    return _closes(outcome) ? 'Confirm: $plain' : 'Propose: $plain';
  }

  Future<void> _act(BuildContext context, OrderStatus outcome) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ResolutionDialog(outcome: outcome),
    );
    if (note == null || !context.mounted) return;

    final uid = me;
    if (uid == null) return;
    final repository = context.read<AdminRepository>();
    try {
      if (_closes(outcome)) {
        await repository.resolveDispute(
          orderId: order.id,
          actorId: uid,
          outcome: outcome,
          note: note,
        );
      } else {
        await repository.proposeDisputeOutcome(
          orderId: order.id,
          actorId: uid,
          outcome: outcome,
          note: note,
        );
      }
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }
}

/// Where a large dispute stands: waiting for a proposal, waiting for a
/// second staff member, or ready for this one to confirm.
class _SecondOpinionNote extends StatelessWidget {
  const _SecondOpinionNote({required this.order, required this.me});

  final WorkOrder order;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proposal = order.disputeResolution;
    final String text;
    if (proposal == null) {
      text =
          'Two staff members decide disputes of '
          '${_peso(DisputePolicy.secondOpinionFrom)} or more. Propose an '
          'outcome and a colleague confirms it.';
    } else if (proposal.proposedBy == me) {
      text =
          'You proposed "${proposal.outcome == OrderStatus.completed ? 'release to seller' : 'refund buyer'}". '
          'Waiting for another staff member to confirm.';
    } else {
      text =
          'A colleague proposed "${proposal.outcome == OrderStatus.completed ? 'release to seller' : 'refund buyer'}". '
          'Confirm it, or propose the other outcome.';
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 16,
          color: theme.colorScheme.tertiary,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

class _ResolutionDialog extends StatefulWidget {
  const _ResolutionDialog({required this.outcome});

  final OrderStatus outcome;

  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
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
    final releasing = widget.outcome == OrderStatus.completed;
    return AlertDialog(
      title: Text(releasing ? 'Release to seller?' : 'Refund the buyer?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            releasing
                ? 'The order closes as completed. A gateway payment held by '
                      "the platform is released to the seller's balance, "
                      'minus commission. This cannot be undone.'
                : 'The order closes as cancelled. A gateway payment held by '
                      'the platform is refunded to the buyer automatically; a '
                      'manual settlement has to be returned outside the app. '
                      'This cannot be undone.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'What did you find, and what decided it?',
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
          // A decision this final should carry a reason into the audit log.
          onPressed: _controller.text.trim().length < 10
              ? null
              : () => Navigator.pop(context, _controller.text.trim()),
          child: Text(releasing ? 'Release' : 'Refund'),
        ),
      ],
    );
  }
}
