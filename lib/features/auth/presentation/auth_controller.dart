import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_failure.dart';
import '../data/auth_repository.dart';
import '../domain/user_profile.dart';

enum AuthStatus { loading, authenticated, unauthenticated }

/// Single source of truth for the authentication gate used by the router
/// redirect and screens that need the current user or profile.
class AuthController extends ChangeNotifier {
  AuthController(this._repository);

  final AuthRepository _repository;

  AuthStatus status = AuthStatus.loading;
  UserProfile? profile;

  StreamSubscription<void>? _authSubscription;
  StreamSubscription<UserProfile>? _profileSubscription;
  bool _disposed = false;
  int _authGeneration = 0;

  /// The auth listener resolves the profile asynchronously, so a notification
  /// can land after this controller is gone. Notifying a disposed
  /// ChangeNotifier throws, so every path goes through here.
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  String? get uid =>
      status == AuthStatus.authenticated ? _repository.currentUser?.uid : null;

  bool get isEmailVerified => _repository.isEmailVerified;

  void init() {
    _authSubscription = _repository.authStateChanges.listen((user) async {
      final generation = ++_authGeneration;
      await _profileSubscription?.cancel();
      _profileSubscription = null;
      if (_disposed || generation != _authGeneration) return;
      if (user == null) {
        profile = null;
        status = AuthStatus.unauthenticated;
      } else {
        try {
          // Recreates the profile if signup failed between the auth account
          // and the profile write, so a half-created account repairs itself.
          final loadedProfile = await _repository.ensureProfile(user);
          if (!_isCurrentAuthEvent(user.uid, generation)) return;
          profile = loadedProfile;
          status = AuthStatus.authenticated;
          _profileSubscription = _repository
              .watchProfile(user.uid)
              .listen(
                (updated) {
                  if (!_isCurrentAuthEvent(user.uid, generation)) return;
                  profile = updated;
                  _safeNotify();
                },
                onError: (_) {
                  // Keep the last known profile during a temporary read failure.
                },
              );
        } on AppFailure {
          if (!_isCurrentAuthEvent(user.uid, generation)) return;
          // Still unreachable (offline, rules): screens degrade gracefully
          // with a fallback name rather than blocking sign-in.
          status = AuthStatus.authenticated;
        }
      }
      _safeNotify();
    });
  }

  bool _isCurrentAuthEvent(String uid, int generation) =>
      !_disposed &&
      _authGeneration == generation &&
      _repository.currentUser?.uid == uid;

  @override
  void dispose() {
    // Without this the subscription outlives the controller and keeps firing.
    _disposed = true;
    _authSubscription?.cancel();
    _profileSubscription?.cancel();
    _authSubscription = null;
    super.dispose();
  }

  /// The only sign-in on the real project. The profile is created from the
  /// Google account by the auth listener's `ensureProfile` path.
  Future<void> signInWithGoogle() async {
    await _repository.signInWithGoogle();
    // authStateChanges drives state transitions.
  }

  /// Seeded demo accounts only; hidden from production builds.
  Future<void> signInWithPassword(String email, String password) async {
    await _repository.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() => _repository.signOut();

  Future<void> refreshProfile() async {
    final id = uid;
    if (id == null) return;
    final refreshed = await _repository.loadProfile(id);
    if (_disposed || uid != id) return;
    profile = refreshed;
    _safeNotify();
  }

  Future<void> updateProfile({
    required String displayName,
    required String bio,
    required List<String> skills,
    String? collegeId,
    String? program,
    DateTime? birthDate,
  }) async {
    final current = profile;
    final id = uid;
    if (current == null || id == null) return;
    final updated = UserProfile(
      uid: id,
      displayName: displayName.trim(),
      bio: bio.trim(),
      skills: skills,
      createdAt: current.createdAt,
      photoUrl: current.photoUrl,
      collegeId: collegeId ?? current.collegeId,
      program: program ?? current.program,
      // Set once: an existing date always wins over the argument.
      birthDate: current.birthDate ?? birthDate,
      proUntil: current.proUntil,
      identityVerified: current.identityVerified,
      paymentTermsAcceptedAt: current.paymentTermsAcceptedAt,
      email: current.email,
      studentId: current.studentId,
      suspended: current.suspended,
    );
    await _repository.updateProfile(updated);
    profile = updated;
    _safeNotify();
  }

  Future<void> completeOnboarding({
    required String collegeId,
    required String program,
    required DateTime birthDate,
  }) async {
    final id = uid;
    if (id == null) return;
    await _repository.completeOnboarding(
      uid: id,
      collegeId: collegeId,
      program: program,
      birthDate: profile?.birthDate ?? birthDate,
    );
    await refreshProfile();
  }

  /// Marks the payment terms accepted and refreshes the cached profile.
  Future<void> acceptPaymentTerms() async {
    final id = uid;
    if (id == null) return;
    await _repository.acceptPaymentTerms(id);
    await refreshProfile();
  }
}
