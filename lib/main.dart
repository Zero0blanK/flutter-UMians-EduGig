import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/router/app_router.dart';
import 'app/theme/app_theme.dart';
import 'app/theme/theme_controller.dart';
import 'core/backend/backend_client.dart';
import 'core/config/app_environment.dart';
import 'core/platform/platform_repository.dart';
import 'core/storage/storage_repository.dart';
import 'core/widgets/status_views.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/admin/data/admin_repository.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/chat/data/chat_repository.dart';
import 'features/notifications/data/notification_repository.dart';
import 'features/notifications/data/push_service.dart';
import 'features/notifications/notification_router.dart';
import 'features/offers/data/offer_repository.dart';
import 'features/orders/data/order_repository.dart';
import 'features/payments/data/manual_payment_gateway.dart';
import 'features/payments/data/payment_gateway.dart';
import 'features/payments/data/payment_repository.dart';
import 'features/payments/data/xendit_gateway.dart';
import 'features/payments/payment_config.dart';
import 'features/pro/data/pro_repository.dart';
import 'features/reviews/data/review_repository.dart';
import 'features/services/data/service_repository.dart';
import 'features/marketplace/data/people_search_repository.dart';
import 'features/marketplace/domain/featured_session.dart';
import 'features/wallet/data/wallet_repository.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const BootstrapApp());
}

class BootstrapApp extends StatelessWidget {
  const BootstrapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FirebaseApp>(
      future: _initializeFirebase(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: ErrorView(
                message:
                    'Firebase failed to initialize.\n\n${snapshot.error}\n\n'
                    'Run "flutterfire configure" to generate the project '
                    'configuration.',
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            debugShowCheckedModeBanner: false,
            home: const Scaffold(body: LoadingView()),
          );
        }
        return ProviderScope(app: snapshot.data!);
      },
    );
  }
}

class ProviderScope extends StatefulWidget {
  const ProviderScope({super.key, required this.app});

  final FirebaseApp app;

  @override
  State<ProviderScope> createState() => _ProviderScopeState();
}

class _ProviderScopeState extends State<ProviderScope> {
  late final AuthRepository _authRepository;
  late final AuthController _authController;
  late final FirebaseFirestore _firestore;
  late final StorageRepository _storage;
  late final BackendClient _backend;
  late final AppRouter _router;
  late final PaymentConfig _paymentConfig;
  late final PaymentGateway _paymentGateway;
  late final PushService _push;
  late final ThemeController _themeController;

  @override
  void initState() {
    super.initState();
    final auth = FirebaseAuth.instanceFor(app: widget.app);
    _firestore = FirebaseFirestore.instanceFor(app: widget.app);
    _storage = StorageRepository(FirebaseStorage.instanceFor(app: widget.app));

    _authRepository = AuthRepository(auth, _firestore);
    _authController = AuthController(_authRepository);

    // Payments: the build ships in manual mode and switches to the backend
    // when PAYMENTS_API_URL is defined at build time. Only the binding
    // changes; no UI or repository code branches on the mode. The same
    // client serves payouts, Pro, and staff actions — every route that moves
    // money or grants an entitlement is decided server-side.
    _paymentConfig = PaymentConfig.fromEnvironment();
    _backend = BackendClient(
      baseUrl: _paymentConfig.backendUrl,
      idTokenProvider: () async => auth.currentUser?.getIdToken(),
    );
    _paymentGateway = switch (_paymentConfig.mode) {
      PaymentMode.manual => const ManualPaymentGateway(),
      PaymentMode.xendit => XenditGateway(_backend),
    };

    _router = AppRouter(_authController);

    // Push: register the device whenever someone signs in, forget it when
    // they sign out, and route a tapped notification through the same
    // NotificationRouter an inbox tap uses.
    _push = PushService(
      _firestore,
      messaging: PushService.isSupported ? FirebaseMessaging.instance : null,
    );
    _authController.addListener(_syncPushRegistration);
    _push.listenForTaps(
      (data) =>
          NotificationRouter.withRouter(_router.router).routeFromData(data),
    );
    _authController.init();

    _themeController = ThemeController();
    _themeController.load();
  }

  void _syncPushRegistration() {
    final uid = _authController.uid;
    if (uid != null) {
      _push.register(uid);
    } else if (_authController.status == AuthStatus.unauthenticated) {
      _push.unregister();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AuthRepository>.value(value: _authRepository),
        ChangeNotifierProvider<AuthController>.value(value: _authController),
        Provider<StorageRepository>.value(value: _storage),
        Provider<PlatformSettingsRepository>(
          create: (_) => PlatformSettingsRepository(_firestore),
        ),
        Provider<PushService>.value(value: _push),
        Provider<ChatRepository>(create: (_) => ChatRepository(_firestore)),
        Provider<FeaturedSession>(create: (_) => FeaturedSession()),
        Provider<ServiceRepository>(
          create: (_) => ServiceRepository(_firestore),
        ),
        Provider<PeopleSearchRepository>(
          create: (_) => PeopleSearchRepository(_backend),
        ),
        Provider<OrderRepository>(create: (_) => OrderRepository(_firestore)),
        Provider<OfferRepository>(create: (_) => OfferRepository(_firestore)),
        Provider<ReviewRepository>(create: (_) => ReviewRepository(_firestore)),
        Provider<NotificationRepository>(
          create: (_) => NotificationRepository(_firestore),
        ),
        Provider<AdminRepository>(
          create: (_) => AdminRepository(_firestore, _backend),
        ),
        Provider<PaymentRepository>(
          create: (_) =>
              PaymentRepository(_firestore, _paymentGateway, _paymentConfig),
        ),
        Provider<WalletRepository>(
          create: (_) => WalletRepository(_firestore, _backend),
        ),
        Provider<ProRepository>(
          create: (_) => ProRepository(_firestore, _backend, _storage),
        ),
        ChangeNotifierProvider<ThemeController>.value(value: _themeController),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) => MaterialApp.router(
          title: 'Student Freelance Services',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: theme.mode,
          routerConfig: _router.router,
          debugShowCheckedModeBanner: false,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _authController.removeListener(_syncPushRegistration);
    _authController.dispose();
    _themeController.dispose();
    _push.dispose();
    _backend.dispose();
    super.dispose();
  }
}

/// Production and development builds talk to the real project in
/// `firebase_options.dart`; an emulator build is redirected to the local
/// emulators. See [AppEnvironment].
Future<FirebaseApp> _initializeFirebase() async {
  checkAppEnvironment();
  final app = await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (kAppEnvironment.usesEmulator) {
    FirebaseFirestore.instanceFor(app: app)
        .useFirestoreEmulator(kEmulatorHost, 8080);
    await FirebaseAuth.instanceFor(app: app)
        .useAuthEmulator(kEmulatorHost, 9099);
    await FirebaseStorage.instanceFor(app: app)
        .useStorageEmulator(kEmulatorHost, 9199);
  }
  return app;
}
