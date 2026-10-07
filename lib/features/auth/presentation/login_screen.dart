import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/config/app_environment.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/widgets/lily.dart';
import '../domain/um_account.dart';
import 'auth_controller.dart';

/// Development and emulator builds show a selector for the seeded demo
/// accounts; production builds have no demo-account controls.

/// The single way in: a University of Mindanao Google account.
///
/// There is no registration. Signing in with a UM address creates the
/// profile from what Google supplies (name, photo, email) and, for a
/// student-format address, marks the student identity-verified. Any other
/// Google account is refused here, by the rules, and by the backend.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _collapsedSheetSize = 0.35;
  final _sheetController = DraggableScrollableController();
  bool _showDemoAccounts = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sheetController.addListener(_onSheetChanged);
  }

  void _onSheetChanged() {
    final expanded = _sheetController.size > _collapsedSheetSize;
    if (expanded != _showDemoAccounts) {
      setState(() => _showDemoAccounts = expanded);
    }
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AuthController>().signInWithGoogle();
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = Breakpoints.isWide(context);
    final card = _SignInCard(
      submitting: _submitting,
      error: _error,
      onGoogle: _signInWithGoogle,
    );

    if (wide) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: _CampusBackground(
                child: const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: _Brand(expanded: true),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: card,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: _CampusBackground(
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                AnimatedBuilder(
                  animation: _sheetController,
                  builder: (context, child) => Positioned(
                    left: 24,
                    right: 24,
                    bottom:
                        constraints.maxHeight *
                            (_sheetController.isAttached
                                ? _sheetController.size
                                : _collapsedSheetSize) +
                        24,
                    child: child!,
                  ),
                  child: const _Brand(expanded: false),
                ),
                DraggableScrollableSheet(
                  controller: _sheetController,
                  initialChildSize: _collapsedSheetSize,
                  minChildSize: _collapsedSheetSize,
                  maxChildSize: 0.7,
                  snap: true,
                  shouldCloseOnMinExtent: false,
                  builder: (context, scrollController) => Material(
                    color: Theme.of(context).colorScheme.surface,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(32),
                      ),
                    ),
                    child: SingleChildScrollView(
                      controller: scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                        .withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              _SignInCard(
                                submitting: _submitting,
                                error: _error,
                                onGoogle: _signInWithGoogle,
                                showDemoAccounts: _showDemoAccounts,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CampusBackground extends StatelessWidget {
  const _CampusBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      image: DecorationImage(
        image: AssetImage('assets/image/login-bg.png'),
        fit: BoxFit.cover,
        alignment: Alignment.center,
      ),
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.2),
            Colors.black.withValues(alpha: 0.8),
          ],
        ),
      ),
      child: child,
    ),
  );
}

class _Brand extends StatelessWidget {
  const _Brand({required this.expanded});

  /// Wide layout: the mark, the name and three reasons. Phone: mark and
  /// name only, the card carries the rest.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const LilyMark(size: 56, onHero: true),
        const SizedBox(height: 20),
        const Text('UMians EduGig', style: OnHero.title),
        const SizedBox(height: 10),
        const Text(
          'Hire fellow UM students, or get hired for what you already know '
          'how to do.',
          style: OnHero.subtitle,
        ),
        if (expanded) ...[
          const SizedBox(height: 40),
          const _Reason(
            icon: Icons.school_outlined,
            text: 'Everyone here signed in with a UM account.',
          ),
          const _Reason(
            icon: Icons.lock_outline_rounded,
            text:
                'Pay in the app; the money is held until you approve the work.',
          ),
          const _Reason(
            icon: Icons.star_outline_rounded,
            text: 'Reviews from real classmates, one per completed order.',
          ),
        ],
      ],
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 19, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: OnHero.subtitle)),
        ],
      ),
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({
    required this.submitting,
    required this.error,
    required this.onGoogle,
    this.showDemoAccounts = true,
  });

  final bool submitting;
  final String? error;
  final VoidCallback onGoogle;
  final bool showDemoAccounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sign in', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Use your University of Mindanao Google account. There is nothing '
          'to register.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        if (error != null) ...[
          InlineAuthError(message: error!),
          const SizedBox(height: 14),
        ],
        FilledButton.icon(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          icon: submitting
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.school_outlined),
          label: Text(
            submitting ? 'Opening Google…' : 'Continue with UM Google',
          ),
          onPressed: submitting ? null : onGoogle,
        ),
        const SizedBox(height: 12),
        Text(
          'Only @${UmAccount.domain} accounts are accepted. Your name and '
          'photo come from your university account, and a student address '
          '(a.surname.123456) counts as identity verification.',
          style: theme.textTheme.bodySmall,
        ),
        if (kAppEnvironment.demoLogin && showDemoAccounts) ...[
          const SizedBox(height: 28),
          const _DemoSignIn(),
        ],
      ],
    );
  }
}

/// The seeded demo students (`tools/seed`), on whichever Firebase this
/// build targets. Rendered only for development and emulator builds; a
/// production build has no demo-account selector at all.
class _DemoSignIn extends StatefulWidget {
  const _DemoSignIn();

  @override
  State<_DemoSignIn> createState() => _DemoSignInState();
}

class _DemoSignInState extends State<_DemoSignIn> {
  static const _password = 'Password123';

  _DemoAccount _selected = _demoAccounts.first;
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AuthController>().signInWithPassword(
        _selected.email,
        _password,
      );
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LilyPanel(
      tint: theme.colorScheme.tertiary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Demo accounts · ${kAppEnvironment.label}',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            kAppEnvironment.usesEmulator
                ? 'Choose a seeded account on the local emulator. No Google '
                      'account is needed for the demo.'
                : 'Choose a seeded account in the development project. No '
                      'Google account is needed for the demo.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[
            InlineAuthError(message: _error!),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<_DemoAccount>(
            initialValue: _selected,
            isExpanded: true,
            itemHeight: null,
            decoration: const InputDecoration(labelText: 'Demo account'),
            selectedItemBuilder: (context) => [
              for (final account in _demoAccounts)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(account.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            items: [
              for (final account in _demoAccounts)
                DropdownMenuItem(
                  value: account,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(account.name, overflow: TextOverflow.ellipsis),
                      Text(
                        account.email,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: _submitting
                ? null
                : (account) {
                    if (account != null) setState(() => _selected = account);
                  },
          ),
          const SizedBox(height: 6),
          Text(_selected.email, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(_selected.scenario, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _submitting ? null : _submit,
            child: Text(
              _submitting
                  ? 'Signing in...'
                  : 'Sign in as ${_selected.name.split(' ').first}',
            ),
          ),
        ],
      ),
    );
  }
}

/// Accounts created by `tools/seed/seed.js`. They are intentionally listed in
/// the development-only widget rather than queried from Firestore: an
/// unauthenticated visitor must not be able to enumerate real students.
class _DemoAccount {
  const _DemoAccount({
    required this.name,
    required this.email,
    required this.scenario,
  });

  final String name;
  final String email;
  final String scenario;
}

const _demoAccounts = [
  _DemoAccount(
    name: 'Maya Robles',
    email: 'm.robles.100001@umindanao.edu.ph',
    scenario:
        'Seller and client with the most complete marketplace activity. '
        'Also use this account for the admin demo after granting it admin access.',
  ),
  _DemoAccount(
    name: 'Ivan Cruz',
    email: 'i.cruz.100002@umindanao.edu.ph',
    scenario:
        'Design seller and client with paid, active and completed orders.',
  ),
  _DemoAccount(
    name: 'Samantha Lim',
    email: 's.lim.100003@umindanao.edu.ph',
    scenario: 'Writing seller and client with reviews and order activity.',
  ),
  _DemoAccount(
    name: 'Noel Bautista',
    email: 'n.bautista.100004@umindanao.edu.ph',
    scenario: 'Video seller and client with both unpaid and paid requests.',
  ),
  _DemoAccount(
    name: 'Rina Delos Santos',
    email: 'r.santos.100005@umindanao.edu.ph',
    scenario: 'Tutoring seller and client with active work and settled sales.',
  ),
  _DemoAccount(
    name: 'Jomar Aquino',
    email: 'j.aquino.100006@umindanao.edu.ph',
    scenario: 'Music seller and client with pending and active orders.',
  ),
  _DemoAccount(
    name: 'Thea Marquez',
    email: 't.marquez.100007@umindanao.edu.ph',
    scenario: 'Photography seller and client with an unpaid request and sales.',
  ),
];

/// Quiet inline error banner.
class InlineAuthError extends StatelessWidget {
  const InlineAuthError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppTheme.radiusControl),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
