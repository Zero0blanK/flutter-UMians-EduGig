import 'package:flutter/material.dart';

import 'lily.dart';

/// Loading, empty and error states, each with a centre and a next step.
///
/// A blank screen, a spinner in a void, or an outline icon floating over the
/// page all read as the app breaking. Every state here has a tinted disc, a
/// sentence that says what happened, and, where one exists, the action that
/// resolves it.

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label, this.skeleton = false});

  final String? label;

  /// Draw card-shaped placeholders instead of a spinner: right for a list
  /// whose shape the reader already knows.
  final bool skeleton;

  @override
  Widget build(BuildContext context) {
    if (skeleton) return const SkeletonList();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(
              label!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusFrame extends StatelessWidget {
  const _StatusFrame({
    required this.icon,
    required this.tint,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconDisc(icon: icon, tint: tint, size: 72),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.title,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  /// The one line. When [title] is given this becomes the supporting text.
  final String message;
  final String? title;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatusFrame(
      icon: icon,
      tint: theme.colorScheme.primary,
      title: title ?? message,
      message: title == null ? null : message,
      action: actionLabel != null && onAction != null
          ? FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!))
          : null,
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StatusFrame(
      icon: Icons.error_outline_rounded,
      tint: theme.colorScheme.error,
      title: 'Something went wrong',
      message: message,
      action: onRetry != null
          ? FilledButton.tonal(onPressed: onRetry, child: const Text('Retry'))
          : null,
    );
  }
}
