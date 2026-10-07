import 'package:flutter/material.dart';

/// Shows a snackbar with a user-facing failure message.
///
/// Kept in one place so error presentation stays consistent.
void showFailureSnackBar(BuildContext context, Object failure) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(failure.toString()),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
