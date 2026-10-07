import 'package:firebase_auth/firebase_auth.dart';

/// Maps infrastructure exceptions into typed application failures so
/// Firebase-specific errors never leak through the layers or reach users raw.
sealed class AppFailure implements Exception {
  const AppFailure(this.message);

  final String message;

  @override
  String toString() => message;

  static AppFailure from(Object error) {
    if (error is AppFailure) return error;
    if (error is FirebaseAuthException) return _fromAuthCode(error.code);
    if (error is FirebaseException) {
      return switch (error.code) {
        'permission-denied' => const PermissionFailure(),
        'not-found' || 'aborted' => const NotFoundFailure(),
        'unavailable' ||
        'deadline-exceeded' ||
        'cancelled' ||
        'network-request-failed' => const NetworkFailure(),
        _ => UnknownFailure(error.code),
      };
    }
    return const UnknownFailure(null);
  }

  static AppFailure _fromAuthCode(String code) => switch (code) {
    'invalid-email' ||
    'wrong-password' ||
    'user-not-found' ||
    'invalid-credential' => const InvalidCredentialsFailure(),
    'email-already-in-use' => const EmailInUseFailure(),
    'weak-password' => const WeakPasswordFailure(),
    'too-many-requests' => const TooManyAttemptsFailure(),
    'network-request-failed' => const NetworkFailure(),
    'popup-closed-by-user' ||
    'web-context-canceled' ||
    'user-cancelled' => const SignInCancelledFailure(),
    _ => UnknownFailure(code),
  };
}

final class NetworkFailure extends AppFailure {
  const NetworkFailure()
    : super('Network problem. Check your connection and try again.');
}

final class PermissionFailure extends AppFailure {
  const PermissionFailure() : super('You are not allowed to do that.');
}

final class NotFoundFailure extends AppFailure {
  const NotFoundFailure() : super('This item no longer exists.');
}

final class InvalidInputFailure extends AppFailure {
  const InvalidInputFailure(super.message);
}

final class InvalidCredentialsFailure extends AppFailure {
  const InvalidCredentialsFailure() : super('Incorrect email or password.');
}

final class EmailInUseFailure extends AppFailure {
  const EmailInUseFailure()
    : super('An account already exists for this email.');
}

final class WeakPasswordFailure extends AppFailure {
  const WeakPasswordFailure()
    : super('Password must be at least 8 characters with letters and numbers.');
}

final class TooManyAttemptsFailure extends AppFailure {
  const TooManyAttemptsFailure() : super('Too many attempts. Try again later.');
}

/// The payments backend or the gateway behind it refused or misbehaved.
///
/// Deliberately vague to the user: gateway diagnostics can disclose account
/// details, so the specifics stay in the backend's logs.
final class PaymentGatewayFailure extends AppFailure {
  const PaymentGatewayFailure()
    : super('Payment could not be started. Please try again.');
}

/// Google sign-in completed with an account outside the university domain.
final class NotUmAccountFailure extends AppFailure {
  const NotUmAccountFailure()
    : super(
        'Only University of Mindanao accounts (@umindanao.edu.ph) can use '
        'this app. Sign in with your UM Google account.',
      );
}

/// The user dismissed the Google account picker or popup before choosing.
final class SignInCancelledFailure extends AppFailure {
  const SignInCancelledFailure() : super('Sign-in was cancelled.');
}

/// The platform has no Google sign-in flow here (Windows/Linux desktop).
final class UnsupportedSignInFailure extends AppFailure {
  const UnsupportedSignInFailure()
    : super(
        'Google sign-in is not available on this platform. Use the Android, '
        'web, or macOS app.',
      );
}

/// A feature that needs the trusted backend was used in a build without one.
///
/// The app runs without a server (manual settlement), but payouts, Pro, and
/// gateway checkout cannot: they are decided server-side or not at all.
final class BackendUnavailableFailure extends AppFailure {
  const BackendUnavailableFailure()
    : super(
        'This needs the payments backend, which this build was not pointed at.',
      );
}

/// Work cannot begin because the order has not been paid for.
final class PaymentRequiredFailure extends AppFailure {
  const PaymentRequiredFailure()
    : super('This order has not been paid for yet.');
}

final class UnknownFailure extends AppFailure {
  const UnknownFailure(String? debugCode)
    : super('Something went wrong. Please try again.');

  @override
  String toString() => 'UnknownFailure($message)';
}
