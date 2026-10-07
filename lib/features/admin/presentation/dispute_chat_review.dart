import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/storage/attachment_view.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/user_name.dart';
import '../../chat/domain/chat_models.dart';
import '../../chat/presentation/chat_service_card.dart';
import '../data/admin_repository.dart';

class DisputeChatReview extends StatefulWidget {
  const DisputeChatReview({super.key, required this.orderId});
  final String orderId;
  @override
  State<DisputeChatReview> createState() => _DisputeChatReviewState();
}

class _DisputeChatReviewState extends State<DisputeChatReview> {
  final _messages = <ChatMessage>[];
  DateTime? _capturedAt;
  String? _cursor;
  String? _error;
  bool _loading = false;
  bool _exhausted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || _exhausted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<AdminRepository>().fetchDisputeChat(
        widget.orderId,
        afterId: _cursor,
      );
      if (!mounted) return;
      setState(() {
        _capturedAt = page.capturedAt;
        _messages.addAll(page.messages);
        _cursor = page.nextCursor;
        _exhausted = _cursor == null;
      });
    } catch (failure) {
      if (mounted) setState(() => _error = AppFailure.from(failure).message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionHeader(
        'Chat snapshot',
        subtitle:
            'Read-only buyer and seller conversation, newest messages first.',
      ),
      if (_capturedAt != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Captured ${DateFormat.yMMMd().add_jm().format(_capturedAt!.toLocal())}. Later messages are excluded.',
          ),
        ),
      for (final message in _messages)
        LilyPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserName(uid: message.senderId),
              Text(
                DateFormat.yMMMd().add_jm().format(message.sentAt.toLocal()),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (message.text.isNotEmpty) SelectableText(message.text),
              if (message.offerId != null)
                Text('Offer reference: ${message.offerId}'),
              if (message.attachment != null)
                AttachmentView(attachment: message.attachment!),
              if (message.serviceReference case final reference?)
                ChatServiceCard(reference: reference),
            ],
          ),
        ),
      if (!_loading && _exhausted && _messages.isEmpty)
        const Text('No messages were present when this snapshot was captured.'),
      if (_error != null) Text(_error!),
      if (_loading)
        const Center(child: CircularProgressIndicator())
      else if (!_exhausted)
        TextButton(
          onPressed: _load,
          child: Text(
            _error == null ? 'Load older messages' : 'Retry chat snapshot',
          ),
        ),
    ],
  );
}
