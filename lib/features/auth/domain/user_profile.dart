import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/academics.dart';

/// Public profile of a user. Every user can act as both client and
/// freelancer; there is no mutually exclusive role field by design.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.displayName,
    required this.bio,
    required this.skills,
    required this.createdAt,
    this.photoUrl,
    this.collegeId,
    this.program,
    this.proUntil,
    this.identityVerified = false,
    this.birthDate,
    this.paymentTermsAcceptedAt,
    this.email,
    this.studentId,
    this.suspended = false,
    this.onboardingComplete = true,
    this.publicRole,
  });

  final String uid;
  final String displayName;
  final String bio;
  final List<String> skills;
  final String? photoUrl;
  final DateTime createdAt;

  /// Which college the student belongs to, as an id from [kColleges].
  ///
  /// Nullable because accounts created before this field existed have neither,
  /// and a profile is still perfectly usable without one.
  final String? collegeId;

  /// Degree programme, e.g. "BS Computer Science".
  final String? program;

  /// End of the current paid Pro month. Written only by the backend after a
  /// gateway-confirmed payment; a client write that touches it is rejected.
  final DateTime? proUntil;

  /// Staff confirmed this student's ID and school email. Also server-owned.
  /// A permanent fact about the person, separate from whether they pay.
  final bool identityVerified;

  /// The UM Google address the account signed in with. Written at profile
  /// creation from the auth token and pinned by rules.
  final String? email;

  /// Six-digit student number parsed from a student-format address
  /// (`a.nerosa.545679@umindanao.edu.ph`); null for faculty/office accounts.
  final String? studentId;

  /// Set by staff (`users.manage`). A suspended account can sign in and
  /// read, but rules refuse every write that creates or moves anything.
  final bool suspended;

  final bool onboardingComplete;
  final String? publicRole;

  /// Set once at sign-up (or added later by accounts that predate it) and
  /// never editable afterwards. Gates selling and payouts, not buying.
  final DateTime? birthDate;

  /// When the student accepted the payment terms (money held by the platform,
  /// released on acceptance, refunded on cancellation). Asked once, before
  /// the first checkout.
  final DateTime? paymentTermsAcceptedAt;

  /// Eighteen or over, by date. No birth date means not an adult: the gate
  /// must be opted into, never defaulted through.
  bool get isAdult {
    final born = birthDate;
    if (born == null) return false;
    final now = DateTime.now();
    return !born.isAfter(DateTime(now.year - 18, now.month, now.day));
  }

  bool get hasAcceptedPaymentTerms => paymentTermsAcceptedAt != null;

  bool get isPro => proUntil != null && proUntil!.isAfter(DateTime.now());

  /// The check mark. It certifies identity, and it is shown only while the
  /// subscription that pays for the check is active — never sold outright.
  bool get hasVerifiedBadge => identityVerified && isPro;

  College? get college => collegeById(collegeId);

  /// "BS Computer Science · CCE", or empty when neither is set.
  String get academics =>
      academicSummary(collegeId: collegeId, program: program);

  factory UserProfile.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return UserProfile(
      uid: doc.id,
      displayName: data['displayName'] as String? ?? 'Unnamed student',
      bio: data['bio'] as String? ?? '',
      skills: List<String>.from(data['skills'] as List<dynamic>? ?? const []),
      photoUrl: data['photoUrl'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      collegeId: data['collegeId'] as String?,
      program: data['program'] as String?,
      proUntil: (data['proUntil'] as Timestamp?)?.toDate(),
      identityVerified: data['identityVerified'] as bool? ?? false,
      birthDate: (data['birthDate'] as Timestamp?)?.toDate(),
      paymentTermsAcceptedAt: (data['paymentTermsAcceptedAt'] as Timestamp?)
          ?.toDate(),
      email: data['email'] as String?,
      studentId: data['studentId'] as String?,
      suspended: data['suspended'] as bool? ?? false,
      onboardingComplete: data['onboardingComplete'] as bool? ?? true,
      publicRole: data['publicRole'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
    'uid': uid,
    'displayName': displayName,
    'bio': bio,
    'skills': skills,
    if (photoUrl != null) 'photoUrl': photoUrl,
    if (collegeId != null) 'collegeId': collegeId,
    if (program != null) 'program': program,
    if (birthDate != null) 'birthDate': Timestamp.fromDate(birthDate!),
    if (email != null) 'email': email,
    if (studentId != null) 'studentId': studentId,
    // Only ever true here for a student-format UM address; rules check the
    // claim against the auth token, so a client cannot assert it.
    if (identityVerified) 'identityVerified': true,
    'createdAt': FieldValue.serverTimestamp(),
    if (!onboardingComplete) 'onboardingComplete': false,
  };

  Map<String, dynamic> toUpdate() => {
    'displayName': displayName,
    'bio': bio,
    'skills': skills,
    if (collegeId != null) 'collegeId': collegeId,
    if (program != null) 'program': program,
    // Only ever adds one; rules refuse a change to an existing date.
    if (birthDate != null) 'birthDate': Timestamp.fromDate(birthDate!),
    'updatedAt': FieldValue.serverTimestamp(),
    if (onboardingComplete) 'onboardingComplete': true,
  };
}
