import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/config/app_environment.dart';
import '../../../core/errors/app_failure.dart';
import '../domain/um_account.dart';
import '../domain/user_profile.dart';

class AuthRepository {
  AuthRepository(this._auth, this._firestore);

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  User? get currentUser => _auth.currentUser;

  bool get isEmailVerified => _auth.currentUser?.emailVerified ?? false;

  /// Completed once per process; `GoogleSignIn.initialize` must run exactly
  /// once, and only Android ever needs it.
  Future<void>? _googleSignInReady;

  /// Signs in with a University of Mindanao Google account.
  ///
  /// The hosted-domain filter asks Google to show only UM accounts, but it is
  /// a hint, not a guarantee: a modified client can drop it. The domain is
  /// therefore checked again here, in the rules (`isSignedIn`) and in the
  /// backend, and an account that slips through is deleted on the spot so it
  /// never lingers in Authentication.
  ///
  /// Web uses the Firebase popup. Android uses the native account picker
  /// (`google_sign_in`) and hands the ID token to Firebase: the alternative,
  /// `signInWithProvider`, bounces through the hosted sign-in helper in a
  /// Custom Tab, whose `sessionStorage` many Android browsers partition or
  /// drop, which surfaces as `auth/missing-initial-state`. Other platforms
  /// keep the provider flow.
  Future<User> signInWithGoogle() async {
    final UserCredential credential;
    try {
      if (kIsWeb) {
        credential = await _auth.signInWithPopup(_webProvider());
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        credential = await _signInWithGoogleNatively();
      } else {
        credential = await _auth.signInWithProvider(_webProvider());
      }
    } on UnimplementedError {
      // firebase_auth has no Google flow on Windows/Linux desktop.
      throw const UnsupportedSignInFailure();
    } on GoogleSignInException catch (e) {
      throw switch (e.code) {
        GoogleSignInExceptionCode.canceled ||
        GoogleSignInExceptionCode.interrupted => const SignInCancelledFailure(),
        _ => UnknownFailure(e.code.name),
      };
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
    final user = credential.user!;
    if (!UmAccount.isUmEmail(user.email) || !user.emailVerified) {
      try {
        await user.delete();
      } on FirebaseAuthException {
        await _auth.signOut();
      }
      throw const NotUmAccountFailure();
    }
    return user;
  }

  GoogleAuthProvider _webProvider() => GoogleAuthProvider()
    ..setCustomParameters({'hd': UmAccount.domain, 'prompt': 'select_account'})
    ..addScope('email')
    ..addScope('profile');

  Future<UserCredential> _signInWithGoogleNatively() async {
    final google = GoogleSignIn.instance;
    await (_googleSignInReady ??= google.initialize(
      hostedDomain: UmAccount.domain,
    ));
    final account = await google.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      // Credential Manager returned an account without a token, which only
      // happens when the Android OAuth client is misconfigured.
      throw const UnknownFailure('google-sign-in/no-id-token');
    }
    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  /// Email/password sign-in exists only for the seeded demo students
  /// (`tools/seed`), the project's only password users. The login-screen
  /// selector is hidden in production and this repository guard prevents a
  /// future caller from accidentally reintroducing it there.
  Future<User> signInWithPassword({
    required String email,
    required String password,
  }) async {
    if (!kAppEnvironment.demoLogin) throw const PermissionFailure();
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return credential.user!;
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    // Forget the picked Google account too, so the next sign-in shows the
    // account picker instead of silently reusing the last one.
    if (_googleSignInReady != null) {
      await GoogleSignIn.instance.signOut();
    }
  }

  /// Returns the signed-in user's profile, creating it from the Google
  /// account on first sign-in: the name and photo Google supplies, the email,
  /// and the student number parsed from a student-format address. A student
  /// address also marks the profile identity-verified, because the
  /// institutional sign-in is the check.
  Future<UserProfile> ensureProfile(User user) async {
    try {
      final profile = await loadProfile(user.uid);
      if (profile.photoUrl != null && profile.photoUrl!.isNotEmpty) {
        return profile;
      }
      final providerPhoto = user.providerData
          .map((provider) => provider.photoURL)
          .whereType<String>()
          .firstOrNull;
      final photo = _auth.currentUser?.photoURL ?? providerPhoto;
      if (photo == null || photo.isEmpty) return profile;
      await _firestore.doc(FirestorePaths.user(user.uid)).update({
        'photoUrl': photo,
      });
      return await loadProfile(user.uid);
    } on NotFoundFailure {
      try {
        await user.reload();
      } on FirebaseException {
        // Offline: fall back to whatever this instance already knows.
      }
      final refreshed = _auth.currentUser ?? user;
      final providerPhoto = refreshed.providerData
          .map((provider) => provider.photoURL)
          .whereType<String>()
          .firstOrNull;
      final name = (refreshed.displayName ?? '').trim();
      final email = refreshed.email;
      await _firestore
          .doc(FirestorePaths.user(refreshed.uid))
          .set(
            UserProfile(
              uid: refreshed.uid,
              displayName: name.isEmpty || name.length > 60 ? 'Student' : name,
              bio: '',
              skills: const [],
              createdAt: DateTime.now(),
              photoUrl: refreshed.photoURL ?? providerPhoto,
              email: email,
              studentId: UmAccount.studentIdOf(email),
              identityVerified: UmAccount.isStudentEmail(email),
              onboardingComplete: false,
            ).toFirestore(),
          );
      return loadProfile(refreshed.uid);
    }
  }

  Future<UserProfile> loadProfile(String uid) async {
    try {
      final doc = await _firestore.doc(FirestorePaths.user(uid)).get();
      if (!doc.exists) {
        throw const NotFoundFailure();
      }
      return UserProfile.fromFirestore(doc);
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Stream<UserProfile> watchProfile(String uid) =>
      _firestore.doc(FirestorePaths.user(uid)).snapshots().map((snapshot) {
        if (!snapshot.exists) throw const NotFoundFailure();
        return UserProfile.fromFirestore(snapshot);
      });

  Future<void> updateProfile(UserProfile profile) async {
    try {
      await _firestore
          .doc(FirestorePaths.user(profile.uid))
          .update(profile.toUpdate());
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> completeOnboarding({
    required String uid,
    required String collegeId,
    required String program,
    required DateTime birthDate,
  }) async {
    try {
      await _firestore.doc(FirestorePaths.user(uid)).update({
        'collegeId': collegeId,
        'program': program,
        'birthDate': Timestamp.fromDate(birthDate),
        'onboardingComplete': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Records that the student read and accepted how payment works. Asked
  /// once, before their first checkout; rules accept only a timestamp.
  Future<void> acceptPaymentTerms(String uid) async {
    try {
      await _firestore.doc(FirestorePaths.user(uid)).update({
        'paymentTermsAcceptedAt': FieldValue.serverTimestamp(),
      });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }
}
