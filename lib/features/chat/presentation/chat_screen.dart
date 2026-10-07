import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/storage/attachment.dart';
import '../../../core/storage/attachment_view.dart';
import '../../../core/storage/storage_repository.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../offers/presentation/offer_card.dart';
import '../../offers/presentation/send_offer_dialog.dart';
import '../data/chat_repository.dart';
import '../domain/chat_models.dart';
import 'chat_message_text.dart';
import 'chat_service_card.dart';

/// One thread. The other student's name and face are the title and lead to
/// their profile; messages group by day; offers are cards in the stream;
/// the composer is a pill with attach on the left and send on the right.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.serviceId});

  final String conversationId;
  final String? serviceId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  bool _hasText = false;
  bool _picking = false;
  PickedFile? _pendingFile;
  Attachment? _uploadedAttachment;
  String? _peerUid;
  late String? _pendingServiceId = widget.serviceId;

  /// Held rather than rebuilt in `build`: a fresh stream object each rebuild
  /// tears down and re-establishes the Firestore listener.
  late final Stream<List<ChatMessage>> _messages;

  @override
  void initState() {
    super.initState();
    _messages = context.read<ChatRepository>().watchMessages(
      widget.conversationId,
    );
    _inputController.addListener(() {
      final hasText = _inputController.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
    _loadPeer();
    _markRead();
  }

  Future<void> _loadPeer() async {
    final repository = context.read<ChatRepository>();
    final uid = context.read<AuthController>().uid;
    try {
      final conversation = await repository.fetchConversation(
        widget.conversationId,
      );
      if (conversation == null || uid == null) return;
      if (mounted) {
        setState(() => _peerUid = conversation.otherParticipant(uid));
      }
    } on Exception {
      // Title stays generic when the header lookup fails; messages still load.
    }
  }

  /// Opening the conversation clears this user's unread badge. Best-effort:
  /// a failure here must not block reading messages.
  Future<void> _markRead() async {
    final uid = context.read<AuthController>().uid;
    if (uid == null) return;
    try {
      await context.read<ChatRepository>().markConversationRead(
        conversationId: widget.conversationId,
        readerId: uid,
      );
    } on Exception {
      // Badge stays until next open.
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  ChatRepository get _repository => context.read<ChatRepository>();

  Future<void> _send() async {
    final text = _inputController.text;
    final file = _pendingFile;
    if ((text.trim().isEmpty && file == null) || _sending || _picking) return;
    final uid = context.read<AuthController>().uid!;
    final repository = _repository;
    final storage = context.read<StorageRepository>();
    setState(() => _sending = true);
    try {
      if (file == null) {
        await repository.sendText(
          conversationId: widget.conversationId,
          senderId: uid,
          rawText: text,
          serviceId: _pendingServiceId,
        );
      } else {
        _uploadedAttachment ??= await storage.uploadChatAttachment(
          conversationId: widget.conversationId,
          file: file,
        );
        await repository.sendAttachment(
          conversationId: widget.conversationId,
          senderId: uid,
          attachment: _uploadedAttachment!,
          caption: text,
          serviceId: _pendingServiceId,
        );
      }
      if (!mounted) return;
      _inputController.clear();
      setState(() {
        _pendingServiceId = null;
        _pendingFile = null;
        _uploadedAttachment = null;
      });
    } on AppFailure catch (failure) {
      if (!mounted) return;
      showFailureSnackBar(context, failure);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _attach({required bool imagesOnly}) async {
    if (_sending || _picking) return;
    final storage = context.read<StorageRepository>();
    setState(() => _picking = true);
    try {
      final picked = await storage.pick(
        imagesOnly: imagesOnly,
        limitBytes: StorageRepository.chatVideoLimitBytes,
        forChat: true,
      );
      if (picked.isEmpty || !mounted) return;
      setState(() {
        _pendingFile = picked.first;
        _uploadedAttachment = null;
      });
    } on Exception catch (error) {
      if (mounted) showFailureSnackBar(context, AppFailure.from(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _offer(String uid) {
    final peer = _peerUid;
    if (peer == null) return;
    showDialog<bool>(
      context: context,
      builder: (_) => SendOfferDialog(freelancerId: uid, clientId: peer),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthController>().uid;
    if (uid == null) return const LoadingView();

    // Validate the route parameter before using it in any query.
    if (widget.conversationId.isEmpty ||
        widget.conversationId.length > 120 ||
        widget.conversationId.contains('/')) {
      return const ErrorView(message: 'Invalid conversation.');
    }
    final theme = Theme.of(context);
    final peer = _peerUid;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: peer == null
            ? const Text('Conversation')
            : InkWell(
                onTap: () => context.push('/user/$peer'),
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UserAvatarFor(uid: peer, radius: 17),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            UserName(
                              uid: peer,
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'View profile',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        actions: [
          // Either side may be the seller in a given conversation; the
          // dialog only lists the sender's own published listings, and the
          // rules refuse an offer for anyone else's.
          if (peer != null)
            IconButton(
              tooltip: 'Send an offer',
              icon: const Icon(Icons.request_quote_outlined),
              onPressed: () => _offer(uid),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<ChatMessage>>(
              stream: _messages,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const ErrorView(message: 'Could not load messages.');
                }
                if (!snapshot.hasData) return const LoadingView();
                final messages = snapshot.data!.reversed.toList(
                  growable: false,
                );
                if (messages.isEmpty) {
                  return EmptyView(
                    icon: Icons.waving_hand_outlined,
                    title: 'Say hello',
                    message:
                        'Describe the job, agree on a price, and the seller '
                        'can send an offer card you accept right here.',
                    actionLabel: peer == null ? null : 'Send an offer',
                    onAction: peer == null ? null : () => _offer(uid),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients &&
                      _scrollController.position.maxScrollExtent > 0) {
                    _scrollController.jumpTo(
                      _scrollController.position.maxScrollExtent,
                    );
                  }
                });
                return ContentWidth(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final previous = index == 0 ? null : messages[index - 1];
                      final newDay =
                          previous == null ||
                          !_sameDay(previous.sentAt, message.sentAt);
                      final continued =
                          previous != null &&
                          !newDay &&
                          previous.senderId == message.senderId &&
                          previous.offerId == null &&
                          message.sentAt.difference(previous.sentAt).inMinutes <
                              5;
                      final fromMe = message.senderId == uid;
                      final Widget body;
                      if (message.offerId != null) {
                        body = Align(
                          alignment: fromMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: OfferCard(
                              offerId: message.offerId!,
                              myUid: uid,
                            ),
                          ),
                        );
                      } else {
                        body = _MessageBubble(
                          message: message,
                          fromMe: fromMe,
                          continued: continued,
                        );
                      }
                      if (!newDay) return body;
                      return Column(
                        children: [
                          _DayDivider(day: message.sentAt),
                          body,
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
          if (_sending) const LinearProgressIndicator(minHeight: 2),
          _Composer(
            controller: _inputController,
            canSend:
                (_hasText || _pendingFile != null) && !_sending && !_picking,
            uploading: _sending || _picking,
            pendingFile: _pendingFile,
            onRemove: () => setState(() {
              _pendingFile = null;
              _uploadedAttachment = null;
            }),
            onSend: _send,
            onAttach: _attach,
          ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(day.year, day.month, day.day);
    final label = that == today
        ? 'Today'
        : that == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : DateFormat.MMMEd().format(day);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label, style: theme.textTheme.labelSmall),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.fromMe,
    required this.continued,
  });

  final ChatMessage message;
  final bool fromMe;

  /// Same sender within minutes of the previous message: tuck it closer and
  /// drop the timestamp.
  final bool continued;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final bubbleColor = fromMe
        ? scheme.primary
        : dark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLowest;
    final foreground = fromMe ? scheme.onPrimary : scheme.onSurface;
    const r = Radius.circular(18);
    const tight = Radius.circular(6);
    return Align(
      alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: fromMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(top: continued ? 2 : 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.75,
            ),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: !fromMe && continued ? tight : r,
                topRight: fromMe && continued ? tight : r,
                bottomLeft: fromMe ? r : tight,
                bottomRight: fromMe ? tight : r,
              ),
              border: fromMe || dark
                  ? null
                  : Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.serviceReference case final reference?) ...[
                  ChatServiceCard(reference: reference, foreground: foreground),
                  const SizedBox(height: 8),
                ],
                if (message.attachment != null)
                  AttachmentView(
                    attachment: message.attachment!,
                    foreground: foreground,
                  ),
                if (message.attachment != null && message.text.isNotEmpty)
                  const SizedBox(height: 6),
                if (message.text.isNotEmpty)
                  ChatMessageText(
                    message.text,
                    style: TextStyle(color: foreground, height: 1.35),
                  ),
              ],
            ),
          ),
          if (!continued)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 3, 6, 0),
              child: Text(
                DateFormat.jm().format(message.sentAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.canSend,
    required this.uploading,
    required this.onSend,
    required this.onAttach,
    required this.pendingFile,
    required this.onRemove,
  });

  final TextEditingController controller;
  final bool canSend;
  final bool uploading;
  final VoidCallback onSend;
  final void Function({required bool imagesOnly}) onAttach;
  final PickedFile? pendingFile;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: theme.brightness == Brightness.dark
          ? scheme.surfaceContainerLow
          : scheme.surfaceContainerLowest,
      child: SafeArea(
        top: false,
        child: ContentWidth(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pendingFile case final file?)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: file.isImage
                        ? SizedBox(
                            width: 48,
                            height: 48,
                            child: Image.memory(
                              file.bytes,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.image_outlined),
                            ),
                          )
                        : Icon(
                            file.type == AttachmentType.video
                                ? Icons.videocam_outlined
                                : Icons.insert_drive_file_outlined,
                          ),
                    title: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${(file.size / (1024 * 1024)).toStringAsFixed(1)} MB · Ready to send',
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove attachment',
                      onPressed: uploading ? null : onRemove,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    'Photos/files: 10 MB · Videos: 25 MB. Share larger files with an HTTPS link.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    PopupMenuButton<bool>(
                      tooltip: 'Attach',
                      icon: Icon(
                        Icons.add_circle_outline_rounded,
                        color: scheme.primary,
                      ),
                      enabled: !uploading,
                      onSelected: (imagesOnly) =>
                          onAttach(imagesOnly: imagesOnly),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: true,
                          child: ListTile(
                            leading: Icon(Icons.image_outlined),
                            title: Text('Photo'),
                          ),
                        ),
                        PopupMenuItem(
                          value: false,
                          child: ListTile(
                            leading: Icon(Icons.insert_drive_file_outlined),
                            title: Text('Video or file'),
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: TextField(
                        enabled: !uploading,
                        controller: controller,
                        maxLength: ChatRepository.maxMessageLength,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(
                          hintText: 'Message',
                          counterText: '',
                          isDense: true,
                          filled: true,
                          fillColor: scheme.surfaceContainerHigh.withValues(
                            alpha: 0.6,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(24)),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(24)),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(24),
                            ),
                            borderSide: BorderSide(color: scheme.primary),
                          ),
                        ),
                        onSubmitted: (_) => onSend(),
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedScale(
                      scale: canSend ? 1 : 0.9,
                      duration: const Duration(milliseconds: 150),
                      child: IconButton.filled(
                        tooltip: 'Send',
                        icon: const Icon(Icons.send_rounded, size: 20),
                        onPressed: canSend ? onSend : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
