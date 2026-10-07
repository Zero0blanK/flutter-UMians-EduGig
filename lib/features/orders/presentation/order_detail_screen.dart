import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/storage/attachment.dart';
import '../../../core/storage/attachment_view.dart';
import '../../../core/storage/storage_repository.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../admin/data/admin_repository.dart';
import '../../admin/domain/admin_access.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/domain/payment.dart';
import '../../payments/presentation/payment_section.dart';
import '../../reviews/data/review_repository.dart';
import '../../admin/presentation/dispute_chat_review.dart';
import '../data/order_repository.dart';
import '../domain/delivery.dart';
import '../domain/order.dart';
import 'widgets/order_status_chip.dart';

/// One order, top to bottom: where it stands, what happens next, the terms,
/// the brief, the deliveries, the money. The actions this person can take
/// right now sit in a bar at the bottom and nowhere else.
class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({
    super.key,
    required this.orderId,
    this.staffReadOnly = false,
  });

  final String orderId;

  /// Admin-console links set this even when a staff account also happens to
  /// own the order, so the console cannot become a payment action surface.
  final bool staffReadOnly;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen>
    with WidgetsBindingObserver {
  /// Held for the life of the screen. Building these in `build` handed
  /// StreamBuilder a new stream object on every rebuild, which tore down and
  /// re-established the Firestore listeners.
  ///
  /// The payment stream lives here rather than inside the panel so the panel
  /// and the "Start working" gate share one listener instead of opening two on
  /// the same document.
  late final Stream<WorkOrder> _order;
  late final Stream<Payment?> _payment;
  Future<AdminAccess?>? _staffAccess;
  String? _accessCheckedFor;

  /// The latest payment seen, so a return to the app can decide whether
  /// there is a gateway checkout worth asking about.
  Payment? _latestPayment;
  WorkOrder? _latestOrder;
  String? _activeUid;
  StreamSubscription<Payment?>? _paymentWatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final orders = context.read<OrderRepository>();
    final payments = context.read<PaymentRepository>();
    _order = orders.watchById(widget.orderId);
    _payment = payments.watchForOrder(widget.orderId);
    _paymentWatch = _payment.listen(
      (payment) => _latestPayment = payment,
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _paymentWatch?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    _activeUid = uid;
    if (uid != _accessCheckedFor) {
      _accessCheckedFor = uid;
      _staffAccess = uid == null
          ? Future.value(null)
          : context.read<AdminRepository>().access(uid);
    }
  }

  /// Coming back from GCash, Maya or the card page brings the app to the
  /// foreground; if the checkout is still pending, ask the gateway now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // A staff inspection must never initiate a gateway sync. The order owner
    // retains this convenience when viewing their own normal order page.
    if (widget.staffReadOnly ||
        !(_latestOrder?.involves(_activeUid ?? '') ?? false)) {
      return;
    }
    final payment = _latestPayment;
    if (payment == null ||
        payment.status != PaymentStatus.pending ||
        payment.method != PaymentMethod.xendit) {
      return;
    }
    context
        .read<PaymentRepository>()
        .syncPayment(widget.orderId)
        .catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthController>().uid;
    if (uid == null) {
      return Scaffold(appBar: AppBar(), body: const LoadingView());
    }
    return StreamBuilder<WorkOrder>(
      stream: _order,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: ErrorView(
              message: snapshot.error is AppFailure
                  ? '${snapshot.error}'
                  : 'Could not load this order.',
            ),
          );
        }
        if (!snapshot.hasData) {
          return Scaffold(
            appBar: AppBar(),
            body: const LoadingView(skeleton: true),
          );
        }
        final order = snapshot.data!;
        _latestOrder = order;
        if (widget.staffReadOnly || !order.involves(uid)) {
          return FutureBuilder<AdminAccess?>(
            future: _staffAccess,
            builder: (context, accessSnapshot) {
              if (accessSnapshot.connectionState != ConnectionState.done) {
                return Scaffold(
                  appBar: AppBar(),
                  body: const LoadingView(label: 'Checking access'),
                );
              }
              final access = accessSnapshot.data;
              final canView =
                  access != null &&
                  (access.can(AdminPermission.ordersManage) ||
                      access.can(AdminPermission.disputesResolve) ||
                      access.can(AdminPermission.reportsView));
              if (!canView) {
                return Scaffold(
                  appBar: AppBar(),
                  body: const ErrorView(message: 'You cannot view this order.'),
                );
              }
              return StreamBuilder<Payment?>(
                stream: _payment,
                builder: (context, paymentSnapshot) => _StaffOrderDetail(
                  order: order,
                  payment: paymentSnapshot.data,
                  paymentFailed: paymentSnapshot.hasError,
                  canReviewChat: access.can(AdminPermission.disputesResolve),
                ),
              );
            },
          );
        }
        return StreamBuilder<Payment?>(
          stream: _payment,
          builder: (context, paymentSnapshot) => _OrderDetail(
            order: order,
            myUid: uid,
            payment: paymentSnapshot.data,
            paymentFailed: paymentSnapshot.hasError,
          ),
        );
      },
    );
  }
}

/// Staff can inspect an order from the admin console, but they are never a
/// buyer or seller. Keep this view read-only so the normal participant action
/// bar cannot accidentally present an invalid state transition to staff.
class _StaffOrderDetail extends StatelessWidget {
  const _StaffOrderDetail({
    required this.order,
    required this.payment,
    required this.paymentFailed,
    required this.canReviewChat,
  });

  final WorkOrder order;
  final Payment? payment;
  final bool paymentFailed;
  final bool canReviewChat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payment = this.payment;
    return Scaffold(
      appBar: AppBar(
        title: Text(order.serviceTitle, overflow: TextOverflow.ellipsis),
      ),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                OrderStatusChip(status: order.status),
                const SizedBox(width: 10),
                Text('Read-only staff view', style: theme.textTheme.bodySmall),
              ],
            ),
            const SectionHeader('Participants'),
            LilyPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserName(uid: order.clientId, prefix: 'Buyer: '),
                  const SizedBox(height: 6),
                  UserName(uid: order.freelancerId, prefix: 'Seller: '),
                ],
              ),
            ),
            const SectionHeader('Terms'),
            _Terms(order: order),
            if (order.isNegotiated) ...[
              const SectionHeader('Agreed scope'),
              LilyPanel(child: _Expandable(text: order.scope ?? '')),
            ],
            const SectionHeader('Requirements'),
            LilyPanel(child: _Expandable(text: order.requirements)),
            if (order.disputeReason case final reason?) ...[
              const SectionHeader('Reported problem'),
              LilyPanel(child: Text(reason)),
            ],
            const SectionHeader('Payment'),
            LilyPanel(
              child: paymentFailed
                  ? const Text('Could not load payment details.')
                  : payment == null
                  ? const Text('No payment has been opened for this order.')
                  : _StaffPaymentSummary(payment: payment),
            ),
            if (canReviewChat &&
                (order.status == OrderStatus.disputed ||
                    order.disputeReason != null))
              DisputeChatReview(key: ValueKey(order.id), orderId: order.id),
          ],
        ),
      ),
    );
  }
}

class _StaffPaymentSummary extends StatelessWidget {
  const _StaffPaymentSummary({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${pesos(payment.amount)} / ${payment.status.label}',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text(
          '${payment.method.label} / commission ${pesos(payment.commission)} '
          '/ seller receives ${pesos(payment.netToFreelancer)}',
          style: theme.textTheme.bodySmall,
        ),
        if (payment.holdStatus != null) ...[
          const SizedBox(height: 6),
          Text(
            'Funds: ${payment.holdStatus!.name}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (payment.refundStatus != null) ...[
          const SizedBox(height: 6),
          Text(
            'Refund: ${payment.refundStatus}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _OrderDetail extends StatelessWidget {
  const _OrderDetail({
    required this.order,
    required this.myUid,
    required this.payment,
    required this.paymentFailed,
  });

  final WorkOrder order;
  final String myUid;

  /// Null while loading and while the order is unpaid; the panel and the work
  /// gate both read this single value.
  final Payment? payment;
  final bool paymentFailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = order.roleOf(myUid);
    final other = role == OrderRole.client
        ? order.freelancerId
        : order.clientId;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          order.serviceTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                OrderStatusChip(status: order.status),
                const SizedBox(width: 10),
                UserAvatarFor(uid: other, radius: 11),
                const SizedBox(width: 6),
                Expanded(
                  child: UserName(
                    uid: other,
                    prefix: role == OrderRole.client ? 'Seller: ' : 'Buyer: ',
                    linkToProfile: true,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _StepTracker(status: order.status),
            const SizedBox(height: 14),
            _NextStep(order: order, role: role, payment: payment),
            const SectionHeader('Terms'),
            _Terms(order: order),
            if (order.isNegotiated) ...[
              const SectionHeader(
                'Agreed scope',
                subtitle: 'From the offer the buyer accepted, not the listing.',
              ),
              LilyPanel(child: _Expandable(text: order.scope ?? '')),
            ],
            const SectionHeader('Requirements'),
            LilyPanel(child: _Expandable(text: order.requirements)),
            const SectionHeader('Deliveries'),
            _DeliveriesSection(orderId: order.id, myUid: myUid),
            const SectionHeader('Payment'),
            LilyPanel(
              child: PaymentSection(
                order: order,
                myUid: myUid,
                payment: payment,
                loadFailed: paymentFailed,
              ),
            ),
            if (order.status == OrderStatus.completed &&
                role == OrderRole.client) ...[
              const SizedBox(height: 20),
              _ReviewPrompt(
                orderId: order.id,
                onLeaveReview: () => _leaveReview(context),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _ActionBar(
        order: order,
        myUid: myUid,
        payment: payment,
      ),
    );
  }

  Future<void> _leaveReview(BuildContext context) async {
    final draft = await showDialog<_ReviewDraft>(
      context: context,
      builder: (dialogContext) => const _ReviewDialog(),
    );
    if (draft == null || !context.mounted) return;
    try {
      await context.read<ReviewRepository>().submitReview(
        order: order,
        rating: draft.rating,
        comment: draft.comment,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thanks, your review is up.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }
}

/// The buttons for this status and role, pinned to the bottom; nothing at
/// all when this person has no move. One tap at a time: a second tap on
/// "Accept & complete" while the first is in flight would only produce a
/// "cannot move" error, and money-moving cancels ask first.
class _ActionBar extends StatefulWidget {
  const _ActionBar({
    required this.order,
    required this.myUid,
    required this.payment,
  });

  final WorkOrder order;
  final String myUid;
  final Payment? payment;

  @override
  State<_ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends State<_ActionBar> {
  bool _busy = false;

  WorkOrder get order => widget.order;
  String get myUid => widget.myUid;
  Payment? get payment => widget.payment;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _go(OrderStatus next, {String? disputeReason}) => _run(() async {
    try {
      await context.read<OrderRepository>().transition(
        orderId: order.id,
        actorId: myUid,
        next: next,
        disputeReason: disputeReason,
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  });

  /// Ending an order is not undoable and may move money; say so first.
  Future<void> _confirmThen(
    OrderStatus next, {
    required String title,
    required String body,
    required String verb,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep the order'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(verb),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _go(next);
  }

  Future<void> _openDispute() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _DisputeReasonDialog(),
    );
    if (reason == null || !mounted) return;
    await _go(OrderStatus.disputed, disputeReason: reason);
  }

  /// Delivery flow: collect the delivery note, then move the order to
  /// `submitted`. The state transition only happens after the delivery
  /// document was accepted. Used for the first delivery and for every
  /// redelivery after a revision request.
  Future<void> _submitDeliveryFlow() async {
    final result = await showDialog<_DeliveryDraft>(
      context: context,
      builder: (dialogContext) => const _DeliveryDialog(),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      final repository = context.read<OrderRepository>();
      final storage = context.read<StorageRepository>();
      final messenger = ScaffoldMessenger.of(context);
      try {
        // Upload first, then record. A delivery that references a file
        // which failed to upload would look delivered and be nothing.
        final attachments = <Attachment>[
          for (final file in result.files)
            await storage.uploadDelivery(orderId: order.id, file: file),
        ];
        await repository.submitDelivery(
          orderId: order.id,
          freelancerId: myUid,
          note: result.note,
          attachments: attachments,
        );
        await repository.transition(
          orderId: order.id,
          actorId: myUid,
          next: OrderStatus.submitted,
        );
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Delivery submitted.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } on AppFailure catch (failure) {
        messenger.showSnackBar(SnackBar(content: Text(failure.message)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final children = _buttons(context);
    if (children == null) return const SizedBox.shrink();
    return StickyActionBar(child: ContentWidth(child: _row(children)));
  }

  // Side by side when there is room, the primary (last) taking what is
  // left; stacked, primary on top, when a phone cannot fit two captions.
  Widget _row(List<Widget> children) => LayoutBuilder(
    builder: (context, constraints) {
      if (children.length > 1 && constraints.maxWidth < 400) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final child in children.reversed) ...[
              child,
              if (child != children.first) const SizedBox(height: 6),
            ],
          ],
        );
      }
      return Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            if (i == children.length - 1)
              Expanded(child: children[i])
            else
              children[i],
          ],
        ],
      );
    },
  );

  List<Widget>? _buttons(BuildContext context) {
    final role = order.roleOf(myUid);
    final scheme = Theme.of(context).colorScheme;
    final blocked = _busy;

    Widget primary(String label, VoidCallback onPressed, {IconData? icon}) =>
        icon == null
        ? FilledButton(
            onPressed: blocked ? null : onPressed,
            child: Text(label),
          )
        : FilledButton.icon(
            onPressed: blocked ? null : onPressed,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon),
            label: Text(label),
          );
    Widget quiet(String label, VoidCallback onPressed) => TextButton(
      onPressed: blocked ? null : onPressed,
      style: TextButton.styleFrom(foregroundColor: scheme.error),
      child: Text(label),
    );

    switch (order.status) {
      case OrderStatus.pending when role == OrderRole.freelancer:
        // Declining a request is 'rejected'; cancelling a pending order is
        // the buyer's move and the rules refuse it from the seller.
        return [
          quiet(
            'Decline',
            () => _confirmThen(
              OrderStatus.rejected,
              title: 'Decline this request?',
              body: 'The buyer will be told. They can order again later.',
              verb: 'Decline',
            ),
          ),
          primary(
            'Accept order',
            () => _go(OrderStatus.accepted),
            icon: Icons.check_rounded,
          ),
        ];
      case OrderStatus.pending:
        return [
          OutlinedButton(
            onPressed: blocked
                ? null
                : () => _confirmThen(
                    OrderStatus.cancelled,
                    title: 'Withdraw this request?',
                    body: 'The seller has not accepted yet; nothing was paid.',
                    verb: 'Withdraw',
                  ),
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Cancel request'),
          ),
        ];
      case OrderStatus.accepted:
        // Work only starts once the money is in. The same rule is re-checked
        // inside the repository transaction, so disabling the button is a
        // convenience, not the control.
        final paid = payment?.isSettled ?? false;
        return [
          quiet('Report a problem', _openDispute),
          if (role == OrderRole.freelancer)
            FilledButton.icon(
              onPressed: paid && !blocked
                  ? () => _go(OrderStatus.inProgress)
                  : null,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(paid ? 'Start working' : 'Start after payment'),
            )
          else if (payment != null)
            // Paid, awaiting confirmation, or a checkout is open: the
            // payment panel says where it stands and what to do; the bar
            // must not start a second payment.
            const SizedBox.shrink()
          else
            primary(
              'Pay ₱${NumberFormat.decimalPattern().format(order.price)}',
              () => _run(() => payForOrder(context, order, myUid: myUid)),
              icon: Icons.lock_outline_rounded,
            ),
        ];
      case OrderStatus.inProgress:
        return [
          quiet(
            'Cancel',
            () => _confirmThen(
              OrderStatus.cancelled,
              title: 'Cancel this order?',
              body: role == OrderRole.client
                  ? 'Work already under way stops. A held gateway payment '
                        'is refunded to you.'
                  : 'The buyer loses the work so far. A held gateway '
                        'payment is refunded to them.',
              verb: 'Cancel order',
            ),
          ),
          if (role == OrderRole.freelancer)
            primary(
              'Submit delivery',
              _submitDeliveryFlow,
              icon: Icons.upload_file_outlined,
            )
          else
            const SizedBox.shrink(),
        ];
      case OrderStatus.submitted when role == OrderRole.client:
        return [
          OutlinedButton(
            onPressed: blocked
                ? null
                : () => _go(OrderStatus.revisionRequested),
            child: const Text('Request revision'),
          ),
          primary(
            'Accept & complete',
            () => _go(OrderStatus.completed),
            icon: Icons.check_circle_outline_rounded,
          ),
        ];
      case OrderStatus.revisionRequested when role == OrderRole.freelancer:
        // A redelivery is a delivery: notes and files, then the status.
        return [
          primary(
            'Redeliver work',
            _submitDeliveryFlow,
            icon: Icons.upload_file_outlined,
          ),
        ];
      case OrderStatus.submitted:
      case OrderStatus.revisionRequested:
      case OrderStatus.completed:
      case OrderStatus.cancelled:
      case OrderStatus.rejected:
      case OrderStatus.disputed:
        return null;
    }
  }
}

class _DisputeReasonDialog extends StatefulWidget {
  const _DisputeReasonDialog();

  @override
  State<_DisputeReasonDialog> createState() => _DisputeReasonDialogState();
}

class _DisputeReasonDialogState extends State<_DisputeReasonDialog> {
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
    final reason = _controller.text.trim();
    final valid = reason.length >= 10 && reason.length <= 1000;
    return AlertDialog(
      title: const Text('Open a dispute?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Staff will review this explanation, the order and its delivery. '
            'Neither party can act on the order while the dispute is open.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 4,
            minLines: 3,
            maxLength: 1000,
            decoration: const InputDecoration(
              labelText: 'What went wrong?',
              hintText: 'Describe the issue for staff (10-1000 characters).',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep order'),
        ),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, reason) : null,
          child: const Text('Open dispute'),
        ),
      ],
    );
  }
}

/// The five stops of an order, with the current one lit. A terminal bad
/// state (declined, cancelled, disputed) replaces the track with one line,
/// because there is no "next" to point at.
class _StepTracker extends StatelessWidget {
  const _StepTracker({required this.status});

  final OrderStatus status;

  // One word each: five stops must fit a phone width without wrapping.
  static const _steps = [
    ('Sent', Icons.send_rounded),
    ('Accepted', Icons.handshake_outlined),
    ('Working', Icons.construction_rounded),
    ('Delivered', Icons.inventory_2_outlined),
    ('Done', Icons.check_circle_rounded),
  ];

  int? get _current => switch (status) {
    OrderStatus.pending => 0,
    OrderStatus.accepted => 1,
    OrderStatus.inProgress => 2,
    OrderStatus.submitted || OrderStatus.revisionRequested => 3,
    OrderStatus.completed => 4,
    OrderStatus.rejected ||
    OrderStatus.cancelled ||
    OrderStatus.disputed => null,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = _current;
    if (current == null) {
      final (tone, icon) = orderStatusVisual(status);
      final tint = tone == Tone.danger ? scheme.error : scheme.tertiary;
      return LilyPanel(
        tint: tint,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Icon(icon, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(switch (status) {
                OrderStatus.rejected => 'The seller declined this request.',
                OrderStatus.cancelled => 'This order was cancelled.',
                _ =>
                  'This order is under dispute. Staff will review it and '
                      'decide where the money goes.',
              }, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      );
    }
    final done = status == OrderStatus.completed;
    return LilyPanel(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    height: 3,
                    decoration: BoxDecoration(
                      color: i <= current
                          ? (done ? scheme.secondary : scheme.primary)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            _Step(
              label: _steps[i].$1,
              icon: _steps[i].$2,
              state: i < current
                  ? _StepState.done
                  : i == current
                  ? (done ? _StepState.done : _StepState.current)
                  : _StepState.todo,
            ),
          ],
        ],
      ),
    );
  }
}

enum _StepState { done, current, todo }

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.icon, required this.state});

  final String label;
  final IconData icon;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg) = switch (state) {
      _StepState.done => (scheme.secondary, scheme.onSecondary),
      _StepState.current => (scheme.primary, scheme.onPrimary),
      _StepState.todo => (scheme.surfaceContainerHighest, scheme.outline),
    };
    return SizedBox(
      width: 62,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              boxShadow: state == _StepState.current
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.35),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              state == _StepState.done ? Icons.check_rounded : icon,
              size: 17,
              color: fg,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: state == _StepState.current
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: state == _StepState.todo
                  ? scheme.outline
                  : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// One sentence on what happens next from this person's side, with the
/// deadline or the auto-complete clock where one applies.
class _NextStep extends StatelessWidget {
  const _NextStep({
    required this.order,
    required this.role,
    required this.payment,
  });

  final WorkOrder order;
  final OrderRole role;
  final Payment? payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final client = role == OrderRole.client;
    final paid = payment?.isSettled ?? false;
    final pendingPayment = payment?.status == PaymentStatus.pending;
    final gateway = payment?.method == PaymentMethod.xendit;
    final when = DateFormat.yMMMd().add_jm();

    final (String text, IconData icon, Color tint) = switch (order.status) {
      OrderStatus.pending =>
        client
            ? (
                'Waiting for the seller to accept. You can withdraw the request until they do.',
                Icons.hourglass_top_rounded,
                scheme.outline,
              )
            : (
                'A buyer is waiting on you. Accept to open payment, or decline.',
                Icons.touch_app_rounded,
                scheme.tertiary,
              ),
      OrderStatus.accepted => switch ((paid, pendingPayment, gateway)) {
        (true, _, true) when client => (
          'Paid and held by the platform. The seller can start now.',
          Icons.lock_outline_rounded,
          scheme.secondary,
        ),
        (true, _, false) when client => (
          'The seller confirmed your payment. They can start now.',
          Icons.check_circle_outline_rounded,
          scheme.secondary,
        ),
        (true, _, _) => (
          'Payment is in. Start working when you are ready.',
          Icons.play_arrow_rounded,
          scheme.tertiary,
        ),
        (false, true, true) when client => (
          'Your payment is with the gateway. It shows as paid the moment it clears.',
          Icons.hourglass_top_rounded,
          scheme.outline,
        ),
        (false, true, false) when client => (
          'You recorded your payment. Waiting for the seller to confirm they received it.',
          Icons.hourglass_top_rounded,
          scheme.outline,
        ),
        (false, true, true) => (
          'The buyer is paying through the gateway. Work starts once the money is held.',
          Icons.hourglass_top_rounded,
          scheme.outline,
        ),
        (false, true, false) => (
          'The buyer says they paid. Confirm below once the money is actually in your account.',
          Icons.touch_app_rounded,
          scheme.tertiary,
        ),
        (false, false, _) when client => (
          'Pay to get the work started. The money is held until you approve the delivery.',
          Icons.payments_outlined,
          scheme.tertiary,
        ),
        (false, false, _) => (
          'Waiting for the buyer to pay. Work starts once the money is held.',
          Icons.hourglass_top_rounded,
          scheme.outline,
        ),
      },
      OrderStatus.inProgress =>
        client
            ? (
                'The seller is working on it${order.deadline == null ? '' : ', due ${when.format(order.deadline!)}'}.',
                Icons.construction_rounded,
                scheme.primary,
              )
            : (
                'Submit the delivery when it is ready${order.deadline == null ? '' : ', by ${when.format(order.deadline!)}'}.',
                Icons.upload_file_outlined,
                scheme.tertiary,
              ),
      // The silent-client rule, stated where it applies. The backend
      // completes a submitted order the client has not answered, so the
      // freelancer is not held hostage by inaction and the client knows
      // exactly how long they have to ask for changes.
      OrderStatus.submitted =>
        client
            ? (
                'Check the delivery. Accept it or request a revision by '
                    '${when.format(order.autoCompletesAt!)}; after that the order completes on its own.',
                Icons.touch_app_rounded,
                scheme.tertiary,
              )
            : (
                'Delivered. If the buyer does not respond, this completes automatically on '
                    '${when.format(order.autoCompletesAt!)}.',
                Icons.hourglass_top_rounded,
                scheme.outline,
              ),
      OrderStatus.revisionRequested =>
        client
            ? (
                'You asked for a revision. The seller will redeliver.',
                Icons.replay_rounded,
                scheme.outline,
              )
            : (
                'The buyer asked for a revision. Redeliver when it is done.',
                Icons.replay_rounded,
                scheme.tertiary,
              ),
      OrderStatus.completed => (
        order.autoCompleted
            ? 'Completed automatically after the delivery went unanswered.'
            : client
            ? 'Done. Leave a review to help the next student decide.'
            : 'Done. The payment has been released to your wallet.',
        Icons.check_circle_rounded,
        scheme.secondary,
      ),
      OrderStatus.rejected ||
      OrderStatus.cancelled ||
      OrderStatus.disputed => ('', Icons.info_outline_rounded, scheme.outline),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return LilyPanel(
      tint: tint,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: tint),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _Terms extends StatelessWidget {
  const _Terms({required this.order});

  final WorkOrder order;

  @override
  Widget build(BuildContext context) {
    return StatGrid(
      minTile: 110,
      tiles: [
        StatTile(
          label: 'Price',
          value: '₱${NumberFormat.decimalPattern().format(order.price)}',
          icon: Icons.sell_outlined,
          emphasis: true,
          caption: order.isNegotiated ? 'from accepted offer' : null,
        ),
        StatTile(
          label: 'Delivery',
          value:
              '${order.deliveryDays} day${order.deliveryDays == 1 ? '' : 's'}',
          icon: Icons.schedule_rounded,
        ),
        StatTile(
          label: 'Revisions',
          value: '${order.revisionCount}',
          icon: Icons.replay_rounded,
        ),
        if (order.deadline != null)
          StatTile(
            label: 'Deadline',
            value: DateFormat.MMMd().format(order.deadline!),
            icon: Icons.event_outlined,
            caption: DateFormat.jm().format(order.deadline!),
          ),
      ],
    );
  }
}

/// Long text folded to a few lines with a "Show more"; short text as is.
class _Expandable extends StatefulWidget {
  const _Expandable({required this.text});

  final String text;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final long =
        widget.text.length > 280 || '\n'.allMatches(widget.text).length > 4;
    if (widget.text.trim().isEmpty) {
      return Text('Nothing written.', style: theme.textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open || !long
              ? SelectableText(widget.text, style: theme.textTheme.bodyMedium)
              : Text(
                  widget.text,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
        ),
        if (long)
          TextButton(
            onPressed: () => setState(() => _open = !_open),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
            ),
            child: Text(_open ? 'Show less' : 'Show more'),
          ),
      ],
    );
  }
}

class _ReviewDraft {
  const _ReviewDraft({required this.rating, required this.comment});

  final int rating;
  final String comment;
}

/// Stars and words in one dialog. Two dialogs in a row lost people between
/// the first and the second.
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog();

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  int _rating = 5;
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

  static const _labels = ['', 'Poor', 'Fair', 'Good', 'Very good', 'Excellent'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Rate this service'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  iconSize: 34,
                  icon: Icon(
                    i <= _rating
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: i <= _rating
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.outline,
                  ),
                  tooltip: '$i star${i > 1 ? 's' : ''}',
                  onPressed: () => setState(() => _rating = i),
                ),
            ],
          ),
          Text(
            _labels[_rating],
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 4,
            maxLength: ReviewRepository.maxCommentLength,
            decoration: const InputDecoration(
              labelText: 'Your review',
              hintText: 'What was the work like? Would you order again?',
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
              : () => Navigator.pop(
                  context,
                  _ReviewDraft(
                    rating: _rating,
                    comment: _controller.text.trim(),
                  ),
                ),
          child: const Text('Post review'),
        ),
      ],
    );
  }
}

/// Prompts for a review, or reports that one exists.
///
/// Stateful purely to hold its stream: rebuilt inline it re-subscribed on
/// every frame and flashed "Leave a review" over an already-reviewed order.
class _ReviewPrompt extends StatefulWidget {
  const _ReviewPrompt({required this.orderId, required this.onLeaveReview});

  final String orderId;
  final VoidCallback onLeaveReview;

  @override
  State<_ReviewPrompt> createState() => _ReviewPromptState();
}

class _ReviewPromptState extends State<_ReviewPrompt> {
  late final Stream<bool> _reviewed;

  @override
  void initState() {
    super.initState();
    _reviewed = context.read<OrderRepository>().watchReviewed(widget.orderId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<bool>(
      stream: _reviewed,
      builder: (context, snapshot) {
        final reviewed = snapshot.data ?? false;
        return LilyPanel(
          tint: reviewed ? null : theme.colorScheme.tertiary,
          child: Row(
            children: [
              IconDisc(
                icon: reviewed ? Icons.rate_review_rounded : Icons.star_rounded,
                tint: theme.colorScheme.tertiary,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  reviewed ? 'You reviewed this order. Thank you.' : 'How did it go? Your review helps the next student decide.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (!reviewed) ...[
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: widget.onLeaveReview,
                  child: const Text('Review'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DeliveriesSection extends StatefulWidget {
  const _DeliveriesSection({required this.orderId, required this.myUid});

  final String orderId;
  final String myUid;

  @override
  State<_DeliveriesSection> createState() => _DeliveriesSectionState();
}

class _DeliveriesSectionState extends State<_DeliveriesSection> {
  late final Stream<List<Delivery>> _deliveries;

  @override
  void initState() {
    super.initState();
    _deliveries = context.read<OrderRepository>().watchDeliveries(
      widget.orderId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<Delivery>>(
      stream: _deliveries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text(
            'Could not load deliveries.',
            style: theme.textTheme.bodySmall,
          );
        }
        if (!snapshot.hasData) return const SkeletonBox(height: 72, radius: 20);
        final deliveries = snapshot.data!;
        if (deliveries.isEmpty) {
          return LilyPanel(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nothing delivered yet. Files and notes the seller submits appear here.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < deliveries.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == deliveries.length - 1 ? 0 : 8,
                ),
                child: LilyPanel(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconDisc(
                            icon: Icons.upload_file_outlined,
                            size: 30,
                            tint: deliveries[i].senderId == widget.myUid
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Delivery ${deliveries.length - i}',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          Text(
                            DateFormat.yMMMd().add_jm().format(
                              deliveries[i].createdAt,
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SelectableText(
                        deliveries[i].note,
                        style: theme.textTheme.bodyMedium,
                      ),
                      for (final attachment in deliveries[i].attachments)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: AttachmentView(attachment: attachment),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// What the delivery dialog hands back: the note and the files still in
/// memory. Uploading happens after the dialog closes, on the order screen,
/// so a cancelled dialog uploads nothing.
class _DeliveryDraft {
  const _DeliveryDraft({required this.note, required this.files});

  final String note;
  final List<PickedFile> files;
}

class _DeliveryDialog extends StatefulWidget {
  const _DeliveryDialog();

  @override
  State<_DeliveryDialog> createState() => _DeliveryDialogState();
}

class _DeliveryDialogState extends State<_DeliveryDialog> {
  final _noteController = TextEditingController();
  final _files = <PickedFile>[];

  @override
  void initState() {
    super.initState();
    _noteController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final picked = await context.read<StorageRepository>().pick(
        multiple: true,
        limitBytes: StorageRepository.deliveryLimitBytes,
      );
      if (!mounted) return;
      setState(() {
        _files.addAll(picked.take(Delivery.maxAttachments - _files.length));
      });
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  void _submit() {
    final note = _noteController.text.trim();
    if (note.isEmpty) return;
    Navigator.pop(context, _DeliveryDraft(note: note, files: List.of(_files)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Submit delivery'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _noteController,
            autofocus: true,
            maxLines: 4,
            maxLength: OrderRepository.maxDeliveryNoteLength,
            decoration: const InputDecoration(
              labelText: 'Delivery notes',
              hintText: 'Summarize the work you delivered…',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final file in _files)
                InputChip(
                  label: Text(file.name, overflow: TextOverflow.ellipsis),
                  avatar: Icon(
                    file.isImage
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 18,
                  ),
                  onDeleted: () => setState(() => _files.remove(file)),
                ),
              if (_files.length < Delivery.maxAttachments)
                ActionChip(
                  avatar: const Icon(Icons.attach_file_outlined, size: 18),
                  label: Text(_files.isEmpty ? 'Attach files' : 'Add more'),
                  onPressed: _pick,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Up to ${Delivery.maxAttachments} files, '
            '${StorageRepository.deliveryLimitBytes ~/ (1024 * 1024)} MB each.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _noteController.text.trim().isEmpty ? null : _submit,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
