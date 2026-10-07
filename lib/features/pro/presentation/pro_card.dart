import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/storage/storage_repository.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/verified_badge.dart';
import '../../../core/widgets/lily.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../payments/domain/payment.dart';
import '../../payments/presentation/payment_method_sheet.dart';
import '../../payments/presentation/payment_section.dart' show openCheckout;
import '../../wallet/data/wallet_repository.dart';
import '../data/pro_repository.dart';
import '../domain/pro_policy.dart';

/// The Pro subscription and the verified badge, on the seller's own profile.
///
/// Says exactly what ₱99 buys — up to two featured listings and the badge
/// once identity is checked — and exactly what it does not: a lower
/// commission. Both cards are honest about the backend requirement instead
/// of failing halfway through a checkout.
class ProCard extends StatefulWidget {
  const ProCard({super.key});

  @override
  State<ProCard> createState() => _ProCardState();
}

class _ProCardState extends State<ProCard> with WidgetsBindingObserver {
  bool _busy = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshSubscription();
  }

  Future<void> _refreshSubscription() async {
    if (_syncing || !mounted) return;
    _syncing = true;
    final repository = context.read<ProRepository>();
    final auth = context.read<AuthController>();
    try {
      await repository.syncPending();
      await auth.refreshProfile();
    } on AppFailure {
      // The profile listener also receives eventual webhook settlement.
    } finally {
      _syncing = false;
    }
  }

  Future<void> _subscribe() async {
    final channel = await showPaymentMethodSheet(
      context,
      title: 'Get Pro for ${ProPolicy.periodDays} days',
      amount: ProPolicy.price,
      note: 'Paid once, up front. Nothing renews on its own.',
    );
    if (channel == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final accountType = switch (channel) {
        PaymentChannel.gcash => 'gcash',
        PaymentChannel.maya => 'maya',
        PaymentChannel.card || PaymentChannel.other => null,
      };
      if (accountType != null) {
        final uid = context.read<AuthController>().uid;
        if (uid == null) return;
        final wallet = await context
            .read<WalletRepository>()
            .watchWallet(uid)
            .first;
        if (!mounted || context.read<AuthController>().uid != uid) return;
        final account = wallet.payoutAccount;
        if (account?.type != accountType ||
            !(account?.isComplete ?? false) ||
            (account?.accountName.trim().isEmpty ?? true)) {
          final saved = await context.push<bool>(
            Uri(
              path: '/wallet/account',
              queryParameters: {'type': accountType, 'setup': 'pro'},
            ).toString(),
          );
          if (saved != true ||
              !mounted ||
              context.read<AuthController>().uid != uid) {
            return;
          }
        }
      }
      final intent = await context.read<ProRepository>().startCheckout(channel);
      if (!mounted) return;
      await openCheckout(context, intent.checkoutUrl);
      if (!mounted) return;
      // Back from the browser: ask the gateway now, so a finished payment
      // switches Pro on at once instead of at the next callback.
      try {
        await _refreshSubscription();
      } on AppFailure {
        // The callback and the reconciler still settle it.
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'If you finished paying, Pro is on now; otherwise it switches '
              'on within a minute of the payment.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (failure) {
      if (mounted) showFailureSnackBar(context, AppFailure.from(failure));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<AuthController>().profile;
    final available = context.read<ProRepository>().isAvailable;
    final isPro = profile?.isPro ?? false;
    final hasVerifiedBadge = profile?.hasVerifiedBadge ?? false;

    return LilyPanel(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.workspace_premium_outlined,
                  size: 18,
                  color: isPro ? theme.colorScheme.tertiary : null,
                ),
                const SizedBox(width: 8),
                Text('Pro', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (isPro)
                  Text(
                    'Active until '
                    '${DateFormat.yMMMd().format(profile!.proUntil!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '₱${ProPolicy.price} for ${ProPolicy.periodDays} days, paid up '
              'front, no auto-renewal. Feature up to '
              '${ProPolicy.featuredPerSeller} of your listings above the '
              'marketplace, and show the verified badge once your student '
              'ID is checked. Commission stays at 5%.',
              style: theme.textTheme.bodySmall,
            ),
            if (hasVerifiedBadge) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const VerifiedBadge(size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your verified badge is active and visible next to your '
                      'name and listings.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ] else if (isPro) ...[
              const SizedBox(height: 12),
              Text(
                'Pro is active. Submit your student ID below to unlock the '
                'verified check.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (!available)
              Text(
                'Pro needs the payments backend, which this build was not '
                'pointed at.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else
              FilledButton.icon(
                icon: const Icon(Icons.shopping_bag_outlined),
                label: Text(isPro ? 'Extend by 30 days' : 'Get Pro for ₱99'),
                onPressed: _busy ? null : _subscribe,
              ),
          ],
        ),
      ),
    );
  }
}

/// The identity check behind the verified badge.
class VerificationCard extends StatefulWidget {
  const VerificationCard({super.key});

  @override
  State<VerificationCard> createState() => _VerificationCardState();
}

class _VerificationCardState extends State<VerificationCard> {
  Stream<VerificationRequest?>? _request;
  String? _loadedFor;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _request = context.read<ProRepository>().watchVerification(uid);
    }
  }

  Future<void> _submit() async {
    final uid = _loadedFor;
    if (uid == null) return;
    final email = await showDialog<String>(
      context: context,
      builder: (_) => const _SchoolEmailDialog(),
    );
    if (email == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final storage = context.read<StorageRepository>();
      final picked = await storage.pick(
        imagesOnly: true,
        limitBytes: StorageRepository.idLimitBytes,
      );
      if (picked.isEmpty || !mounted) return;
      await context.read<ProRepository>().submitVerification(
        uid: uid,
        schoolEmail: email,
        idPhoto: picked.first,
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
    final profile = context.watch<AuthController>().profile;
    final stream = _request;
    if (stream == null) return const SizedBox.shrink();

    return LilyPanel(
      child: Padding(
        padding: EdgeInsets.zero,
        child: StreamBuilder<VerificationRequest?>(
          stream: stream,
          builder: (context, snapshot) {
            final request = snapshot.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const VerifiedBadge(size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Verified student',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  _copyFor(profile, request),
                  style: theme.textTheme.bodySmall,
                ),
                if (request?.status == VerificationStatus.rejected &&
                    (request?.note?.isNotEmpty ?? false)) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Staff note: ${request!.note}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_canSubmit(profile, request)) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.badge_outlined),
                    label: Text(
                      request == null ? 'Submit student ID' : 'Submit again',
                    ),
                    onPressed: _busy ? null : _submit,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  static bool _canSubmit(UserProfile? profile, VerificationRequest? request) {
    if (profile?.identityVerified ?? false) return false;
    return request == null || request.status == VerificationStatus.rejected;
  }

  static String _copyFor(UserProfile? profile, VerificationRequest? request) {
    if (profile?.identityVerified ?? false) {
      return profile!.isPro
          ? 'Your identity is verified and the badge is showing on your '
                'listings.'
          : 'Your identity is verified. The badge shows while Pro is active.';
    }
    return switch (request?.status) {
      VerificationStatus.pending =>
        'Your student ID is under review. Staff usually decide within a '
            'few days.',
      VerificationStatus.rejected =>
        'Your last request was not approved. You can submit a clearer photo '
            'or a different school email.',
      _ =>
        'Submit a photo of your current student ID and your school email. '
            'Staff check them by hand; the badge means a real check, not a '
            'payment. Only staff can see the photo.',
    };
  }
}

class _SchoolEmailDialog extends StatefulWidget {
  const _SchoolEmailDialog();

  @override
  State<_SchoolEmailDialog> createState() => _SchoolEmailDialogState();
}

class _SchoolEmailDialogState extends State<_SchoolEmailDialog> {
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
    final valid = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
        .hasMatch(_controller.text.trim());
    return AlertDialog(
      title: const Text('School email'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(
          labelText: 'Email',
          hintText: 'you@school.edu.ph',
          helperText: 'Next you will pick a photo of your student ID.',
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
          child: const Text('Choose ID photo'),
        ),
      ],
    );
  }
}
