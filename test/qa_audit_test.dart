import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_freelance_services/app/theme/app_theme.dart';
import 'package:student_freelance_services/app/theme/appearance_card.dart';
import 'package:student_freelance_services/app/theme/theme_controller.dart';
import 'package:student_freelance_services/core/errors/app_failure.dart';
import 'package:student_freelance_services/core/platform/platform_repository.dart';
import 'package:student_freelance_services/core/widgets/capped_list.dart';
import 'package:student_freelance_services/features/auth/domain/user_profile.dart';
import 'package:student_freelance_services/features/auth/presentation/auth_controller.dart';
import 'package:student_freelance_services/features/chat/data/chat_repository.dart';
import 'package:student_freelance_services/features/chat/domain/chat_models.dart';
import 'package:student_freelance_services/features/chat/presentation/conversations_screen.dart';
import 'package:student_freelance_services/features/marketplace/presentation/marketplace_screen.dart';
import 'package:student_freelance_services/features/marketplace/domain/featured_session.dart';
import 'package:student_freelance_services/features/notifications/data/notification_repository.dart';
import 'package:student_freelance_services/features/notifications/domain/app_notification.dart';
import 'package:student_freelance_services/features/notifications/presentation/notifications_screen.dart';
import 'package:student_freelance_services/features/reviews/data/review_repository.dart';
import 'package:student_freelance_services/features/reviews/presentation/reviews_screen.dart';
import 'package:student_freelance_services/features/services/data/service_repository.dart';
import 'package:student_freelance_services/features/services/domain/freelance_service.dart';

class _Auth extends Fake implements AuthController {
  @override
  String get uid => 'student';
  @override
  UserProfile? get profile => null;
}

class _Settings extends Fake implements PlatformSettingsRepository {
  @override
  Stream<List<({String id, String label})>> watchCategories() =>
      Stream.value([]);
}

class _Services extends Fake implements ServiceRepository {
  final requests = <Completer<ServicePage>>[];
  final featuredRequests = <int>[];
  final featuredCategories = <String?>[];
  bool featuredFails = false;
  List<FreelanceService> featured = const [];

  @override
  Future<ServicePage> fetchPublished({
    String? categoryId,
    String? search,
    ServiceSort sort = ServiceSort.newest,
    DocumentSnapshot? startAfter,
  }) {
    final request = Completer<ServicePage>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<FreelanceService>> fetchFeaturedSelection(
    List<String> ids,
  ) async => [
    for (final id in ids) ...featured.where((service) => service.id == id),
  ];

  @override
  Future<FeaturedServicePage> fetchFeatured({
    String? categoryId,
    int pageIndex = 0,
    int sessionSeed = 0,
    Set<String> excludedSellerIds = const {},
  }) async {
    featuredRequests.add(pageIndex);
    featuredCategories.add(categoryId);
    if (featuredFails) throw const NetworkFailure();
    final pageCount = (featured.length + 2) ~/ 3;
    final page = featured
        .skip(pageIndex * 3)
        .take(3)
        .where((service) => !excludedSellerIds.contains(service.sellerId))
        .toList();
    return FeaturedServicePage(
      items: page,
      exhausted: pageIndex + 1 >= pageCount,
    );
  }
}

class _Chat extends Fake implements ChatRepository {
  int subscriptions = 0;
  @override
  Future<PeerSummary> summaryOf(String uid) async =>
      const PeerSummary(name: 'Student', verified: false);
  @override
  Future<String> displayNameOf(String uid) async => 'Student';
  @override
  Stream<CappedList<Conversation>> watchConversations(
    String uid, {
    int limit = 50,
  }) {
    subscriptions++;
    return subscriptions == 1
        ? Stream.error(const NetworkFailure())
        : Stream.value(const CappedList.complete([]));
  }
}

class _Notifications extends Fake implements NotificationRepository {
  final marking = Completer<void>();
  @override
  Stream<CappedList<AppNotification>> watchNotifications(
    String uid, {
    int limit = 50,
  }) => Stream.value(const CappedList.complete([]));
  @override
  Future<void> markAllRead(String uid) => marking.future;
}

class _Reviews extends Fake implements ReviewRepository {
  int distributionReads = 0;
  @override
  Future<RatingDistribution> distributionOf(ReviewTarget target) async {
    if (++distributionReads == 1) throw const NetworkFailure();
    return RatingDistribution.empty;
  }

  @override
  Future<ReviewPage> fetchReviews({
    required ReviewTarget target,
    ReviewSort sort = ReviewSort.newest,
    int? rating,
    DocumentSnapshot? startAfter,
  }) async => const ReviewPage(items: [], lastDocument: null, exhausted: true);
}

FreelanceService _listing(
  String title, {
  String? sellerId,
  bool featured = false,
}) => FreelanceService(
  id: title,
  sellerId: sellerId ?? 'seller',
  title: title,
  description: '',
  categoryId: 'programming',
  skills: const [],
  startingPrice: 500,
  currency: 'PHP',
  deliveryDays: 3,
  revisionCount: 1,
  status: ServiceStatus.published,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  featuredUntil: featured ? DateTime.now().add(const Duration(days: 2)) : null,
);

ServicePage _page(String title, {bool exhausted = true}) => ServicePage(
  items: exhausted
      ? [_listing(title)]
      : List.generate(
          ServiceRepository.pageSize,
          (index) => _listing(index == 0 ? title : '$title $index'),
        ),
  lastDocument: null,
  exhausted: exhausted,
);

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  _Chat? chat,
  _Reviews? reviews,
  _Notifications? notifications,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<AuthController>.value(value: _Auth()),
        Provider<PlatformSettingsRepository>.value(value: _Settings()),
        Provider<ChatRepository>.value(value: chat ?? _Chat()),
        Provider<ReviewRepository>.value(value: reviews ?? _Reviews()),
        Provider<NotificationRepository>.value(
          value: notifications ?? _Notifications(),
        ),
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 1200),
            textScaler: TextScaler.linear(scale),
          ),
          child: screen,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'featured survives tab recreation and background without a popup',
    (tester) async {
      final session = FeaturedSession();
      final services = _Services()
        ..featured = List.generate(
          9,
          (index) => _listing(
            'Placement $index',
            sellerId: 'featured-$index',
            featured: true,
          ),
        );
      await _pump(
        tester,
        MarketplaceScreen(repository: services, featuredSession: session),
      );
      services.requests.last.complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      expect(find.text('Featured for you'), findsOneWidget);
      await tester.tap(find.byTooltip('Close showcase'));
      await tester.pumpAndSettle();
      final firstSelection = session.services
          .take(5)
          .map((service) => service.id)
          .toList();
      final requests = services.featuredRequests.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Featured for you'), findsNothing);
      expect(services.featuredRequests.length, requests);
      await tester.pumpWidget(const SizedBox());
      await _pump(
        tester,
        MarketplaceScreen(repository: services, featuredSession: session),
      );
      services.requests.last.complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      expect(find.text('Featured for you'), findsNothing);
      expect(
        session.services.take(5).map((service) => service.id),
        firstSelection,
      );
      expect(services.featuredRequests.length, requests);
      // Expiry rotates the cards without reopening the launch modal.
      session.selectedAt = DateTime.now().subtract(const Duration(minutes: 30));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(services.featuredRequests.length, greaterThan(requests));
      expect(find.text('Featured for you'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'today checkbox persists suppression across launches and can be cleared',
    (tester) async {
      final services = _Services()
        ..featured = List.generate(
          6,
          (index) => _listing(
            'Placement $index',
            sellerId: 'featured-$index',
            featured: true,
          ),
        );
      await _pump(
        tester,
        MarketplaceScreen(
          repository: services,
          featuredSession: FeaturedSession(),
        ),
      );
      services.requests.last.complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getInt('featured_showcase_suppressed_until'),
        FeaturedSession.nextDay(DateTime.now()).millisecondsSinceEpoch,
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(preferences.getInt('featured_showcase_suppressed_until'), isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close showcase'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await _pump(
        tester,
        MarketplaceScreen(
          repository: services,
          featuredSession: FeaturedSession(),
        ),
      );
      services.requests.last.complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      expect(find.text('Featured for you'), findsNothing);
      expect(find.text('Featured'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'relaunch shows popup with the saved selection before 30 minutes',
    (tester) async {
      final services = _Services()
        ..featured = List.generate(
          9,
          (index) => _listing(
            'Placement $index',
            sellerId: 'featured-$index',
            featured: true,
          ),
        );
      final original = FeaturedSession();
      await _pump(
        tester,
        MarketplaceScreen(repository: services, featuredSession: original),
      );
      services.requests.last.complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close showcase'));
      await tester.pumpAndSettle();
      final selected = original.services
          .take(5)
          .map((service) => service.id)
          .toList();
      final requests = services.featuredRequests.length;
      await tester.pumpWidget(const SizedBox());
      final relaunched = FeaturedSession();
      await _pump(
        tester,
        MarketplaceScreen(repository: services, featuredSession: relaunched),
      );
      services.requests.last.complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      expect(find.text('Featured for you'), findsOneWidget);
      expect(relaunched.services.map((service) => service.id), selected);
      expect(services.featuredRequests.length, requests);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('saved category does not hide global Featured or its showcase', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'marketplace_category_id': 'writing',
    });
    final services = _Services()
      ..featured = List.generate(
        6,
        (index) => _listing(
          'Featured item $index',
          sellerId: 'seller-$index',
          featured: true,
        ),
      );
    await _pump(tester, MarketplaceScreen(repository: services));
    // Featured must load even while the regular service request is pending.
    await tester.pump();
    expect(find.text('Featured for you'), findsOneWidget);
    expect(services.featuredCategories, everyElement(isNull));
    expect(
      tester
          .widget<PageView>(find.byType(PageView))
          .childrenDelegate
          .estimatedChildCount,
      6,
    );
    services.requests.single.completeError(const NetworkFailure());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close showcase'));
    await tester.pumpAndSettle();
    expect(find.text('Featured'), findsOneWidget);
    expect(find.text('Featured item 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('featured failure shows retry and recovery opens the showcase', (
    tester,
  ) async {
    final services = _Services()..featuredFails = true;
    await _pump(tester, MarketplaceScreen(repository: services));
    services.requests.single.complete(_page('Regular result'));
    await tester.pumpAndSettle();
    expect(find.text('Featured'), findsOneWidget);
    expect(find.text('Retry featured listings'), findsOneWidget);
    services
      ..featuredFails = false
      ..featured = List.generate(
        6,
        (index) => _listing(
          'Featured item $index',
          sellerId: 'seller-$index',
          featured: true,
        ),
      );
    await tester.tap(find.text('Retry featured listings'));
    await tester.pumpAndSettle();
    expect(find.text('Featured for you'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty featured pool is visible instead of silently disappearing',
    (tester) async {
      final services = _Services();
      await _pump(tester, MarketplaceScreen(repository: services));
      services.requests.single.complete(_page('Regular result'));
      await tester.pumpAndSettle();
      expect(find.text('Featured'), findsOneWidget);
      expect(
        find.text('No active featured listings right now.'),
        findsOneWidget,
      );
    },
  );

  for (final staleFails in [false, true]) {
    testWidgets(
      'old marketplace response cannot replace search (failure=$staleFails)',
      (tester) async {
        final services = _Services();
        await _pump(tester, MarketplaceScreen(repository: services));
        await tester.enterText(find.byType(TextField), 'new query');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(services.requests, hasLength(2));
        services.requests[1].complete(_page('Matching new result'));
        await tester.pumpAndSettle();
        if (staleFails) {
          services.requests[0].completeError(const NetworkFailure());
        } else {
          services.requests[0].complete(_page('Stale result'));
        }
        await tester.pumpAndSettle();
        expect(find.text('Matching new result'), findsOneWidget);
        expect(find.text('Stale result'), findsNothing);
        expect(find.text('Something went wrong'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('featured popup pages while marketplace retains five cards', (
    tester,
  ) async {
    final services = _Services()
      ..featured = List.generate(
        9,
        (index) => _listing(
          'Featured item ${index + 1}',
          sellerId: 'featured-seller-$index',
          featured: true,
        ),
      );
    await _pump(tester, MarketplaceScreen(repository: services));
    services.requests.single.complete(
      ServicePage(
        items: [_listing('Regular result'), services.featured.first],
        lastDocument: null,
        exhausted: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Featured for you'), findsOneWidget);
    expect(services.featuredRequests, [0, 1]);
    for (var index = 0; index < 4; index++) {
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
    }
    expect(services.featuredRequests, [0, 1, 2]);
    await tester.tap(find.byTooltip('Close showcase'));
    await tester.pumpAndSettle();
    expect(find.text('Regular result'), findsOneWidget);
    expect(find.text('Featured item 1'), findsOneWidget);

    final horizontalLists = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    await tester.drag(horizontalLists.last, const Offset(-1200, 0));
    await tester.pumpAndSettle();
    expect(services.featuredRequests, [0, 1, 2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'regular marketplace results continue past a featured-only page',
    (tester) async {
      final services = _Services();
      await _pump(tester, MarketplaceScreen(repository: services));
      services.requests[0].complete(
        ServicePage(
          items: List.generate(
            ServiceRepository.pageSize,
            (index) => _listing(
              'Featured listing $index',
              sellerId: 'featured-seller-$index',
              featured: true,
            ),
          ),
          lastDocument: null,
          exhausted: false,
        ),
      );
      await tester.pump();
      expect(services.requests, hasLength(2));
      services.requests[1].complete(_page('Regular listing'));
      await tester.pumpAndSettle();
      expect(find.text('Regular listing'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pagination failure preserves results and offers a working retry',
    (tester) async {
      final services = _Services();
      await _pump(tester, MarketplaceScreen(repository: services));
      services.requests[0].complete(_page('First result', exhausted: false));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Load more services'));
      await tester.tap(find.text('Load more services'));
      await tester.pump();
      services.requests[1].completeError(const NetworkFailure());
      await tester.pumpAndSettle();
      expect(find.text('First result'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.ensureVisible(find.text('Retry loading services'));
      await tester.tap(find.text('Retry loading services'));
      await tester.pump();
      services.requests[2].complete(_page('Second result'));
      await tester.pumpAndSettle();
      expect(find.text('First result'), findsOneWidget);
      expect(find.text('Second result'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('messages retry opens a new subscription', (tester) async {
    final chat = _Chat();
    await _pump(tester, const ConversationsScreen(), chat: chat);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(chat.subscriptions, 2);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rating breakdown failure has a working retry', (tester) async {
    final reviews = _Reviews();
    await _pump(
      tester,
      const ReviewsScreen(target: ReviewTarget.service('service')),
      reviews: reviews,
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load the rating breakdown.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(reviews.distributionReads, 2);
    expect(find.text('Could not load the rating breakdown.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mark-all-read reports failure and re-enables the action', (
    tester,
  ) async {
    final notifications = _Notifications();
    await _pump(
      tester,
      const NotificationsScreen(),
      notifications: notifications,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark all read'));
    await tester.pump();
    final busy = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Marking read...'),
    );
    expect(busy.onPressed, isNull);
    notifications.marking.completeError(const NetworkFailure());
    await tester.pumpAndSettle();
    expect(find.text(const NetworkFailure().message), findsOneWidget);
    expect(find.text('Mark all read'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'marketplace categories and longest sort fit enlarged phone text',
    (tester) async {
      final services = _Services();
      await _pump(tester, MarketplaceScreen(repository: services), scale: 2);
      services.requests[0].complete(_page('Service title'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Newest'));
      await tester.tap(find.text('Newest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price: high to low'));
      await tester.pump();
      services.requests[1].complete(_page('Service title'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('appearance options fit a phone at large text size', (
    tester,
  ) async {
    await _pump(
      tester,
      const Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: EdgeInsets.all(16), child: AppearanceCard()),
        ),
      ),
      scale: 2,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final control = tester.widget<SegmentedButton<ThemeMode>>(
      find.byType(SegmentedButton<ThemeMode>),
    );
    expect(control.direction, Axis.vertical);
  });
}
