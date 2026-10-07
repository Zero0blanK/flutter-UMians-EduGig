import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/capped_list.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../../core/widgets/user_name.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/chat_repository.dart';
import '../domain/chat_models.dart';

/// The inbox. Unread threads are bold with a lily dot; read ones step back.
/// One row per classmate, never per order, so a buyer and a seller who work
/// together keep one thread.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  /// Held rather than rebuilt in `build`: a fresh stream object each rebuild
  /// tears down and re-establishes the Firestore listener.
  Stream<CappedList<Conversation>>? _conversations;
  String? _loadedFor;
  int _listLimit = 50;
  bool _loadingMore = false;
  bool _hasMore = false;

  void _loadMore() {
    final uid = _loadedFor;
    if (uid == null || _loadingMore || !_hasMore) return;
    setState(() {
      _listLimit += 50;
      _loadingMore = true;
      _conversations = context
          .read<ChatRepository>()
          .watchConversations(uid, limit: _listLimit)
          .map((page) {
            _loadingMore = false;
            return page;
          });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _listLimit = 50;
      _loadingMore = false;
      _conversations = context.read<ChatRepository>().watchConversations(
        uid,
        limit: _listLimit,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = _conversations;
    final uid = _loadedFor;
    if (stream == null || uid == null) return const LoadingView();
    final columns = Breakpoints.columns(context, minTile: 440);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification.metrics.extentAfter < 300) {
          _loadMore();
        }
        return false;
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: StreamBuilder<CappedList<Conversation>>(
          stream: stream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              _loadingMore = false;
              return ErrorView(
                message: 'Could not load conversations.',
                onRetry: () => setState(() {
                  _conversations = context
                      .read<ChatRepository>()
                      .watchConversations(uid, limit: _listLimit);
                }),
              );
            }
            if (!snapshot.hasData) {
              return const LoadingView(skeleton: true);
            }
            final page = snapshot.data!;
            _hasMore = page.truncated;
            final conversations = page.items;
            if (conversations.isEmpty) {
              return EmptyView(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'No messages yet',
                message:
                    'Open a service and tap Message to talk to the seller. '
                    'Offers and orders start here.',
                actionLabel: 'Browse services',
                onAction: () => context.go('/'),
              );
            }
            final unread = conversations
                .where((c) => c.unreadFor(uid) > 0)
                .length;
            return CustomScrollView(
              slivers: [
                if (unread > 0)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        '$unread unread',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  sliver: columns == 1
                      ? SliverList.separated(
                          itemCount: conversations.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) => _ConversationTile(
                            conversation: conversations[i],
                            myUid: uid,
                          ),
                        )
                      : SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                mainAxisExtent:
                                    36 +
                                    MediaQuery.textScalerOf(context).scale(48),
                              ),
                          itemCount: conversations.length,
                          itemBuilder: (context, i) => _ConversationTile(
                            conversation: conversations[i],
                            myUid: uid,
                          ),
                        ),
                ),
                if (page.truncated)
                  SliverToBoxAdapter(
                    child: TextButton(
                      onPressed: _loadingMore ? null : _loadMore,
                      child: Text(
                        _loadingMore ? 'Loading?' : 'Load older records',
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.myUid});

  final Conversation conversation;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fromMe = conversation.lastMessageSenderId == myUid;
    final unread = conversation.unreadFor(myUid);
    final other = conversation.otherParticipant(myUid);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => context.push('/chat/${conversation.id}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          child: Row(
            children: [
              UserAvatarFor(
                uid: other,
                radius: 24,
                ring: unread > 0 ? theme.colorScheme.primary : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: UserName(
                            uid: other,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread > 0
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (conversation.lastMessageAt != null)
                          Text(
                            _timeOf(conversation.lastMessageAt!),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: unread > 0
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.lastMessagePreview.isEmpty
                                ? 'Started a conversation'
                                : '${fromMe ? 'You: ' : ''}${conversation.lastMessagePreview}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: unread > 0
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Badge.count(
                            count: unread,
                            backgroundColor: theme.colorScheme.primary,
                            textColor: theme.colorScheme.onPrimary,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeOf(DateTime time) {
    final now = DateTime.now();
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    if (sameDay) return DateFormat.jm().format(time);
    if (now.difference(time).inDays < 7) return DateFormat.E().format(time);
    return DateFormat.MMMd().format(time);
  }
}
