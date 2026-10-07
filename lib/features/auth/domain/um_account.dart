/// The one identity the platform accepts: a University of Mindanao Google
/// account. Signing in with it is what proves someone is a UM student, so it
/// replaces the old email-and-password registration and doubles as identity
/// verification.
///
/// The same domain and student-address pattern are enforced in
/// `firestore.rules` (`isSignedIn`, `isStudentEmail`) and in the backend's
/// token check (`functions/server.js`). A client that skips this class still
/// cannot read or write anything.
abstract final class UmAccount {
  static const domain = 'umindanao.edu.ph';

  /// Student addresses look like `a.nerosa.545679@umindanao.edu.ph`: first
  /// initial, surname, six-digit student number. Faculty and office
  /// addresses on the same domain do not match and are treated as UM
  /// accounts without a student number.
  static final RegExp _student = RegExp(
    r'^[a-z]+\.[a-z]+\.(\d{6})@umindanao\.edu\.ph$',
  );

  static bool isUmEmail(String? email) {
    if (email == null) return false;
    return email.toLowerCase().endsWith('@$domain');
  }

  static bool isStudentEmail(String? email) =>
      email != null && _student.hasMatch(email.toLowerCase());

  /// The six-digit student number, or null for a non-student UM address.
  static String? studentIdOf(String? email) {
    if (email == null) return null;
    return _student.firstMatch(email.toLowerCase())?.group(1);
  }
}
