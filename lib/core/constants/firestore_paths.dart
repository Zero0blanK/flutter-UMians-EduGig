/// Single source of truth for Firestore collection names and document paths.
///
/// Never hardcode these strings elsewhere; security rules mirror this layout.
abstract final class FirestorePaths {
  static const users = 'users';
  static const services = 'services';
  static const orders = 'orders';
  static const conversations = 'conversations';
  static const reviews = 'reviews';
  static const payments = 'payments';
  static const admins = 'admins';
  static const adminActions = 'adminActions';
  static const wallets = 'wallets';
  static const ledger = 'ledger';
  static const payouts = 'payouts';
  static const subscriptions = 'subscriptions';
  static const verificationRequests = 'verificationRequests';
  static const offers = 'offers';
  static const auditLog = 'auditLog';
  static const categories = 'categories';
  static const settings = 'settings';
  static const platformSettings = 'settings/platform';

  static String user(String uid) => '$users/$uid';
  static String devices(String uid) => '$users/$uid/devices';
  static String notifications(String uid) => '$users/$uid/notifications';
  static String messages(String conversationId) =>
      '$conversations/$conversationId/messages';
  static String wallet(String uid) => '$wallets/$uid';
  static String verificationRequest(String uid) => '$verificationRequests/$uid';

  /// Deterministic two-party conversation id: sorted uids joined by '_'.
  ///
  /// Guarantees one conversation per pair regardless of who initiates,
  /// which makes duplicate contact requests idempotent.
  static String conversationIdFor(String uidA, String uidB) {
    final ids = [uidA, uidB]..sort();
    return '${ids[0]}_${ids[1]}';
  }
}

/// Fixed service categories. Kept client-side as a closed set because they
/// gate queries and validation on both client and rules; a mutable collection
/// would add reads without product value today.
const List<({String id, String label})> kServiceCategories = [
  (id: 'tutoring', label: 'Tutoring'),
  (id: 'design', label: 'Graphic Design'),
  (id: 'writing', label: 'Writing & Editing'),
  (id: 'programming', label: 'Programming'),
  (id: 'video', label: 'Video Editing'),
  (id: 'photography', label: 'Photography'),
  (id: 'music', label: 'Music & Audio'),
  (id: 'other', label: 'Other'),
];

String categoryLabelOf(String id) => kServiceCategories
    .firstWhere((c) => c.id == id, orElse: () => (id: id, label: 'Other'))
    .label;
