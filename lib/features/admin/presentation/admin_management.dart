import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/platform/platform_repository.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/paginated_list.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../orders/domain/order.dart';
import '../../orders/presentation/widgets/order_status_chip.dart';
import '../../payments/domain/payment.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../../services/domain/freelance_service.dart';
import '../data/admin_repository.dart';
import '../domain/admin_access.dart';

String _when(DateTime at) => DateFormat.yMMMd().add_jm().format(at);

// ---------------------------------------------------------------------------
// Students (users.manage)
// ---------------------------------------------------------------------------

class UsersTab extends StatefulWidget {
  const UsersTab({
    super.key,
    required this.canManageUsers,
    required this.canModerateListings,
  });

  final bool canManageUsers;
  final bool canModerateListings;

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  final _search = TextEditingController();
  Timer? _searchDebounce;
  String _activeQuery = '';

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _query(String value) {
    _searchDebounce?.cancel();
    final query = value.trim().toLowerCase();
    if (query == _activeQuery) return;
    setState(() {
      _activeQuery = query;
    });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    setState(() {});
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _query(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search by display name',
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear student search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _query('');
                        setState(() {});
                      },
                    ),
            ),
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: _query,
          ),
        ),
        Expanded(
          child: PaginatedList<UserProfile>(
            key: ValueKey(_activeQuery),
            load: (limit) => context.read<AdminRepository>().watchUsers(
              query: _activeQuery,
              limit: limit,
            ),
            emptyMessage: 'No students match.',
            itemBuilder: (context, profile) => _UserRow(
              profile: profile,
              canManageUsers: widget.canManageUsers,
              canModerateListings: widget.canModerateListings,
            ),
          ),
        ),
      ],
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.profile,
    required this.canManageUsers,
    required this.canModerateListings,
  });

  final UserProfile profile;
  final bool canManageUsers;
  final bool canModerateListings;

  Future<void> _toggle(BuildContext context) async {
    final suspending = !profile.suspended;
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _NoteDialog(
        title: suspending ? 'Suspend ${profile.displayName}?' : 'Reinstate?',
        hint: suspending
            ? 'Why. A suspended student can read but not order, sell or message.'
            : 'Why the suspension is lifted.',
        action: suspending ? 'Suspend' : 'Reinstate',
      ),
    );
    if (note == null || !context.mounted) return;
    try {
      await context.read<AdminRepository>().setSuspended(
        uid: profile.uid,
        actorId: context.read<AuthController>().uid!,
        suspended: suspending,
        note: note,
      );
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: UserAvatar(name: profile.displayName),
        title: Row(
          children: [
            Flexible(child: Text(profile.displayName)),
            if (profile.suspended)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  'SUSPENDED',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Text(
          [
            profile.email ?? 'no email on file',
            if (profile.studentId != null) 'no. ${profile.studentId}',
            if (profile.academics.isNotEmpty) profile.academics,
            'joined ${DateFormat.yMMMd().format(profile.createdAt)}',
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'view') {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _StudentProfileScreen(
                    profile: profile,
                    canManageUsers: canManageUsers,
                    canModerateListings: canModerateListings,
                  ),
                ),
              );
            }
            if (action == 'toggle') _toggle(context);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'view', child: Text('View profile')),
            if (canManageUsers)
              PopupMenuItem(
                value: 'toggle',
                child: Text(profile.suspended ? 'Reinstate' : 'Suspend'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Staff-only profile view. Moderators see every listing from this student
/// here, so a listing decision is made with the owner's account context
/// instead of from a disconnected platform-wide queue.
class _StudentProfileScreen extends StatelessWidget {
  _StudentProfileScreen({
    required this.profile,
    required this.canManageUsers,
    required this.canModerateListings,
  });

  final _listingsKey = GlobalKey<_StudentListingsState>();
  final UserProfile profile;
  final bool canManageUsers;
  final bool canModerateListings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Student profile')),
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical &&
              notification.metrics.extentAfter < 300) {
            _listingsKey.currentState?._loadMore();
          }
          return false;
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        UserAvatar(name: profile.displayName, radius: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.displayName,
                                style: theme.textTheme.titleLarge,
                              ),
                              if (profile.email case final email?)
                                Text(email, style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      profile.suspended
                          ? 'Account suspended'
                          : 'Account active',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: profile.suspended
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                    ),
                    if (profile.studentId != null ||
                        profile.academics.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          [
                            if (profile.studentId != null)
                              'no. ${profile.studentId}',
                            if (profile.academics.isNotEmpty) profile.academics,
                          ].join(' / '),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    if (profile.bio.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(profile.bio, style: theme.textTheme.bodyMedium),
                    ],
                  ],
                ),
              ),
            ),
            if (canModerateListings) ...[
              const SizedBox(height: 20),
              Text('Listings', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              _StudentListings(key: _listingsKey, sellerId: profile.uid),
            ] else if (canManageUsers) ...[
              const SizedBox(height: 20),
              Text(
                'Account controls are available from the Students list.',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StudentListings extends StatefulWidget {
  const _StudentListings({super.key, required this.sellerId});

  final String sellerId;

  @override
  State<_StudentListings> createState() => _StudentListingsState();
}

class _StudentListingsState extends State<_StudentListings> {
  int _limit = 50;
  bool _hasMore = false;
  bool _loadingMore = false;
  late Stream<List<FreelanceService>> _listings = _watch();
  Stream<List<FreelanceService>> _watch() => context
      .read<AdminRepository>()
      .watchServicesForSeller(widget.sellerId, limit: _limit)
      .map((items) {
        _hasMore = items.length >= _limit;
        _loadingMore = false;
        return items;
      });
  void _loadMore() {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _limit += 50;
      _loadingMore = true;
      _listings = _watch();
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<FreelanceService>>(
      stream: _listings,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const ErrorView(
            message: 'Could not load this student\'s listings.',
          );
        }
        if (!snapshot.hasData) return const LoadingView();
        final items = snapshot.data!;
        if (items.isEmpty) {
          return const EmptyView(
            message: 'This student has no listings.',
            icon: Icons.storefront_outlined,
          );
        }
        return Column(
          children: [
            for (final service in items) _StudentListingCard(service: service),
            if (_hasMore || _loadingMore)
              TextButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: Text(_loadingMore ? 'Loading?' : 'Load more listings'),
              ),
          ],
        );
      },
    );
  }
}

class _StudentListingCard extends StatelessWidget {
  const _StudentListingCard({required this.service});

  final FreelanceService service;

  Future<void> _takeDown(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _TakedownDialog(title: service.title),
    );
    if (note == null || !context.mounted) return;
    final actorId = context.read<AuthController>().uid;
    if (actorId == null) return;
    try {
      await context.read<AdminRepository>().takeDownService(
        serviceId: service.id,
        actorId: actorId,
        note: note,
      );
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(service.title),
        subtitle: Text(
          '${pesos(service.startingPrice)} / ${service.status.name}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: service.isPublished
            ? TextButton(
                onPressed: () => _takeDown(context),
                child: const Text('Take down'),
              )
            : null,
        onTap: () => context.push('/service/${service.id}'),
      ),
    );
  }
}

class _TakedownDialog extends StatefulWidget {
  const _TakedownDialog({required this.title});

  final String title;

  @override
  State<_TakedownDialog> createState() => _TakedownDialogState();
}

class _TakedownDialogState extends State<_TakedownDialog> {
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
      title: const Text('Take this listing down?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"${widget.title}" is paused and leaves the marketplace. The '
            'seller keeps the listing and can republish it.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 2,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'Why is this coming down?',
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
          onPressed: _controller.text.trim().length < 10
              ? null
              : () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Take down'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Orders and transactions (orders.manage)
// ---------------------------------------------------------------------------

class OrdersTab extends StatefulWidget {
  const OrdersTab({super.key});

  @override
  State<OrdersTab> createState() => _OrdersTabState();
}

class _OrdersTabState extends State<OrdersTab> {
  OrderStatus? _status;

  void _filter(OrderStatus? status) {
    setState(() {
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _status == null,
                onSelected: (_) => _filter(null),
              ),
              for (final status in OrderStatus.values)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(status.label),
                    selected: _status == status,
                    onSelected: (_) => _filter(status),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: PaginatedList<WorkOrder>(
            key: ValueKey(_status),
            load: (limit) => context.read<AdminRepository>().watchOrders(
              status: _status,
              limit: limit,
            ),
            emptyMessage: 'No orders here.',
            itemBuilder: (context, order) {
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(order.serviceTitle),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          UserName(
                            uid: order.clientId,
                            prefix: 'Buyer: ',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 10),
                          UserName(
                            uid: order.freelancerId,
                            prefix: 'Seller: ',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      Text(
                        '${pesos(order.price)}'
                        '${order.isNegotiated ? ' · from an offer' : ''}'
                        ' · ${_when(order.updatedAt)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  trailing: OrderStatusChip(status: order.status),
                  onTap: () =>
                      context.push('/order/${order.id}?staffView=true'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TransactionsTab extends StatefulWidget {
  const TransactionsTab({super.key});

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaginatedList<Payment>(
      load: (limit) =>
          context.read<AdminRepository>().watchPayments(limit: limit),
      emptyMessage: 'No payments yet.',
      itemBuilder: (context, p) {
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            title: Text(
              '${pesos(p.amount)} · ${p.status.label}'
              '${p.holdStatus == null ? '' : ' · ${p.holdStatus!.name}'}',
            ),
            subtitle: Text(
              '${p.method.label}${p.verified ? ', gateway-verified' : ''} · '
              'commission ${pesos(p.commission)} · '
              '${_when(p.updatedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            trailing: Text(
              p.orderId.length > 8
                  ? '…${p.orderId.substring(p.orderId.length - 6)}'
                  : p.orderId,
              style: theme.textTheme.labelSmall,
            ),
            onTap: () => context.push('/order/${p.orderId}?staffView=true'),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Staff (main admin)
// ---------------------------------------------------------------------------

class StaffTab extends StatefulWidget {
  const StaffTab({super.key});

  @override
  State<StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends State<StaffTab> {
  late final Stream<List<AdminAccess>> _staff = context
      .read<AdminRepository>()
      .watchStaff();

  Future<void> _grant() async {
    final repository = context.read<AdminRepository>();
    final user = await showDialog<UserProfile>(
      context: context,
      builder: (_) => _GrantStaffDialog(repository: repository),
    );
    if (user == null || !mounted) return;
    final actorId = context.read<AuthController>().uid;
    if (user.uid == actorId) {
      showFailureSnackBar(
        context,
        'You are the main admin and already hold every permission.',
      );
      return;
    }
    final existing = await repository.access(user.uid);
    if (!mounted) return;
    if (existing?.isMainAdmin ?? false) {
      showFailureSnackBar(
        context,
        'The main admin already holds every permission.',
      );
      return;
    }
    await _edit(
      existing == null
          ? AdminAccess(
              uid: user.uid,
              role: AdminRole.staff,
              permissions: const {},
              displayName: user.displayName,
              email: user.email,
            )
          : AdminAccess(
              uid: existing.uid,
              role: existing.role,
              permissions: existing.permissions,
              displayName: user.displayName,
              email: user.email,
              createdAt: existing.createdAt,
            ),
      isNew: existing == null,
    );
  }

  Future<void> _edit(AdminAccess member, {required bool isNew}) async {
    final permissions = await showDialog<Set<AdminPermission>>(
      context: context,
      builder: (_) => _PermissionsDialog(member: member),
    );
    if (permissions == null || !mounted) return;
    try {
      await context.read<AdminRepository>().setStaff(
        uid: member.uid,
        actorId: context.read<AuthController>().uid!,
        permissions: permissions,
        createdAt: member.createdAt,
        displayName: member.displayName,
        email: member.email,
        isNew: isNew,
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  Future<void> _revoke(AdminAccess member) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Revoke ${member.displayName ?? member.uid}?'),
        content: const Text('They lose every staff permission immediately.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AdminRepository>().revokeStaff(
        uid: member.uid,
        actorId: context.read<AuthController>().uid!,
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = context.read<AuthController>().uid;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _grant,
        icon: const Icon(Icons.person_add_alt_outlined),
        label: const Text('Grant access'),
      ),
      body: StreamBuilder<List<AdminAccess>>(
        stream: _staff,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const ErrorView(message: 'Could not load staff.');
          }
          if (!snapshot.hasData) return const LoadingView();
          final staff = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            children: [
              Text(
                'The main admin holds every permission and is granted with a '
                'service-account key. Staff hold only what is ticked here, '
                'and the rules and backend check each action against it.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final member in staff)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      member.isMainAdmin
                          ? Icons.shield_outlined
                          : Icons.badge_outlined,
                    ),
                    title: UserName(
                      uid: member.uid,
                      fallback: member.displayName ?? member.uid,
                    ),
                    subtitle: Text(
                      member.isMainAdmin
                          ? 'Main admin · every permission'
                          : member.permissions.isEmpty
                          ? 'Staff · no permissions yet'
                          : 'Staff · ${member.permissions.map((p) => p.label).join(', ')}',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: member.isMainAdmin || member.uid == me
                        ? null
                        : PopupMenuButton<String>(
                            onSelected: (action) => action == 'edit'
                                ? _edit(member, isNew: false)
                                : _revoke(member),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit permissions'),
                              ),
                              PopupMenuItem(
                                value: 'revoke',
                                child: Text('Revoke'),
                              ),
                            ],
                          ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({required this.member});

  final AdminAccess member;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late final Set<AdminPermission> _selected = {...widget.member.permissions};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.member.displayName ?? 'Permissions'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in AdminPermission.values)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p.label),
                subtitle: Text(p.description),
                value: _selected.contains(p),
                onChanged: (on) => setState(() {
                  on == true ? _selected.add(p) : _selected.remove(p);
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _GrantStaffDialog extends StatefulWidget {
  const _GrantStaffDialog({required this.repository});

  final AdminRepository repository;

  @override
  State<_GrantStaffDialog> createState() => _GrantStaffDialogState();
}

class _GrantStaffDialogState extends State<_GrantStaffDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  var _request = 0;
  var _loading = false;
  var _closing = false;
  List<UserProfile> _matches = const [];
  AppFailure? _failure;

  void _prepareToClose() {
    _closing = true;
    _request++;
    _debounce?.cancel();
  }

  bool _canUpdateFor(int request) =>
      mounted &&
      !_closing &&
      request == _request &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  void _choose(UserProfile user) {
    _prepareToClose();
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(user);
  }

  void _cancel() {
    _prepareToClose();
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _search(String value) {
    if (_closing) return;
    _debounce?.cancel();
    final prefix = value.trim();
    final request = ++_request;
    if (prefix.length < 3) {
      setState(() {
        _loading = false;
        _matches = const [];
        _failure = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _matches = const [];
      _failure = null;
    });
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final matches = await widget.repository.searchUsersByEmailPrefix(
          prefix,
        );
        if (!_canUpdateFor(request)) return;
        setState(() {
          _matches = matches;
          _loading = false;
        });
      } on AppFailure catch (failure) {
        if (!_canUpdateFor(request)) return;
        setState(() {
          _failure = failure;
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasQuery = _controller.text.trim().length >= 3;
    return PopScope<UserProfile?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _prepareToClose();
      },
      child: AlertDialog(
        title: const Text('Grant staff access'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                onChanged: _search,
                decoration: const InputDecoration(
                  labelText: 'UM email',
                  hintText: 'Start typing an email address',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              if (_loading) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(minHeight: 2),
              ],
              if (_failure case final failure?) ...[
                const SizedBox(height: 12),
                Text(
                  failure.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ] else if (hasQuery && !_loading && _matches.isEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'No signed-in accounts match that email prefix.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (_matches.isNotEmpty) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _matches.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final user = _matches[index];
                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            backgroundImage: user.photoUrl == null
                                ? null
                                : NetworkImage(user.photoUrl!),
                            child: user.photoUrl == null
                                ? const Icon(Icons.person_outline_rounded)
                                : null,
                          ),
                          title: Text(
                            user.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            user.email ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _choose(user),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: _cancel, child: const Text('Cancel'))],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Categories (categories.manage) and settings (settings.manage)
// ---------------------------------------------------------------------------

class CategoriesTab extends StatefulWidget {
  const CategoriesTab({super.key});

  @override
  State<CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends State<CategoriesTab> {
  late final Stream<List<Category>> _categories = context
      .read<AdminRepository>()
      .watchAllCategories();

  Future<void> _edit(Category? existing, int nextOrder) async {
    final result = await showDialog<Category>(
      context: context,
      builder: (_) => _CategoryDialog(existing: existing, nextOrder: nextOrder),
    );
    if (result == null || !mounted) return;
    try {
      await context.read<AdminRepository>().saveCategory(
        id: result.id,
        label: result.label,
        active: result.active,
        sortOrder: result.sortOrder,
        actorId: context.read<AuthController>().uid!,
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Category>>(
      stream: _categories,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const ErrorView(message: 'Could not load categories.');
        }
        final categories = snapshot.data ?? const <Category>[];
        final builtIn = {for (final c in kServiceCategories) c.id};
        final nextOrder = categories.isEmpty
            ? kServiceCategories.length
            : categories
                      .map((c) => c.sortOrder)
                      .reduce((a, b) => a > b ? a : b) +
                  1;
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(null, nextOrder),
            icon: const Icon(Icons.add),
            label: const Text('Add category'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            children: [
              Text(
                'The app ships with ${kServiceCategories.length} built-in '
                'categories. Entries here override or extend them; a retired '
                'category disappears from the filters but its listings keep '
                'their label.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final c in kServiceCategories)
                if (!categories.any((o) => o.id == c.id))
                  ListTile(
                    leading: const Icon(Icons.lock_outline, size: 18),
                    title: Text(c.label),
                    subtitle: Text('Built-in · ${c.id}'),
                    trailing: TextButton(
                      onPressed: () => _edit(
                        Category(
                          id: c.id,
                          label: c.label,
                          active: true,
                          sortOrder: 0,
                        ),
                        nextOrder,
                      ),
                      child: const Text('Override'),
                    ),
                  ),
              for (final c in categories)
                ListTile(
                  leading: Icon(
                    c.active ? Icons.label_outline : Icons.label_off_outlined,
                    size: 18,
                  ),
                  title: Text(c.label),
                  subtitle: Text(
                    '${c.id}${builtIn.contains(c.id) ? ' · overrides built-in' : ''}'
                    '${c.active ? '' : ' · retired'} · order ${c.sortOrder}',
                  ),
                  trailing: TextButton(
                    onPressed: () => _edit(c, nextOrder),
                    child: const Text('Edit'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({required this.existing, required this.nextOrder});

  final Category? existing;
  final int nextOrder;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final _id = TextEditingController(text: widget.existing?.id ?? '');
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _order = TextEditingController(
    text: '${widget.existing?.sortOrder ?? widget.nextOrder}',
  );
  late bool _active = widget.existing?.active ?? true;

  @override
  void dispose() {
    _id.dispose();
    _label.dispose();
    _order.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New category' : 'Edit category'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _id,
            enabled: widget.existing == null,
            decoration: const InputDecoration(
              labelText: 'Id',
              helperText: 'Lowercase, e.g. 3d-printing. Cannot change later.',
            ),
          ),
          TextField(
            controller: _label,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Label'),
          ),
          TextField(
            controller: _order,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Sort order'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            Category(
              id: _id.text,
              label: _label.text,
              active: _active,
              sortOrder: int.tryParse(_order.text.trim()) ?? widget.nextOrder,
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _announcement = TextEditingController();
  bool _paused = false;
  bool _loaded = false;
  String _expiryPreset = 'Never';
  DateTime? _customExpiry;

  @override
  void dispose() {
    _announcement.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final expiry = switch (_expiryPreset) {
      '1 hour' => DateTime.now().add(const Duration(hours: 1)),
      '6 hours' => DateTime.now().add(const Duration(hours: 6)),
      '12 hours' => DateTime.now().add(const Duration(hours: 12)),
      '24 hours' => DateTime.now().add(const Duration(hours: 24)),
      'Custom' => _customExpiry,
      _ => null,
    };
    if (_expiryPreset == 'Custom' &&
        (expiry == null || !expiry.isAfter(DateTime.now()))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a future expiry date and time.')),
      );
      return;
    }
    try {
      await context.read<AdminRepository>().saveSettings(
        settings: PlatformSettings(
          announcement: _announcement.text,
          ordersPaused: _paused,
          announcementExpiresAt: expiry,
        ),
        actorId: context.read<AuthController>().uid!,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Settings saved.')));
      }
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<PlatformSettings>(
      stream: context.read<PlatformSettingsRepository>().watch(),
      builder: (context, snapshot) {
        final settings = snapshot.data ?? PlatformSettings.none;
        if (!_loaded && snapshot.hasData) {
          _loaded = true;
          _announcement.text = settings.announcement;
          _paused = settings.ordersPaused;
          _expiryPreset = settings.announcementExpiresAt == null
              ? 'Never'
              : 'Custom';
          _customExpiry = settings.announcementExpiresAt;
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Announcement', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Shown as a banner on every tab while non-empty.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _announcement,
              maxLength: 300,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText:
                    'e.g. Payouts are delayed this week due to enrollment.',
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _expiryPreset,
              decoration: const InputDecoration(
                labelText: 'Clear announcement',
              ),
              items: const [
                DropdownMenuItem(value: 'Never', child: Text('Never')),
                DropdownMenuItem(
                  value: '1 hour',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('After 1 hour'),
                  ),
                ),
                DropdownMenuItem(
                  value: '6 hours',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('After 6 hours'),
                  ),
                ),
                DropdownMenuItem(
                  value: '12 hours',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('After 12 hours'),
                  ),
                ),
                DropdownMenuItem(
                  value: '24 hours',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text('After 24 hours'),
                  ),
                ),
                DropdownMenuItem(
                  value: 'Custom',
                  child: Text('Choose date and time'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _expiryPreset = value ?? 'Never'),
            ),
            if (_expiryPreset == 'Custom') ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(
                  _customExpiry == null
                      ? 'Choose expiry'
                      : DateFormat.yMMMd().add_jm().format(_customExpiry!),
                ),
                onPressed: () async {
                  final date = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                    initialDate:
                        _customExpiry != null &&
                            _customExpiry!.isAfter(DateTime.now())
                        ? _customExpiry!
                        : DateTime.now().add(const Duration(days: 1)),
                  );
                  if (!context.mounted || date == null) return;
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(
                      _customExpiry ?? DateTime.now(),
                    ),
                  );
                  if (!context.mounted || time == null) return;
                  setState(
                    () => _customExpiry = DateTime(
                      date.year,
                      date.month,
                      date.day,
                      time.hour,
                      time.minute,
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pause new orders'),
              subtitle: const Text(
                'Refused by the rules platform-wide while on. Orders already '
                'placed keep moving; payments and payouts are unaffected.',
              ),
              value: _paused,
              onChanged: (v) => setState(() => _paused = v),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save settings'),
              onPressed: _save,
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Audit log (reports.view)
// ---------------------------------------------------------------------------

class AuditTab extends StatefulWidget {
  const AuditTab({super.key});

  @override
  State<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<AuditTab> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PaginatedList<AuditEntry>(
      load: (limit) =>
          context.read<AdminRepository>().watchAuditLog(limit: limit),
      emptyMessage: 'Nothing recorded yet.',
      itemBuilder: (context, e) {
        return ListTile(
          dense: true,
          leading: Icon(_iconFor(e.action), size: 18),
          title: Text(e.label),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AuditSubjectLabel(entry: e, style: theme.textTheme.bodySmall),
              _AuditActorLabel(
                actorId: e.actorId,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          trailing: Text(_when(e.createdAt), style: theme.textTheme.labelSmall),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AuditEntryDetailScreen(entry: e),
            ),
          ),
        );
      },
    );
  }

  static IconData _iconFor(String action) {
    final group = action.split('.').first;
    return switch (group) {
      'auth' || 'user' => Icons.person_outline,
      'service' => Icons.storefront_outlined,
      'offer' => Icons.request_quote_outlined,
      'order' => Icons.receipt_long_outlined,
      'payment' || 'payout' => Icons.payments_outlined,
      'staff' => Icons.badge_outlined,
      'settings' || 'category' => Icons.tune_outlined,
      _ => Icons.history_outlined,
    };
  }
}

class AuditEntryDetailScreen extends StatelessWidget {
  const AuditEntryDetailScreen({super.key, required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Audit entry')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(entry.label, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(_when(entry.createdAt), style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
          Text('Subject', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          _AuditSubjectLabel(entry: entry, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
          Text('Performed by', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          _AuditActorLabel(
            actorId: entry.actorId,
            style: theme.textTheme.bodyLarge,
          ),
          if (entry.details.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Details', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    for (final detail in entry.details.entries)
                      _AuditDetailValue(
                        detailKey: detail.key,
                        value: detail.value,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuditSubjectLabel extends StatefulWidget {
  const _AuditSubjectLabel({required this.entry, required this.style});

  final AuditEntry entry;
  final TextStyle? style;

  @override
  State<_AuditSubjectLabel> createState() => _AuditSubjectLabelState();
}

class _AuditSubjectLabelState extends State<_AuditSubjectLabel> {
  late Future<AuditSubject> _subject;

  @override
  void initState() {
    super.initState();
    _subject = _resolve();
  }

  @override
  void didUpdateWidget(_AuditSubjectLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) _subject = _resolve();
  }

  Future<AuditSubject> _resolve() =>
      context.read<AdminRepository>().auditSubject(widget.entry);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AuditSubject>(
      future: _subject,
      builder: (context, snapshot) {
        final subject = snapshot.data;
        final label = snapshot.hasError
            ? 'Subject unavailable'
            : subject == null
            ? 'Resolving subject...'
            : subject.kind == null
            ? subject.label
            : '${subject.kind}: ${subject.label}';
        return Text(
          label,
          style: widget.style,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

class _AuditActorLabel extends StatelessWidget {
  const _AuditActorLabel({required this.actorId, required this.style});

  final String actorId;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final fallback = switch (actorId) {
      'system' => 'System',
      'staff' => 'Staff',
      'participant' => 'Order participant',
      'xendit' => 'Xendit',
      _ => 'Student',
    };
    if (actorId == 'system' ||
        actorId == 'staff' ||
        actorId == 'participant' ||
        actorId == 'xendit') {
      return Text('By $fallback', style: style);
    }
    return UserName(
      uid: actorId,
      prefix: 'By ',
      fallback: fallback,
      style: style,
    );
  }
}

class _AuditReferenceLabel extends StatefulWidget {
  const _AuditReferenceLabel({
    required this.type,
    required this.id,
    required this.style,
  });

  final String type;
  final String id;
  final TextStyle? style;

  @override
  State<_AuditReferenceLabel> createState() => _AuditReferenceLabelState();
}

class _AuditReferenceLabelState extends State<_AuditReferenceLabel> {
  late Future<AuditSubject> _subject;

  @override
  void initState() {
    super.initState();
    _subject = context.read<AdminRepository>().auditSubjectFor(
      widget.type,
      widget.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AuditSubject>(
      future: _subject,
      builder: (context, snapshot) => Text(
        snapshot.hasError
            ? 'Linked record unavailable'
            : snapshot.data?.label ?? 'Resolving linked record...',
        style: widget.style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _AuditDetailValue extends StatelessWidget {
  const _AuditDetailValue({required this.detailKey, required this.value});

  final String detailKey;
  final dynamic value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = detailKey.replaceAllMapped(
      RegExp(r'([A-Z])'),
      (match) => ' ${match.group(0)!.toLowerCase()}',
    );
    final referenceType = switch (detailKey) {
      'clientId' || 'freelancerId' || 'userId' || 'uid' => 'user',
      'serviceId' => 'service',
      'offerId' => 'offer',
      'orderId' => 'order',
      'paymentId' => 'payment',
      'payoutId' => 'payout',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(
            child: referenceType != null && value is String
                ? _AuditReferenceLabel(
                    type: referenceType,
                    id: value,
                    style: theme.textTheme.bodyMedium,
                  )
                : Text(
                    detailKey.endsWith('Id') && value is String
                        ? 'Linked record'
                        : '$value',
                    style: theme.textTheme.bodyMedium,
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({
    required this.title,
    required this.hint,
    required this.action,
  });

  final String title;
  final String hint;
  final String action;
  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
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
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 500,
        decoration: InputDecoration(hintText: widget.hint),
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
          child: Text(widget.action),
        ),
      ],
    );
  }
}
