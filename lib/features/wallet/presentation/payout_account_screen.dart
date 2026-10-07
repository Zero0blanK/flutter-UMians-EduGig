import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/wallet_repository.dart';
import '../domain/wallet.dart';

/// Where payouts go, on a page of its own: pick GCash, Maya or a bank the
/// way a delivery app adds a payment method, then fill in the one form that
/// applies. A saved account shows as a card with a "Change" that starts the
/// same flow again.
class PayoutAccountScreen extends StatefulWidget {
  const PayoutAccountScreen({
    super.key,
    this.initialType,
    this.returnOnSave = false,
  });

  final String? initialType;
  final bool returnOnSave;

  @override
  State<PayoutAccountScreen> createState() => _PayoutAccountScreenState();
}

class _PayoutAccountScreenState extends State<PayoutAccountScreen> {
  Stream<Wallet>? _wallet;
  String? _loadedFor;

  /// The method being set up, or null while the saved account (or the
  /// picker) is shown.
  late String? _editing = PayoutAccount.types.contains(widget.initialType)
      ? widget.initialType
      : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _wallet = context.read<WalletRepository>().watchWallet(uid);
    }
  }

  Future<void> _save(PayoutAccount account) async {
    final uid = _loadedFor;
    if (uid == null) return;
    try {
      await context.read<WalletRepository>().savePayoutAccount(
        uid: uid,
        account: account,
      );
      if (!mounted) return;
      if (widget.returnOnSave) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _editing = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${account.typeLabel} saved as your payout account.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on AppFailure catch (failure) {
      if (mounted) showFailureSnackBar(context, failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = _wallet;
    return Scaffold(
      appBar: AppBar(title: const Text('Payout account')),
      body: ContentWidth(
        child: stream == null
            ? const LoadingView()
            : StreamBuilder<Wallet>(
                stream: stream,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const ErrorView(
                      message: 'Could not load your payout account.',
                    );
                  }
                  if (!snapshot.hasData) return const LoadingView();
                  final account = snapshot.data!.payoutAccount;
                  final editing = _editing;
                  if (editing != null) {
                    return _AccountForm(
                      key: ValueKey(editing),
                      type: editing,
                      initial: account?.type == editing ? account : null,
                      saveLabel: widget.returnOnSave
                          ? 'Save and continue to Pro'
                          : null,
                      onSave: _save,
                      onBack: widget.returnOnSave
                          ? null
                          : () => setState(() => _editing = null),
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (account != null) ...[
                        _SavedAccount(
                          account: account,
                          onChange: () =>
                              setState(() => _editing = account.type),
                        ),
                        const SectionHeader(
                          'Switch to another method',
                          subtitle: 'Replaces the account above.',
                        ),
                      ] else
                        const SectionHeader(
                          'Where should we send your money?',
                          subtitle:
                              'Payouts go here whenever you request one. '
                              'You can change it any time.',
                          padding: EdgeInsets.fromLTRB(0, 8, 0, 12),
                        ),
                      for (final type in PayoutAccount.types)
                        if (account?.type != type)
                          _MethodTile(
                            type: type,
                            onTap: () => setState(() => _editing = type),
                          ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

(IconData, Color, String) _visual(BuildContext context, String type) {
  final scheme = Theme.of(context).colorScheme;
  return switch (type) {
    'gcash' => (
      Icons.account_balance_wallet_rounded,
      scheme.onSurfaceVariant,
      'Sent to your GCash number',
    ),
    'maya' => (
      Icons.smartphone_rounded,
      scheme.onSurfaceVariant,
      'Sent to your Maya number',
    ),
    _ => (
      Icons.account_balance_rounded,
      scheme.primary,
      'Bank transfer to a PH bank account',
    ),
  };
}

String _labelOf(String type) => switch (type) {
  'gcash' => 'GCash',
  'maya' => 'Maya',
  _ => 'Bank account',
};

class _MethodTile extends StatelessWidget {
  const _MethodTile({required this.type, required this.onTap});

  final String type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, tint, hint) = _visual(context, type);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LilyPanel(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        onTap: onTap,
        child: Row(
          children: [
            IconDisc(icon: icon, tint: tint, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_labelOf(type), style: theme.textTheme.titleSmall),
                  Text(hint, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

class _SavedAccount extends StatelessWidget {
  const _SavedAccount({required this.account, required this.onChange});

  final PayoutAccount account;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, tint, _) = _visual(context, account.type);
    return LilyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconDisc(icon: icon, tint: tint, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(account.typeLabel, style: theme.textTheme.titleMedium),
                    Text(
                      account.maskedNumber,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(account.accountName, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const StatusPill(
                label: 'Active',
                tone: Tone.success,
                icon: Icons.check_rounded,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onChange,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit details'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountForm extends StatefulWidget {
  const _AccountForm({
    super.key,
    required this.type,
    required this.initial,
    required this.onSave,
    required this.onBack,
    this.saveLabel,
  });

  final String type;
  final PayoutAccount? initial;
  final Future<void> Function(PayoutAccount account) onSave;
  final VoidCallback? onBack;
  final String? saveLabel;

  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  late String? _bankCode = widget.initial?.bankCode;
  late final _name = TextEditingController(
    text:
        widget.initial?.accountName ??
        context.read<AuthController>().profile?.displayName ??
        '',
  );
  late final _number = TextEditingController(
    text: widget.initial?.accountNumber,
  );
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _number.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _number.dispose();
    super.dispose();
  }

  bool get _bank => widget.type == 'bank';

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      WalletPolicy.validAccountNumber(widget.type, _number.text.trim()) &&
      (!_bank || WalletPolicy.banks.containsKey(_bankCode));

  Future<void> _submit() async {
    setState(() => _saving = true);
    await widget.onSave(
      PayoutAccount(
        type: widget.type,
        accountName: _name.text.trim(),
        accountNumber: _number.text.trim(),
        bankCode: _bank ? _bankCode : null,
      ),
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, tint, _) = _visual(context, widget.type);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            IconDisc(icon: icon, tint: tint, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _labelOf(widget.type),
                style: theme.textTheme.titleLarge,
              ),
            ),
            if (widget.onBack != null)
              TextButton(onPressed: widget.onBack, child: const Text('Change')),
          ],
        ),
        const SizedBox(height: 16),
        LilyPanel(
          child: Column(
            children: [
              if (_bank) ...[
                DropdownButtonFormField<String>(
                  initialValue: WalletPolicy.banks.containsKey(_bankCode)
                      ? _bankCode
                      : null,
                  decoration: const InputDecoration(labelText: 'Bank'),
                  items: [
                    for (final entry in WalletPolicy.banks.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) => setState(() => _bankCode = value),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _name,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Account holder name',
                  helperText: _bank
                      ? 'Exactly as it appears on the account.'
                      : 'The registered name on the wallet.',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _number,
                maxLength: 16,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _bank ? 'Account number' : 'Mobile number',
                  hintText: _bank ? '1234567890' : '09XXXXXXXXX',
                  helperText: _bank
                      ? '10 to 16 digits'
                      : '11 digits, starting with 09',
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LilyPanel(
          tint: theme.colorScheme.tertiary,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Check the number twice. A transfer to the wrong account '
                  'cannot be recalled. Payouts start at '
                  '₱${WalletPolicy.minimumPayout}.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: _valid && !_saving ? _submit : null,
          child: Text(
            _saving
                ? 'Saving…'
                : widget.saveLabel ??
                      (widget.initial == null
                          ? 'Save ${_labelOf(widget.type)}'
                          : 'Save changes'),
          ),
        ),
      ],
    );
  }
}
