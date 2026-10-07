import 'package:cloud_firestore/cloud_firestore.dart';

/// What Pro costs and what it buys. Mirrors PRO_PRICE, PRO_PERIOD_DAYS and
/// FEATURED_PER_SELLER in `functions/policy.js`; the backend's copy is the
/// one that is charged and enforced.
///
/// Pro deliberately does **not** discount the commission. It buys two things:
/// a limited number of featured listings, and the verified badge for a
/// student whose identity staff have checked.
abstract final class ProPolicy {
  static const price = 99;
  static const periodDays = 30;

  /// Featured listings per seller. Capped so a subscriber cannot pin their
  /// whole catalogue and turn the marketplace into a paid wall.
  static const featuredPerSeller = 2;

  /// Featured slots shown above organic results on any one page. Without
  /// this a category with twenty subscribers would show twenty pinned cards
  /// and the feature would be worth nothing to anyone.
  static const featuredPerPage = 3;
}

enum VerificationStatus {
  pending,
  approved,
  rejected;

  static VerificationStatus fromName(String? name) =>
      VerificationStatus.values.firstWhere(
        (s) => s.name == name,
        orElse: () => VerificationStatus.pending,
      );

  String get label => switch (this) {
    VerificationStatus.pending => 'Under review',
    VerificationStatus.approved => 'Approved',
    VerificationStatus.rejected => 'Not approved',
  };
}

/// A student's request to have their identity checked, at
/// `verificationRequests/{uid}`. One per student; a rejection can be
/// re-submitted.
class VerificationRequest {
  const VerificationRequest({
    required this.uid,
    required this.schoolEmail,
    required this.idImagePath,
    required this.status,
    required this.createdAt,
    this.note,
    this.decidedAt,
  });

  final String uid;
  final String schoolEmail;

  /// Storage path (not a URL) under `verification/{uid}/`; only staff and
  /// the owner can download it.
  final String idImagePath;
  final VerificationStatus status;
  final DateTime createdAt;
  final String? note;
  final DateTime? decidedAt;

  factory VerificationRequest.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return VerificationRequest(
      uid: doc.id,
      schoolEmail: data['schoolEmail'] as String? ?? '',
      idImagePath: data['idImagePath'] as String? ?? '',
      status: VerificationStatus.fromName(data['status'] as String?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      note: data['note'] as String?,
      decidedAt: (data['decidedAt'] as Timestamp?)?.toDate(),
    );
  }
}
