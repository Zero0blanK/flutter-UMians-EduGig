import 'package:cloud_firestore/cloud_firestore.dart';

enum ServiceStatus { draft, published, paused, archived }

/// Whether the listed price is the price, or a starting point.
enum PricingMode {
  /// The starting price is what an order costs. Direct ordering is allowed
  /// unless the seller also asks to be contacted first.
  fixed,

  /// The starting price is a floor for the smallest job; the real price is
  /// agreed in chat and arrives as an offer card. Direct ordering is never
  /// allowed.
  negotiable;

  static PricingMode fromName(String? name) => PricingMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => PricingMode.fixed,
  );

  String get label => switch (this) {
    PricingMode.fixed => 'Fixed price',
    PricingMode.negotiable => 'Starting price, negotiable',
  };
}

ServiceStatus serviceStatusFromName(String? name) => ServiceStatus.values
    .firstWhere((s) => s.name == name, orElse: () => ServiceStatus.draft);

/// A freelance service offered by a student.
class FreelanceService {
  const FreelanceService({
    required this.id,
    required this.sellerId,
    required this.title,
    required this.description,
    required this.categoryId,
    required this.skills,
    required this.startingPrice,
    required this.currency,
    required this.deliveryDays,
    required this.revisionCount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.ratingSum = 0,
    this.ratingCount = 0,
    this.keywords = const [],
    this.featuredUntil,
    this.pricingMode = PricingMode.fixed,
    this.requiresContact = false,
  });

  final String id;
  final String sellerId;
  final String title;
  final String description;
  final String categoryId;
  final List<String> skills;
  final int startingPrice; // whole currency units (centavos avoided for MVP)
  final String currency;
  final int deliveryDays;
  final int revisionCount;
  final ServiceStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Denormalised rating totals.
  ///
  /// Kept on the service so a marketplace page costs no extra reads. They are
  /// only ever moved by the reviewer, in the same atomic write that creates
  /// the review, and security rules bind the increment to that review's actual
  /// rating — a seller cannot touch their own score.
  final int ratingSum;
  final int ratingCount;

  /// Lowercased tokens from the title and skills, for word-level search.
  ///
  /// `titleLower` only supports prefix matching, so "poster" could not find
  /// "Event poster for your student org".
  final List<String> keywords;

  /// Pinned above organic results until this instant. Set only by the
  /// backend for a paying Pro seller, and it lapses with the subscription;
  /// the seller's own edits carry it through unchanged (rules check that).
  final DateTime? featuredUntil;

  bool get isFeatured =>
      featuredUntil != null && featuredUntil!.isAfter(DateTime.now());

  final PricingMode pricingMode;

  /// The seller wants to discuss the job before any order, even at a fixed
  /// price. The client's only path is chat, then an offer card.
  final bool requiresContact;

  /// Whether a client may place an order at the listed price without an
  /// offer. Rules enforce the same condition on order creation, and the
  /// backend re-checks it before charging.
  bool get canOrderDirectly =>
      pricingMode == PricingMode.fixed && !requiresContact;

  /// "₱500" or "from ₱500", depending on what the number means.
  String get priceQualifier =>
      pricingMode == PricingMode.negotiable ? 'from' : '';

  bool get isPublished => status == ServiceStatus.published;

  bool get hasRating => ratingCount > 0;

  double get averageRating => ratingCount == 0 ? 0 : ratingSum / ratingCount;

  /// Builds the search tokens for [title] and [skills].
  ///
  /// Derived rather than authored so the index cannot drift from the text it
  /// describes, for the same reason `titleLower` is now checked in rules.
  static List<String> keywordsFor(String title, List<String> skills) {
    final tokens = <String>{};
    for (final source in [title, ...skills]) {
      for (final word in source.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
        // One-character tokens match almost everything and cost index space.
        if (word.length >= 2) tokens.add(word);
      }
    }
    return tokens.take(40).toList();
  }

  factory FreelanceService.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return FreelanceService.fromMap(doc.id, doc.data()!);
  }

  factory FreelanceService.fromMap(String id, Map<String, dynamic> data) {
    return FreelanceService(
      id: id,
      sellerId: data['sellerId'] as String,
      title: data['title'] as String? ?? '',
      description: data['description'] as String? ?? '',
      categoryId: data['categoryId'] as String? ?? 'other',
      skills: List<String>.from(data['skills'] as List<dynamic>? ?? const []),
      startingPrice: (data['startingPrice'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'PHP',
      deliveryDays: (data['deliveryDays'] as num?)?.toInt() ?? 1,
      revisionCount: (data['revisionCount'] as num?)?.toInt() ?? 0,
      status: serviceStatusFromName(data['status'] as String?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      ratingSum: (data['ratingSum'] as num?)?.toInt() ?? 0,
      ratingCount: (data['ratingCount'] as num?)?.toInt() ?? 0,
      keywords: List<String>.from(
        data['keywords'] as List<dynamic>? ?? const [],
      ),
      featuredUntil: (data['featuredUntil'] as Timestamp?)?.toDate(),
      pricingMode: PricingMode.fromName(data['pricingMode'] as String?),
      requiresContact: data['requiresContact'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestore({required bool isNew}) {
    final timestamp = isNew
        ? FieldValue.serverTimestamp()
        : Timestamp.fromDate(createdAt);
    return {
      'sellerId': sellerId,
      'title': title,
      'titleLower': title.toLowerCase(),
      'description': description,
      'categoryId': categoryId,
      'skills': skills,
      'keywords': keywordsFor(title, skills),
      'startingPrice': startingPrice,
      'currency': currency,
      'deliveryDays': deliveryDays,
      'revisionCount': revisionCount,
      'status': status.name,
      'pricingMode': pricingMode.name,
      'requiresContact': requiresContact,
      // Carried through unchanged on edit: rules reject a seller moving their
      // own score, so these must round-trip exactly as they were read.
      'ratingSum': ratingSum,
      'ratingCount': ratingCount,
      // Server-owned, and the save is a full overwrite: dropping it here
      // would un-feature a listing every time its seller fixed a typo.
      'featuredUntil': featuredUntil == null
          ? null
          : Timestamp.fromDate(featuredUntil!),
      'createdAt': timestamp,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
