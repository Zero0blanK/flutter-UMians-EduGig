import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/storage/storage_repository.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/paginated_list.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../payments/domain/payment.dart';
import '../../payments/presentation/payment_section.dart' show pesos;
import '../../pro/domain/pro_policy.dart';
import '../../wallet/domain/wallet.dart';
import '../data/admin_repository.dart';

/// Transfers waiting to be made. Staff send the money by hand (GCash, bank)
/// and record the reference here; the backend moves the balance and logs
/// the action in the same transaction.
class PayoutQueue extends StatelessWidget {
  const PayoutQueue({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.read<AdminRepository>();
    return PaginatedList<Payout>(
      load: (limit) => repository.watchPayoutQueue(limit: limit),
      emptyMessage: 'No payouts waiting.',
      header: Column(
        children: [if (!repository.backendAvailable) const _BackendNotice()],
      ),
      itemBuilder: (context, item) => _PayoutCard(payout: item),
    );
  }
}

class _PayoutCard extends StatefulWidget {
  const _PayoutCard({required this.payout});

  final Payout payout;

  @override
  State<_PayoutCard> createState() => _PayoutCardState();
}

class _PayoutCardState extends State<_PayoutCard> {
  Payout get payout => widget.payout;

  /// One money-moving call at a time. The backend refuses a second submit
  /// on its own (the payout id is the idempotency key), but a disabled
  /// button is clearer than an error.
  bool _busy = false;

  /// Sending real money to a bank account: say what and where, then go.
  Future<void> _submit(BuildContext context) async {
    final account = payout.account;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Send ${pesos(payout.amount)} via Xendit?'),
        content: Text(
          account == null
              ? 'This payout has no account on file.'
              : 'To ${account.typeLabel} ${account.accountNumber} '
                    '(${account.accountName}). A transfer to the wrong '
                    'account cannot be recalled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: account == null
                ? null
                : () => Navigator.pop(dialogContext, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await context.read<AdminRepository>().submitPayout(
        payout.id,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (outcome) {
              'submitted' => 'Handed to Xendit; the callback will settle it.',
              'refused' => 'Xendit refused the account; money returned.',
              _ => 'Xendit is not responding; try again later.',
            }),
          ),
        );
      }
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _settle(BuildContext context) async {
    final reference = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(
        title: 'Record the transfer',
        label: 'Transfer reference',
        hint: 'GCash / InstaPay reference number',
        minLength: 1,
        maxLength: 120,
        action: 'Mark as sent',
      ),
    );
    if (reference == null || !context.mounted) return;
    try {
      await context.read<AdminRepository>().settlePayout(
        payoutId: payout.id,
        reference: reference,
      );
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

  Future<void> _reject(BuildContext context) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(
        title: 'Return to balance',
        label: 'Reason (shown to the student)',
        hint: 'e.g. the account number does not exist',
        minLength: 10,
        maxLength: 500,
        action: 'Return money',
      ),
    );
    if (note == null || !context.mounted) return;
    try {
      await context.read<AdminRepository>().rejectPayout(
        payoutId: payout.id,
        note: note,
      );
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = payout.account;
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
                  child: UserName(
                    uid: payout.uid,
                    style: theme.textTheme.titleMedium,
                    linkToProfile: true,
                  ),
                ),
                Text(pesos(payout.amount), style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              account == null
                  ? 'No account on file'
                  : '${account.typeLabel} · ${account.accountNumber} · '
                        '${account.accountName}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Requested ${DateFormat.yMMMd().add_jm().format(payout.requestedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            if (payout.gatewayError != null) ...[
              const SizedBox(height: 4),
              Text(
                payout.gatewayError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (payout.status == PayoutStatus.processing)
              // With the gateway: its callback settles or returns it. A
              // manual "sent" here would risk paying twice.
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'With Xendit (${payout.gatewayPayoutId ?? 'no id'}). '
                      'Waiting for its callback.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.send_outlined),
                    label: Text(
                      payout.gatewayError == null
                          ? 'Send via Xendit'
                          : 'Retry via Xendit',
                    ),
                    onPressed: _busy ? null : () => _submit(context),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Sent by hand'),
                    onPressed: _busy ? null : () => _settle(context),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: _busy ? null : () => _reject(context),
                    child: const Text('Return'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Students waiting for an identity check. The ID photo is loaded through a
/// rule-checked download URL, never a public link.
class VerificationQueue extends StatelessWidget {
  const VerificationQueue({super.key, required this.isMainAdmin});
  final bool isMainAdmin;
  @override
  Widget build(BuildContext context) {
    final repository = context.read<AdminRepository>();
    return PaginatedList<VerificationRequest>(
      load: (limit) => repository.watchVerificationQueue(limit: limit),
      emptyMessage: 'No verification requests waiting.',
      header: Column(
        children: [if (!repository.backendAvailable) const _BackendNotice()],
      ),
      itemBuilder: (context, item) =>
          _VerificationCard(request: item, isMainAdmin: isMainAdmin),
    );
  }
}

class _VerificationCard extends StatefulWidget {
  const _VerificationCard({required this.request, required this.isMainAdmin});

  final VerificationRequest request;
  final bool isMainAdmin;

  @override
  State<_VerificationCard> createState() => _VerificationCardState();
}

class _VerificationCardState extends State<_VerificationCard> {
  late final Future<String> _photoUrl = context
      .read<StorageRepository>()
      .downloadUrl(widget.request.idImagePath);

  /// What the student declared, to be read against the ID. The birth date is
  /// self-reported and pinned once; this review is the only moment a human
  /// sees it next to a document, so approval requires saying they match.
  late final Future<UserProfile> _profile = context
      .read<AuthRepository>()
      .loadProfile(widget.request.uid);
  bool _detailsMatch = false;

  Future<void> _decide(bool approve) async {
    var note = '';
    if (!approve) {
      final reason = await showDialog<String>(
        context: context,
        builder: (_) => const _TextDialog(
          title: 'Not approved',
          label: 'Reason (shown to the student)',
          hint: 'e.g. the ID is expired, or the photo is unreadable',
          minLength: 10,
          maxLength: 500,
          action: 'Reject',
        ),
      );
      if (reason == null || !mounted) return;
      note = reason;
    }
    try {
      await context.read<AdminRepository>().decideVerification(
        uid: widget.request.uid,
        approve: approve,
        note: note,
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    final me = context.read<AuthController>().uid;
    final backendAvailable = context.read<AdminRepository>().backendAvailable;
    final isStaffSelfReview = me == request.uid && !widget.isMainAdmin;
    final approvalHint = !backendAvailable
        ? 'Approving verification needs the trusted backend. Run the '
              'development or production build, not the emulator build.'
        : isStaffSelfReview
        ? 'You cannot approve your own identity verification. Ask another '
              'staff member to review it.'
        : !_detailsMatch
        ? 'Confirm that the ID name and birth date match the profile to '
              'enable approval.'
        : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserName(
              uid: request.uid,
              style: theme.textTheme.titleMedium,
              linkToProfile: true,
            ),
            const SizedBox(height: 4),
            SelectableText(
              request.schoolEmail,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              'Submitted ${DateFormat.yMMMd().add_jm().format(request.createdAt)}'
              ' · ${_waiting(request.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: DateTime.now().difference(request.createdAt).inDays >= 3
                    ? theme.colorScheme.error
                    : null,
              ),
            ),
            const SizedBox(height: 10),
            FutureBuilder<UserProfile>(
              future: _profile,
              builder: (context, snapshot) {
                final profile = snapshot.data;
                if (profile == null) return const SizedBox.shrink();
                final born = profile.birthDate;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Profile says: ${profile.displayName}'
                    '${profile.studentId == null ? '' : ' · ${profile.studentId}'}'
                    ' · born ${born == null ? 'not given' : DateFormat.yMMMd().format(born)}',
                    style: theme.textTheme.bodySmall,
                  ),
                );
              },
            ),
            FutureBuilder<String>(
              future: _photoUrl,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(
                    'Could not load the ID photo.',
                    style: theme.textTheme.bodySmall,
                  );
                }
                if (!snapshot.hasData) {
                  return const LinearProgressIndicator(minHeight: 2);
                }
                return ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: Image.network(snapshot.data!, fit: BoxFit.contain),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _detailsMatch,
              onChanged: (v) => setState(() => _detailsMatch = v ?? false),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'The name and birth date on the ID match the profile',
              ),
            ),
            if (approvalHint != null) ...[
              const SizedBox(height: 4),
              Text(
                approvalHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('Approve'),
                  // Staff do not verify themselves, and never without
                  // reading the ID against the declared details.
                  onPressed: approvalHint == null ? () => _decide(true) : null,
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () => _decide(false),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "waiting 2 days" — the number a queue is judged by.
String _waiting(DateTime since) {
  final d = DateTime.now().difference(since);
  if (d.inDays >= 1) {
    return 'waiting ${d.inDays} day${d.inDays == 1 ? '' : 's'}';
  }
  if (d.inHours >= 1) return 'waiting ${d.inHours} h';
  return 'just now';
}

/// Refunds the gateway refused or cannot address. Staff either retry once
/// the gateway is back, or send the money by hand and record the reference.
class RefundQueue extends StatelessWidget {
  const RefundQueue({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = context.read<AdminRepository>();
    return PaginatedList<Payment>(
      load: (limit) => repository.watchRefundQueue(limit: limit),
      emptyMessage: 'No refunds need attention.',
      header: Column(
        children: [
          if (!repository.backendAvailable) const _BackendNotice(),
          const _ChargebackPanel(),
        ],
      ),
      itemBuilder: (context, item) => _RefundCard(payment: item),
    );
  }
}

class _ChargebackPanel extends StatelessWidget {
  const _ChargebackPanel();

  Future<void> _record(BuildContext context) async {
    final orderId = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(
        title: 'Record a chargeback',
        label: 'Order ID',
        hint: 'The order named in the gateway case',
        minLength: 1,
        maxLength: 120,
        action: 'Continue',
      ),
    );
    if (orderId == null || !context.mounted) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(
        title: 'Gateway chargeback case',
        label: 'Case reference and reason',
        hint: 'Give the gateway case reference and why',
        minLength: 10,
        maxLength: 500,
        action: 'Continue',
      ),
    );
    if (reason == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record this chargeback?'),
        content: Text(
          'Order: $orderId\n$reason\n\nThe seller’s released net will be recovered from their balance; any shortfall becomes owed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Record chargeback'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<AdminRepository>().recordChargeback(
        orderId: orderId,
        reason: reason,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Chargeback recorded.')));
      }
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) => LilyPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Gateway chargebacks',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const Text('Record a confirmed gateway case for a released payment.'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: context.read<AdminRepository>().backendAvailable
              ? () => _record(context)
              : null,
          icon: const Icon(Icons.undo_outlined),
          label: const Text('Record chargeback'),
        ),
      ],
    ),
  );
}

class _RefundCard extends StatelessWidget {
  const _RefundCard({required this.payment});

  final Payment payment;

  Future<void> _retry(BuildContext context) async {
    try {
      await context.read<AdminRepository>().retryRefund(payment.orderId);
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

  Future<void> _manual(BuildContext context) async {
    final reference = await showDialog<String>(
      context: context,
      builder: (_) => const _TextDialog(
        title: 'Refunded outside the gateway',
        label: 'Transfer reference',
        hint: 'GCash / InstaPay reference of the refund you sent',
        minLength: 1,
        maxLength: 120,
        action: 'Record refund',
      ),
    );
    if (reference == null || !context.mounted) return;
    try {
      await context.read<AdminRepository>().markRefundedManually(
        orderId: payment.orderId,
        reference: reference,
      );
    } on AppFailure catch (failure) {
      if (context.mounted) showFailureSnackBar(context, failure);
    }
  }

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
                  child: UserName(
                    uid: payment.clientId,
                    prefix: 'Refund to ',
                    style: theme.textTheme.titleMedium,
                    linkToProfile: true,
                  ),
                ),
                Text(pesos(payment.amount), style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              payment.refundStatus == 'manual-required'
                  ? 'No gateway payment id on this record; it cannot be '
                        'refunded automatically.'
                  : 'The gateway refused the refund. Retry, or send it by hand.',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'Order ${payment.orderId} · ${_waiting(payment.updatedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (payment.refundStatus != 'manual-required') ...[
                  FilledButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                    onPressed: () => _retry(context),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton(
                  onPressed: () => _manual(context),
                  child: const Text('Refunded by hand'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendNotice extends StatelessWidget {
  const _BackendNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Decisions here go through the payments backend, which this build was '
      'not pointed at. Rebuild with PAYMENTS_API_URL to act on the queue.',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.hint,
    required this.minLength,
    required this.maxLength,
    required this.action,
  });

  final String title;
  final String label;
  final String hint;
  final int minLength;
  final int maxLength;
  final String action;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
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
    final valid = _controller.text.trim().length >= widget.minLength;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: widget.maxLength,
        maxLines: widget.maxLength > 200 ? 3 : 1,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid
              ? () => Navigator.pop(context, _controller.text.trim())
              : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
