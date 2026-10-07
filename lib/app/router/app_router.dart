import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/status_views.dart';
import '../../features/auth/presentation/auth_controller.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/chat/presentation/chat_screen.dart';
import '../../features/chat/presentation/conversations_screen.dart';
import '../../features/marketplace/presentation/marketplace_screen.dart';
import '../../features/marketplace/domain/featured_session.dart';
import '../../features/marketplace/data/people_search_repository.dart';
import '../../features/marketplace/presentation/service_detail_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/orders/presentation/create_order_screen.dart';
import '../../features/orders/presentation/order_detail_screen.dart';
import '../../features/orders/presentation/orders_screen.dart';
import '../../features/admin/presentation/admin_gate.dart';
import '../../features/payments/presentation/transactions_screen.dart';
import '../../features/payments/presentation/payment_return_screen.dart';
import '../../features/pro/presentation/pro_screen.dart';
import '../../features/profile/presentation/edit_profile_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/profile/presentation/public_profile_screen.dart';
import '../../features/auth/presentation/onboarding_screen.dart';
import '../../features/reviews/data/review_repository.dart';
import '../../features/reviews/presentation/reviews_screen.dart';
import '../../features/services/data/service_repository.dart';
import '../../features/services/presentation/edit_service_screen.dart';
import '../../features/services/presentation/my_services_screen.dart';
import '../../features/wallet/presentation/payout_account_screen.dart';
import '../../features/wallet/presentation/wallet_screen.dart';
import '../app_shell.dart';

class AppRouter {
  AppRouter(this._auth);

  final AuthController _auth;

  late final GoRouter router = GoRouter(
    refreshListenable: _auth,
    initialLocation: '/',
    redirect: (context, state) {
      final location = state.matchedLocation;
      final isPaymentReturn =
          location == '/payment/success' || location == '/payment/cancelled';
      return switch (_auth.status) {
        AuthStatus.loading => location == '/' || isPaymentReturn ? null : '/',
        AuthStatus.unauthenticated => location == '/login' ? null : '/login',
        AuthStatus.authenticated =>
          _auth.profile != null &&
                  !_auth.profile!.onboardingComplete &&
                  location != '/onboarding'
              ? '/onboarding'
              : location == '/onboarding' &&
                    _auth.profile?.onboardingComplete == true
              ? '/'
              : location == '/login'
              ? '/'
              : null,
      };
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: MarketplaceTab()),
          ),
          GoRoute(
            path: '/chats',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: ConversationsScreen()),
          ),
          GoRoute(
            path: '/orders',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: OrdersTab()),
          ),
          GoRoute(
            path: '/profile',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: ProfileScreen()),
          ),
        ],
      ),
      // Declared before '/service/:id': go_router matches in order, so the
      // parameterised route otherwise captured this path with id == 'new' and
      // the detail screen looked up a service by that name — "This item no
      // longer exists." on every attempt to add a listing.
      GoRoute(
        path: '/service/new',
        builder: (context, state) => const EditServiceScreen(),
      ),
      GoRoute(
        path: '/service/:id',
        builder: (context, state) => _guard(
          state.pathParameters['id'],
          (id) => ServiceDetailScreen(serviceId: id),
          fallback: 'Invalid service.',
        ),
      ),
      GoRoute(
        path: '/service/:id/reviews',
        builder: (context, state) => _guard(
          state.pathParameters['id'],
          (id) => ReviewsScreen(
            target: ReviewTarget.service(id),
            title: 'Service reviews',
          ),
          fallback: 'Invalid service.',
        ),
      ),
      GoRoute(
        path: '/user/:uid',
        builder: (context, state) => _guard(
          state.pathParameters['uid'],
          (uid) => PublicProfileScreen(uid: uid),
          fallback: 'Invalid profile.',
        ),
      ),
      GoRoute(
        path: '/user/:uid/reviews',
        builder: (context, state) => _guard(
          state.pathParameters['uid'],
          (uid) => ReviewsScreen(
            target: ReviewTarget.seller(uid),
            title: 'Reviews received',
          ),
          fallback: 'Invalid profile.',
        ),
      ),
      // Staff only. AdminGate checks the roster before building the console;
      // the enforcement itself lives in firestore.rules.
      GoRoute(path: '/admin', builder: (context, state) => const AdminGate()),
      GoRoute(
        path: '/service/:id/edit',
        builder: (context, state) => _guard(
          state.pathParameters['id'],
          (id) => EditServiceScreen(serviceId: id),
          fallback: 'Invalid service.',
        ),
      ),
      GoRoute(
        path: '/my-services',
        builder: (context, state) {
          final uid = _auth.uid;
          if (uid == null) return const InvalidRoute('Not signed in.');
          return MyServicesScreen(
            repository: context.read<ServiceRepository>(),
            sellerId: uid,
          );
        },
      ),
      GoRoute(
        path: '/order/new/:serviceId',
        builder: (context, state) => _guard(
          state.pathParameters['serviceId'],
          (id) => CreateOrderScreen(serviceId: id),
          fallback: 'Invalid service.',
        ),
      ),
      GoRoute(
        path: '/order/:id',
        builder: (context, state) => _guard(
          state.pathParameters['id'],
          (id) => OrderDetailScreen(
            orderId: id,
            staffReadOnly: state.uri.queryParameters['staffView'] == 'true',
          ),
          fallback: 'Invalid order.',
        ),
      ),
      GoRoute(
        path: '/payment/success',
        builder: (context, state) {
          final orderId = state.uri.queryParameters['order'];
          if (isValidId(orderId)) return PaymentReturnScreen(orderId: orderId!);
          if (state.uri.queryParameters['pro'] == '1') {
            return const ProPaymentReturnScreen();
          }
          return const InvalidRoute('Invalid payment return.');
        },
      ),
      GoRoute(
        path: '/payment/cancelled',
        builder: (context, state) {
          final orderId = state.uri.queryParameters['order'];
          if (isValidId(orderId)) {
            return PaymentCancelledScreen(orderId: orderId!);
          }
          if (state.uri.queryParameters['pro'] == '1') {
            return const InvalidRoute('Pro checkout was cancelled.');
          }
          return const InvalidRoute('Invalid payment return.');
        },
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (context, state) => _guard(
          state.pathParameters['id'],
          (id) => ChatScreen(
            key: ValueKey('$id:${state.uri.queryParameters['service'] ?? ''}'),
            conversationId: id,
            serviceId: state.uri.queryParameters['service'],
          ),
          fallback: 'Invalid conversation.',
        ),
      ),
      GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/profile/edit',
        builder: (context, state) => const EditProfileScreen(),
      ),
      GoRoute(
        path: '/wallet',
        builder: (context, state) => const WalletScreen(),
      ),
      GoRoute(
        path: '/transactions',
        builder: (context, state) => const TransactionsScreen(),
      ),
      GoRoute(
        path: '/wallet/account',
        builder: (context, state) => PayoutAccountScreen(
          initialType: state.uri.queryParameters['type'],
          returnOnSave: state.uri.queryParameters['setup'] == 'pro',
        ),
      ),
      GoRoute(path: '/pro', builder: (context, state) => const ProScreen()),
    ],
  );

  /// IDs arrive from external sources (deep links, notification payloads)
  /// and are validated before they are used in any screen or query.
  static bool isValidId(String? id) =>
      id != null &&
      id.isNotEmpty &&
      id.length <= 120 &&
      !id.contains('/') &&
      !id.contains('..');

  static Widget _guard(
    String? id,
    Widget Function(String id) build, {
    required String fallback,
  }) => isValidId(id) ? build(id!) : InvalidRoute(fallback);
}

class MarketplaceTab extends StatelessWidget {
  const MarketplaceTab({super.key});

  @override
  Widget build(BuildContext context) {
    return MarketplaceScreen(
      repository: context.read<ServiceRepository>(),
      featuredSession: context.read<FeaturedSession>(),
      peopleSearchRepository: context.read<PeopleSearchRepository>(),
    );
  }
}

class InvalidRoute extends StatelessWidget {
  const InvalidRoute(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: ErrorView(message: message));
  }
}
