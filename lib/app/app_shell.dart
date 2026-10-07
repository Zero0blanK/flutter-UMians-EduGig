import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/platform/platform_repository.dart';
import '../core/widgets/lily.dart';
import '../features/admin/domain/admin_access.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/chat/data/chat_repository.dart';
import '../features/chat/domain/chat_models.dart';
import '../core/widgets/capped_list.dart';
import '../features/notifications/data/notification_repository.dart';
import '../features/notifications/domain/app_notification.dart';

/// Root scaffold: the four destinations, laid out for the screen.
///
/// On a phone they are a bottom bar. From [Breakpoints.desktop] up they move
/// to a rail on the left with the lily mark above them, and the content gets
/// the width a desktop actually has. Same four places either way: Home,
/// Orders, Messages, and Me — a student's own things gathered in one tab
/// rather than spread across the bar.
///
/// Also shows an in-app banner when a new notification arrives while the app
/// is foregrounded (from the Firestore stream, not FCM: push is for the lock
/// screen, and the same news twice is worse than once), and the staff
/// announcement or order pause from `settings/platform`.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _lastUnseen = -1;

  late final Stream<PlatformSettings> _settings = context
      .read<PlatformSettingsRepository>()
      .watch();

  /// The shell's two Firestore listeners live for the whole session, so they
  /// are the ones worth closing when the app leaves the foreground: an idle
  /// listener costs nothing, but one that reconnects after a long pause
  /// re-reads its whole result set. Both are rebuilt on resume.
  Stream<CappedList<Conversation>>? _conversations;
  StreamSubscription<List<AppNotification>>? _unread;
  String? _listeningFor;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unread?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is a system sheet or a transition, not a departure; tearing
    // down there would recreate the listeners many times a session.
    final foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      setState(() => _listen(context.read<AuthController>().uid));
    } else {
      setState(_stopListening);
    }
  }

  void _stopListening() {
    _unread?.cancel();
    _unread = null;
    _conversations = null;
    _listeningFor = null;
    // The first snapshot after a resume is a catch-up, not news.
    _lastUnseen = -1;
  }

  /// (Re)creates the listeners for [uid]; a no-op while they already belong
  /// to that user, and a teardown when there is no user.
  void _listen(String? uid) {
    if (uid == _listeningFor) return;
    _stopListening();
    if (uid == null || !_foreground) return;
    _listeningFor = uid;
    _conversations = context.read<ChatRepository>().watchConversations(uid);
    _unread = context.read<NotificationRepository>().watchUnread(uid).listen((
      unread,
    ) {
      if (!mounted) return;
      if (_lastUnseen >= 0 && unread.length > _lastUnseen) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(unread.first.title),
            action: SnackBarAction(
              label: 'View',
              onPressed: () => context.push('/notifications'),
            ),
          ),
        );
      }
      _lastUnseen = unread.length;
    }, onError: (_) {});
  }

  static const _destinations = [
    (
      path: '/',
      label: 'Home',
      icon: Icons.storefront_outlined,
      active: Icons.storefront_rounded,
    ),
    (
      path: '/orders',
      label: 'Orders',
      icon: Icons.receipt_long_outlined,
      active: Icons.receipt_long_rounded,
    ),
    (
      path: '/chats',
      label: 'Messages',
      icon: Icons.chat_bubble_outline_rounded,
      active: Icons.chat_bubble_rounded,
    ),
    (
      path: '/profile',
      label: 'Me',
      icon: Icons.person_outline_rounded,
      active: Icons.person_rounded,
    ),
  ];

  List<({String path, String label, IconData icon, IconData active})>
  _destinationsFor(String? firstName) => [
    ..._destinations.take(3),
    (
      path: '/profile',
      label: firstName == null || firstName.isEmpty ? 'Me' : firstName,
      icon: Icons.person_outline_rounded,
      active: Icons.person_rounded,
    ),
  ];

  int _indexFor(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    for (var i = _destinations.length - 1; i >= 0; i--) {
      final path = _destinations[i].path;
      if (path == '/' ? location == '/' : location.startsWith(path)) return i;
    }
    return 0;
  }

  void _select(int index) => context.go(_destinations[index].path);

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthController>().uid;
    final profile = context.watch<AuthController>().profile;
    final name = profile?.displayName.trim() ?? '';
    final firstName = name.isEmpty ? null : name.split(RegExp(r'\s+')).first;
    final destinations = _destinationsFor(firstName);
    // Keyed on the uid, so a sign-out or account switch swaps the listeners
    // rather than leaking the previous user's.
    _listen(uid);
    final wide = Breakpoints.isWide(context);
    final index = _indexFor(context);

    final body = Column(
      children: [
        _Banner(settings: _settings),
        Expanded(child: widget.child),
      ],
    );

    // Unread messages badge the Messages destination, from the same stream
    // the Messages tab reads.
    Widget withUnread(Widget icon) {
      final stream = _conversations;
      if (uid == null || stream == null) return icon;
      return StreamBuilder<CappedList<Conversation>>(
        stream: stream,
        builder: (context, snapshot) {
          final unread =
              snapshot.data?.items.fold<int>(
                0,
                (sum, c) => sum + c.unreadFor(uid),
              ) ??
              0;
          if (unread == 0) return icon;
          return Badge.count(count: unread, child: icon);
        },
      );
    }

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: _select,
              extended: MediaQuery.sizeOf(context).width >= 1280,
              minExtendedWidth: 200,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LilyMark(size: 40),
              ),
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: d.label == 'Messages'
                        ? withUnread(Icon(d.icon))
                        : Icon(d.icon),
                    selectedIcon: Icon(d.active),
                    label: Text(d.label),
                  ),
              ],
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Material(
          color:
              Theme.of(context).navigationBarTheme.backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: SizedBox(
            height: 76,
            child: Row(
              children: [
                for (var i = 0; i < destinations.length; i++)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: i == index,
                      label: destinations[i].label,
                      child: InkWell(
                        onTap: () => _select(i),
                        borderRadius: BorderRadius.circular(28),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 7,
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: i == index
                                  ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                withUnread(
                                  Icon(
                                    i == index
                                        ? destinations[i].active
                                        : destinations[i].icon,
                                    color: i == index
                                        ? Theme.of(context)
                                              .colorScheme
                                              .onPrimaryContainer
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  destinations[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context)
                                          .navigationBarTheme
                                          .labelTextStyle
                                          ?.resolve({
                                            if (i == index)
                                              WidgetState.selected,
                                          }) ??
                                      Theme.of(context).textTheme.labelSmall,
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

/// The staff announcement and the order pause, when either is set.
class _Banner extends StatefulWidget {
  const _Banner({required this.settings});

  final Stream<PlatformSettings> settings;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  Timer? _expiryTimer;
  DateTime? _scheduledExpiry;

  void _scheduleExpiry(DateTime? expiry) {
    if (_scheduledExpiry == expiry) return;
    _expiryTimer?.cancel();
    _scheduledExpiry = expiry;
    if (expiry == null || !expiry.isAfter(DateTime.now())) return;
    _expiryTimer = Timer(expiry.difference(DateTime.now()), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlatformSettings>(
      stream: widget.settings,
      builder: (context, snapshot) {
        final s = snapshot.data ?? PlatformSettings.none;
        _scheduleExpiry(s.announcementExpiresAt);
        final announcement = s.hasActiveAnnouncement ? s.announcement : '';
        if (announcement.isEmpty && !s.ordersPaused) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.tertiaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    s.ordersPaused
                        ? Icons.pause_circle_outline
                        : Icons.campaign_outlined,
                    size: 18,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [
                        if (s.ordersPaused)
                          'New orders are paused by the platform for now.',
                        if (announcement.isNotEmpty) announcement,
                      ].join(' '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
