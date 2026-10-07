import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_repository.dart';
import '../domain/admin_access.dart';
import 'admin_screen.dart';

/// Route guard for `/admin`.
///
/// The console itself is safe without this — every query it makes is refused
/// by security rules for anyone without an `admins/{uid}` document, and that
/// document cannot be written from a client. But "safe" and "correct" are not
/// the same thing: `/admin` was reachable by any signed-in student who typed
/// the path, and what they got was the full staff console rendered around a
/// row of permission errors. That looks like a broken app to an honest user
/// and like a promising surface to a dishonest one.
///
/// So the check here is a UX and disclosure control, not the authorization
/// boundary. The boundary stays in firestore.rules, where a client cannot
/// reach it. Anyone editing this should assume the gate can be bypassed and
/// make sure the rules still hold.
class AdminGate extends StatefulWidget {
  const AdminGate({super.key});

  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> {
  Stream<AdminAccess?>? _access;
  String? _checkedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // watch, not read: signing out mid-session must re-run the check rather
    // than leave the previous user's answer on screen.
    final uid = context.watch<AuthController>().uid;
    if (uid != _checkedFor) {
      _checkedFor = uid;
      _access = uid == null
          ? null
          : context.read<AdminRepository>().watchAccess(uid);
    }
  }

  void _retryAccess() {
    final uid = context.read<AuthController>().uid;
    setState(() {
      _checkedFor = uid;
      _access = uid == null
          ? null
          : context.read<AdminRepository>().watchAccess(uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    final check = _access;
    if (check == null) return const _NotStaff();

    return StreamBuilder<AdminAccess?>(
      stream: check,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('Admin')),
            body: ErrorView(
              message: 'Could not check staff access. Check your connection.',
              onRetry: _retryAccess,
            ),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: LoadingView(label: 'Checking access'));
        }
        // A failed check is treated as "no", never as "probably yes".
        final access = snapshot.data;
        if (access == null) return const _NotStaff();
        return AdminScreen(access: access);
      },
    );
  }
}

class _NotStaff extends StatelessWidget {
  const _NotStaff();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: EmptyView(
        icon: Icons.lock_outline,
        message: 'The staff console is only open to platform staff.',
        actionLabel: 'Back to the marketplace',
        onAction: () => context.go('/'),
      ),
    );
  }
}
