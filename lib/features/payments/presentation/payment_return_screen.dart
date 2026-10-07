import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/payment_repository.dart';
import '../domain/payment.dart';
import '../../pro/data/pro_repository.dart';

/// The browser return from Xendit is only a navigation hint. The payment
/// document, written by the verified gateway callback or a server-side sync,
/// remains the source of truth for what this screen calls paid.
class PaymentReturnScreen extends StatefulWidget {
  const PaymentReturnScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<PaymentReturnScreen> createState() => _PaymentReturnScreenState();
}

class _PaymentReturnScreenState extends State<PaymentReturnScreen> {
  Future<void>? _sync;
  String? _syncedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _syncedFor) {
      _syncedFor = uid;
      _sync = _syncPayment();
    }
  }

  Future<void> _syncPayment() async {
    try {
      await context.read<PaymentRepository>().syncPayment(widget.orderId);
    } catch (_) {
      // The callback/reconciler can still settle the record. The stream below
      // remains visible rather than treating a return-screen sync failure as
      // a failed payment.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    if (auth.status == AuthStatus.loading || _sync == null) {
      return const Scaffold(body: LoadingView(label: 'Restoring your session'));
    }
    final payments = context.read<PaymentRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('Payment status')),
      body: FutureBuilder<void>(
        future: _sync,
        builder: (context, sync) => StreamBuilder<Payment?>(
          stream: payments.watchForOrder(widget.orderId),
          builder: (context, snapshot) {
            if (!snapshot.hasData && snapshot.connectionState == ConnectionState.waiting) {
              return const LoadingView(label: 'Confirming payment');
            }
            if (snapshot.hasError) {
              return _ReturnPanel(
                icon: Icons.error_outline_rounded,
                title: 'Could not read payment status',
                message: 'Open the order to retry. A successful redirect alone is not treated as payment confirmation.',
                actionLabel: 'View order',
                onAction: () => context.go('/order/${widget.orderId}'),
              );
            }
            final payment = snapshot.data;
            if (payment?.isSettled ?? false) {
              return _ReturnPanel(
                icon: Icons.check_circle_outline_rounded,
                title: 'Payment confirmed',
                message: 'Your payment is recorded as paid. The order is ready for the next step.',
                actionLabel: 'View order',
                onAction: () => context.go('/order/${widget.orderId}'),
              );
            }
            if (payment?.status == PaymentStatus.refunded) {
              return _ReturnPanel(
                icon: Icons.undo_outlined,
                title: 'Payment refunded',
                message: 'This payment was returned. Open the order for the details.',
                actionLabel: 'View order',
                onAction: () => context.go('/order/${widget.orderId}'),
              );
            }
            return _ReturnPanel(
              icon: Icons.hourglass_top_rounded,
              title: 'Confirming payment',
              message: sync.connectionState == ConnectionState.waiting
                  ? 'We are checking the gateway now. This usually takes a moment.'
                  : 'The payment is still being confirmed. You can safely open the order; it updates automatically.',
              actionLabel: 'View order',
              onAction: () => context.go('/order/${widget.orderId}'),
            );
          },
        ),
      ),
    );
  }
}

class PaymentCancelledScreen extends StatelessWidget {
  const PaymentCancelledScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment cancelled')),
      body: _ReturnPanel(
        icon: Icons.cancel_outlined,
        title: 'Checkout was not completed',
        message: 'No payment is marked as paid from this return. You can reopen the order whenever you are ready.',
        actionLabel: 'Back to order',
        onAction: () => context.go('/order/$orderId'),
      ),
    );
  }
}

class ProPaymentReturnScreen extends StatefulWidget {
  const ProPaymentReturnScreen({super.key});

  @override
  State<ProPaymentReturnScreen> createState() => _ProPaymentReturnScreenState();
}

class _ProPaymentReturnScreenState extends State<ProPaymentReturnScreen> {
  Future<void>? _sync;
  String? _syncedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _syncedFor) {
      _syncedFor = uid;
      _sync = _syncProPayment();
    }
  }

  Future<void> _syncProPayment() async {
    try {
      await context.read<ProRepository>().syncPending();
    } catch (_) {
      // The verified callback still updates the subscription after a transient
      // return-screen sync failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    if (auth.status == AuthStatus.loading || _sync == null) {
      return const Scaffold(body: LoadingView(label: 'Restoring your session'));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Pro payment status')),
      body: FutureBuilder<void>(
        future: _sync,
        builder: (context, snapshot) => _ReturnPanel(
          icon: snapshot.connectionState == ConnectionState.waiting
              ? Icons.hourglass_top_rounded
              : Icons.workspace_premium_outlined,
          title: snapshot.connectionState == ConnectionState.waiting
              ? 'Confirming Pro payment'
              : 'Pro payment return received',
          message: 'Your subscription status is updated from the verified gateway result.',
          actionLabel: 'Open Pro',
          onAction: () => context.go('/pro'),
        ),
      ),
    );
  }
}

class _ReturnPanel extends StatelessWidget {
  const _ReturnPanel({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: LilyPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 44, color: theme.colorScheme.primary),
                const SizedBox(height: 14),
                Text(title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(actionLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
