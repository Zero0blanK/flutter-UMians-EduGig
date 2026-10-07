import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/chat_repository.dart';

/// Opens (creating if needed) the thread between the signed-in student and
/// [other], then navigates to it. The one place a "Message" button goes.
///
/// Every failure is shown. A tap that silently did nothing is the worst
/// outcome here: the student cannot tell a slow network from a refused
/// write, and neither can whoever is asked to fix it.
Future<void> openChatWith(
  BuildContext context,
  String other, {
  String? serviceId,
}) async {
  final me = context.read<AuthController>().uid;
  if (me == null) {
    showFailureSnackBar(context, const PermissionFailure());
    return;
  }
  if (me == other) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('That is you.')));
    return;
  }
  final repository = context.read<ChatRepository>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final id = await repository.openConversationWith(me: me, other: other);
    if (context.mounted) {
      context.push(
        Uri(
          path: '/chat/$id',
          queryParameters: serviceId == null ? null : {'service': serviceId},
        ).toString(),
      );
    }
  } on AppFailure catch (failure) {
    if (context.mounted) showFailureSnackBar(context, failure);
  } catch (error) {
    // Not one of ours: say that it failed, and what kind, without echoing
    // an internal message to the screen.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Could not open the chat (${error.runtimeType}). Please try again.',
        ),
      ),
    );
  }
}
