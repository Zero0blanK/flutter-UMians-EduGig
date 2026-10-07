import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/feedback.dart';
import '../../../core/widgets/capped_list.dart';
import '../../../core/widgets/content_width.dart';
import '../../../core/widgets/lily.dart';
import '../../../core/widgets/status_views.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/notification_repository.dart';
import '../domain/app_notification.dart';
import '../notification_router.dart';

/// The inbox, grouped by day, unread rows marked with a lily dot and bold
/// title. Each row's icon and tint say what kind of news it is before the
/// title is read: money is green, orders lily, reviews pollen.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  /// Held rather than rebuilt in `build`: a fresh stream object each rebuild
  /// tears down and re-establishes the Firestore listener.
  Stream<CappedList<AppNotification>>? _notifications;
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
      _notifications = context
          .read<NotificationRepository>()
          .watchNotifications(uid, limit: _listLimit)
          .map((page) {
            _loadingMore = false;
            return page;
          });
    });
  }

  bool _markingRead = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.watch<AuthController>().uid;
    if (uid != null && uid != _loadedFor) {
      _loadedFor = uid;
      _listLimit = 50;
      _loadingMore = false;
      _notifications = context
          .read<NotificationRepository>()
          .watchNotifications(uid, limit: _listLimit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _loadedFor;
    final stream = _notifications;
    final repository = context.read<NotificationRepository>();

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification.metrics.extentAfter < 300) {
          _loadMore();
        }
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          actions: [
            if (uid != null)
              TextButton.icon(
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: Text(_markingRead ? 'Marking read...' : 'Mark all read'),
                onPressed: _markingRead
                    ? null
                    : () async {
                        setState(() => _markingRead = true);
                        try {
                          await repository.markAllRead(uid);
                        } catch (failure) {
                          if (context.mounted) {
                            showFailureSnackBar(
                              context,
                              AppFailure.from(failure),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _markingRead = false);
                        }
                      },
              ),
          ],
        ),
        body: uid == null || stream == null
            ? const SizedBox.shrink()
            : ContentWidth(
                child: StreamBuilder<CappedList<AppNotification>>(
                  stream: stream,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      _loadingMore = false;
                      return ErrorView(
                        message: 'Could not load notifications.',
                        onRetry: () => setState(() {
                          _notifications = repository.watchNotifications(
                            uid,
                            limit: _listLimit,
                          );
                        }),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const LoadingView(skeleton: true);
                    }
                    final page = snapshot.data!;
                    _hasMore = page.truncated;
                    final notifications = page.items;
                    if (notifications.isEmpty) {
                      return const EmptyView(
                        icon: Icons.notifications_none_rounded,
                        title: 'All quiet',
                        message:
                            'Order updates, messages, payments and reviews '
                            'land here.',
                      );
                    }
                    final rows = _group(notifications);
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: rows.length + (page.truncated ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == rows.length) {
                          return TextButton(
                            onPressed: _loadingMore ? null : _loadMore,
                            child: Text(
                              _loadingMore ? 'Loading?' : 'Load older records',
                            ),
                          );
                        }
                        final row = rows[index];
                        if (row is String) {
                          return Padding(
                            padding: EdgeInsets.fromLTRB(
                              4,
                              index == 0 ? 8 : 20,
                              4,
                              8,
                            ),
                            child: Text(
                              row,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _NotificationTile(
                            notification: row as AppNotification,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }

  /// Day labels interleaved with the notifications under them.
  static List<Object> _group(List<AppNotification> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final rows = <Object>[];
    String? current;
    for (final n in items) {
      final day = DateTime(
        n.createdAt.year,
        n.createdAt.month,
        n.createdAt.day,
      );
      final label = day == today
          ? 'Today'
          : day == today.subtract(const Duration(days: 1))
          ? 'Yesterday'
          : DateFormat.MMMEd().format(day);
      if (label != current) {
        current = label;
        rows.add(label);
      }
      rows.add(n);
    }
    return rows;
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification});

  final AppNotification notification;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, tint) = switch (notification.type) {
      AppNotificationType.chatMessage => (
        Icons.chat_bubble_outline_rounded,
        scheme.primary,
      ),
      AppNotificationType.offerReceived ||
      AppNotificationType.offerAccepted ||
      AppNotificationType.offerDeclined => (
        Icons.local_offer_outlined,
        scheme.primary,
      ),
      AppNotificationType.paymentConfirmed ||
      AppNotificationType.paymentReleased ||
      AppNotificationType.paymentRefunded ||
      AppNotificationType.payoutPaid ||
      AppNotificationType.payoutRejected ||
      AppNotificationType.paymentChargedBack ||
      AppNotificationType.walletDormant => (
        Icons.payments_outlined,
        scheme.secondary,
      ),
      AppNotificationType.reviewReceived => (
        Icons.star_rounded,
        scheme.tertiary,
      ),
      AppNotificationType.proActivated ||
      AppNotificationType.verificationApproved ||
      AppNotificationType.verificationRejected => (
        Icons.workspace_premium_outlined,
        scheme.tertiary,
      ),
      AppNotificationType.systemAnnouncement => (
        Icons.campaign_outlined,
        scheme.tertiary,
      ),
      AppNotificationType.adminRefundAttention ||
      AppNotificationType.adminPayoutRequested ||
      AppNotificationType.adminVerificationPending ||
      AppNotificationType.adminDormantWallet => (
        Icons.shield_outlined,
        scheme.error,
      ),
      _ => (Icons.receipt_long_outlined, scheme.primary),
    };
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () =>
            NotificationRouter(context)
                .routeFromData(notification.toRouteData()),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Badge(
                isLabelVisible: !notification.read,
                smallSize: 10,
                backgroundColor: scheme.primary,
                child: IconDisc(icon: icon, tint: tint, size: 40),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: notification.read
                                  ? FontWeight.w600
                                  : FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          DateFormat.jm().format(notification.createdAt),
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    if (notification.body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        notification.body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: notification.read
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
