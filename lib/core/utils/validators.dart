/// Client-side input validators shared by auth forms.
///
/// These mirror what Firebase Auth enforces server-side; they exist so the
/// user gets precise feedback before a network round-trip.
abstract final class AppValidators {
  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static String? email(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) return 'Enter your email';
    if (!_email.hasMatch(email)) return 'Enter a valid email address';
    return null;
  }

  static String? password(String? value) {
    final password = value ?? '';
    if (password.length < 8) return 'Minimum 8 characters';
    return null;
  }

  static String? strongPassword(String? value) {
    final password = value ?? '';
    final hasLetter = password.contains(RegExp(r'[A-Za-z]'));
    final hasDigit = password.contains(RegExp(r'\d'));
    if (password.length >= 8 && hasLetter && hasDigit) return null;
    return 'At least 8 characters with letters and numbers';
  }

  static String? requiredText(String? value, {String message = 'Required'}) {
    return value != null && value.trim().isNotEmpty ? null : message;
  }
}
