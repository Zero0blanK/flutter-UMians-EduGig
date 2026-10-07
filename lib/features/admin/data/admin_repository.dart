import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/backend/backend_client.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../auth/domain/user_profile.dart';
import '../../orders/domain/order.dart';
import '../domain/admin_access.dart';
import '../domain/dispute_chat_page.dart';
import '../../payments/domain/payment.dart';
import '../../pro/domain/pro_policy.dart';
import '../../services/domain/freelance_service.dart';
import '../../wallet/domain/wallet.dart';
import '../domain/platform_metrics.dart';

/// What the platform is holding for whom. Every peso here belongs to
/// someone else; the balance sheet is what staff reconcile against the
/// gateway's settlement report before making a payout run.
class MoneyHeld {
  const MoneyHeld({
    required this.heldOrders,
    required this.heldGross,
    required this.heldNet,
    required this.walletAvailable,
    required this.walletClearing,
    required this.walletPending,
    required this.stuckRefunds,
    required this.stuckRefundAmount,
  });

  /// Paid, not yet released or refunded: owed to a freelancer or a client.
  final int heldOrders;
  final int heldGross;
  final int heldNet;

  /// Released and not yet transferred out, in its three states.
  final int walletAvailable;
  final int walletClearing;
  final int walletPending;

  /// Refunds a human has to make.
  final int stuckRefunds;
  final int stuckRefundAmount;

  /// Everything the platform must be able to pay out right now.
  int get liabilities =>
      heldGross + walletAvailable + walletClearing + walletPending;
}

/// Reads platform-wide figures and performs the two moderation actions staff
/// are trusted with.
///
/// Every query here is refused for a normal account: the collection-wide reads
/// depend on `admins/{uid}` existing, and that document can only be written
/// with a service-account key. Nothing in this class grants access — it just
/// asks, and the rules decide.
class AdminRepository {
  AdminRepository(this._firestore, this._backend);

  final FirebaseFirestore _firestore;
  final BackendClient _backend;
  final Map<String, Future<AuditSubject>> _auditSubjects = {};

  /// Payout settlement and verification decisions move money or grant a
  /// badge, so they go through the backend rather than a rules-checked write.
  bool get backendAvailable => _backend.isConfigured;

  Future<DisputeChatPage> fetchDisputeChat(
    String orderId, {
    String? afterId,
  }) async {
    final response = await _backend.post(
      '/admin/orders/$orderId/chat-snapshot',
      body: {'afterId': ?afterId},
    );
    return DisputeChatPage.fromJson(response);
  }

  /// Whether [uid] is staff. Drives whether the entry point is shown at all.
  Future<bool> isAdmin(String uid) async => (await access(uid)) != null;

  /// The caller's role and permissions, or null for a student. Decides
  /// which console tabs are built; the rules decide what they may do.
  Future<AdminAccess?> access(String uid) async {
    try {
      final doc = await _firestore.doc('${FirestorePaths.admins}/$uid').get();
      return doc.exists ? AdminAccess.fromFirestore(doc) : null;
    } on FirebaseException {
      // A denied read is the same answer as "no" from the UI's point of view.
      return null;
    }
  }

  /// Live version of [access], so role or permission changes immediately
  /// remove sections from an open staff console.
  Stream<AdminAccess?> watchAccess(String uid) => _firestore
      .doc('${FirestorePaths.admins}/$uid')
      .snapshots()
      .map((doc) => doc.exists ? AdminAccess.fromFirestore(doc) : null);

  // --- staff (main admin only) ---------------------------------------------

  Stream<List<AdminAccess>> watchStaff() {
    return _firestore
        .collection(FirestorePaths.admins)
        .snapshots()
        .map((s) => s.docs.map(AdminAccess.fromFirestore).toList());
  }

  /// Searches signed-in accounts by UM email prefix for the staff picker.
  Future<List<UserProfile>> searchUsersByEmailPrefix(String prefix) async {
    final normalized = prefix.trim().toLowerCase();
    if (normalized.length < 3) return const [];
    try {
      final snapshot = await _firestore
          .collection(FirestorePaths.users)
          .orderBy('email')
          .startAt([normalized])
          .endAt(['$normalized\uf8ff'])
          .get();
      return snapshot.docs.map(UserProfile.fromFirestore).toList();
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Grants or re-scopes a staff member. Rules refuse a main-admin role, the
  /// caller's own document, and any permission outside the known list.
  Future<void> setStaff({
    required String uid,
    required String actorId,
    required Set<AdminPermission> permissions,
    DateTime? createdAt,
    String? displayName,
    String? email,
    bool isNew = true,
  }) async {
    try {
      // Replace the document with the rule-approved shape. Merging a legacy
      // record can leave old keys behind, and validStaff() rejects unknown
      // fields on every update.
      await _firestore.doc('${FirestorePaths.admins}/$uid').set({
        'role': AdminRole.staff.name,
        'permissions': [for (final p in permissions) p.wireName],
        'displayName': ?displayName,
        'email': ?email,
        'createdBy': actorId,
        'createdAt': createdAt == null
            ? FieldValue.serverTimestamp()
            : Timestamp.fromDate(createdAt),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _log(
        actorId: actorId,
        action: isNew ? 'staff.granted' : 'staff.updated',
        targetType: 'staff',
        targetId: uid,
        note: [for (final p in permissions) p.wireName].join(', '),
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> revokeStaff({
    required String uid,
    required String actorId,
  }) async {
    try {
      await _firestore.doc('${FirestorePaths.admins}/$uid').delete();
      await _log(
        actorId: actorId,
        action: 'staff.revoked',
        targetType: 'staff',
        targetId: uid,
        note: '',
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  // --- students (users.manage) ---------------------------------------------

  /// Newest accounts first, or a case-insensitive partial-name search.
  /// Returns at most the configured limit of results. Legacy user records have no normalized name
  /// field, so searches inspect the directory before applying that limit.
  Stream<List<UserProfile>> watchUsers({String query = '', int limit = 50}) {
    final users = _firestore.collection(FirestorePaths.users);
    final trimmed = query.trim().toLowerCase();
    final q = trimmed.isEmpty
        ? users.orderBy('createdAt', descending: true).limit(limit)
        : users.orderBy('displayName');
    return q.snapshots().map(
      (s) => s.docs
          .map(UserProfile.fromFirestore)
          .where(
            (user) =>
                trimmed.isEmpty ||
                user.displayName.toLowerCase().contains(trimmed),
          )
          .take(limit)
          .toList(),
    );
  }

  /// Suspends or reinstates an account. A suspended student can sign in and
  /// read, but rules refuse every write that creates or moves anything.
  Future<void> setSuspended({
    required String uid,
    required String actorId,
    required bool suspended,
    required String note,
  }) async {
    final trimmed = note.trim();
    if (trimmed.length < 10) {
      throw const InvalidInputFailure(
        'Explain why in at least ten characters.',
      );
    }
    try {
      await _firestore.doc(FirestorePaths.user(uid)).update({
        'suspended': suspended,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _log(
        actorId: actorId,
        action: suspended ? 'user.suspended' : 'user.reinstated',
        targetType: 'user',
        targetId: uid,
        note: trimmed,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  // --- orders and transactions (orders.manage) ------------------------------

  Stream<List<WorkOrder>> watchOrders({OrderStatus? status, int limit = 50}) {
    Query<Map<String, dynamic>> q = _firestore.collection(
      FirestorePaths.orders,
    );
    if (status != null) q = q.where('status', isEqualTo: status.name);
    return q
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(WorkOrder.fromFirestore).toList());
  }

  Stream<List<Payment>> watchPayments({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.payments)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(Payment.fromFirestore).toList());
  }

  /// Settled sales in the selected reporting range. [paidAt], rather than a
  /// checkout's creation time, is the point at which money became a sale.
  Stream<List<Payment>> watchSales({DateTime? from, DateTime? until}) {
    Query<Map<String, dynamic>> query = _firestore
        .collection(FirestorePaths.payments)
        .where('status', isEqualTo: PaymentStatus.paid.name);
    if (from != null) {
      query = query.where(
        'paidAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(from),
      );
    }
    if (until != null) {
      query = query.where('paidAt', isLessThan: Timestamp.fromDate(until));
    }
    return query
        .orderBy('paidAt', descending: true)
        .snapshots()
        .map((s) => s.docs.map(Payment.fromFirestore).toList());
  }

  // --- audit (reports.view) ------------------------------------------------

  Stream<List<AuditEntry>> watchAuditLog({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.auditLog)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AuditEntry.fromFirestore).toList());
  }

  /// Resolves audit document ids into the names staff recognize. The audit
  /// entry itself remains immutable and keeps ids as its stable evidence;
  /// this cache prevents a long log from repeatedly reading the same target.
  Future<AuditSubject> auditSubject(AuditEntry entry) {
    final type = entry.targetType;
    final id = entry.targetId;
    if (type == null || type.isEmpty || id == null || id.isEmpty) {
      return Future.value(const AuditSubject(label: 'Platform event'));
    }
    return auditSubjectFor(type, id);
  }

  /// Resolves an audit reference stored inside an entry's detail map.
  Future<AuditSubject> auditSubjectFor(String type, String id) {
    final key = '$type/$id';
    return _auditSubjects.putIfAbsent(key, () => _loadAuditSubject(type, id));
  }

  Future<AuditSubject> _loadAuditSubject(String type, String id) async {
    try {
      switch (type) {
        case 'user':
        case 'verification':
          return AuditSubject(label: await _userName(id), kind: 'Student');
        case 'service':
          return AuditSubject(
            label: await _documentLabel(
              FirestorePaths.services,
              id,
              'title',
              'Listing',
            ),
            kind: 'Listing',
          );
        case 'order':
          return AuditSubject(
            label: await _documentLabel(
              FirestorePaths.orders,
              id,
              'serviceTitle',
              'Order',
            ),
            kind: 'Order',
          );
        case 'payment':
          return AuditSubject(
            label: await _documentLabel(
              FirestorePaths.orders,
              id,
              'serviceTitle',
              'Payment',
            ),
            kind: 'Payment',
          );
        case 'offer':
          return AuditSubject(
            label: await _documentLabel(
              FirestorePaths.offers,
              id,
              'serviceTitle',
              'Offer',
            ),
            kind: 'Offer',
          );
        case 'payout':
          final payout = await _firestore
              .doc('${FirestorePaths.payouts}/$id')
              .get();
          final uid = payout.data()?['uid'] as String?;
          return AuditSubject(
            label: uid == null
                ? 'Payout request'
                : 'Payout for ${await _userName(uid)}',
            kind: 'Payout',
          );
        case 'wallet':
          return AuditSubject(
            label: await _userName(id),
            kind: 'Student wallet',
          );
        case 'category':
          return AuditSubject(
            label: await _documentLabel(
              FirestorePaths.categories,
              id,
              'label',
              'Category',
            ),
            kind: 'Category',
          );
        case 'settings':
          return const AuditSubject(
            label: 'Platform settings',
            kind: 'Settings',
          );
        case 'staff':
          return const AuditSubject(label: 'Staff member', kind: 'Staff');
        default:
          return AuditSubject(
            label: '${type[0].toUpperCase()}${type.substring(1)} event',
          );
      }
    } on FirebaseException {
      return AuditSubject(
        label: '${type[0].toUpperCase()}${type.substring(1)} unavailable',
      );
    } catch (_) {
      return AuditSubject(
        label: '${type[0].toUpperCase()}${type.substring(1)} unavailable',
      );
    }
  }

  Future<String> _userName(String uid) async {
    final user = await _firestore.doc(FirestorePaths.user(uid)).get();
    return user.data()?['displayName'] as String? ?? 'Former student';
  }

  Future<String> _documentLabel(
    String collection,
    String id,
    String field,
    String fallback,
  ) async {
    final doc = await _firestore.doc('$collection/$id').get();
    return doc.data()?[field] as String? ?? '$fallback unavailable';
  }

  // --- categories and settings ---------------------------------------------

  Stream<List<Category>> watchAllCategories() {
    return _firestore
        .collection(FirestorePaths.categories)
        .orderBy('sortOrder')
        .snapshots()
        .map((s) => s.docs.map(Category.fromFirestore).toList());
  }

  Future<void> saveCategory({
    required String id,
    required String label,
    required bool active,
    required int sortOrder,
    required String actorId,
  }) async {
    final cleanId = id.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]{2,30}$').hasMatch(cleanId)) {
      throw const InvalidInputFailure(
        'Category id: 2-30 lowercase letters, digits, - or _.',
      );
    }
    if (label.trim().isEmpty || label.trim().length > 40) {
      throw const InvalidInputFailure('Label must be 1-40 characters.');
    }
    try {
      await _firestore.doc('${FirestorePaths.categories}/$cleanId').set({
        'label': label.trim(),
        'active': active,
        'sortOrder': sortOrder,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': actorId,
      });
      await _log(
        actorId: actorId,
        action: 'category.saved',
        targetType: 'category',
        targetId: cleanId,
        note: '${label.trim()} (${active ? 'active' : 'retired'})',
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveSettings({
    required PlatformSettings settings,
    required String actorId,
  }) async {
    if (settings.announcement.length > 300) {
      throw const InvalidInputFailure(
        'Announcements are limited to 300 characters.',
      );
    }
    try {
      await _firestore.doc(FirestorePaths.platformSettings).set({
        'announcement': settings.announcement.trim(),
        'ordersPaused': settings.ordersPaused,
        if (settings.announcementExpiresAt != null)
          'announcementExpiresAt': Timestamp.fromDate(
            settings.announcementExpiresAt!,
          ),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': actorId,
      });
      await _log(
        actorId: actorId,
        action: settings.ordersPaused
            ? 'settings.orders_paused'
            : 'settings.saved',
        targetType: 'settings',
        targetId: 'platform',
        note: settings.announcement.trim(),
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Headline numbers for the dashboard.
  ///
  /// Counts come from aggregate queries so the cost does not grow with the
  /// marketplace — asking "how many orders are disputed" should not mean
  /// downloading every disputed order.
  Future<PlatformMetrics> metrics() async {
    try {
      final services = _firestore.collection(FirestorePaths.services);
      final orders = _firestore.collection(FirestorePaths.orders);
      final payments = _firestore.collection(FirestorePaths.payments);

      final counts = await Future.wait([
        _count(_firestore.collection(FirestorePaths.users)),
        _count(services),
        _count(services.where('status', isEqualTo: 'published')),
        _count(orders),
        _count(_firestore.collection(FirestorePaths.reviews)),
      ]);

      final byStatus = <OrderStatus, int>{};
      await Future.wait([
        for (final status in OrderStatus.values)
          _count(orders.where('status', isEqualTo: status.name))
              .then((value) => byStatus[status] = value),
      ]);

      // Revenue is only real once a payment settles; pending money is not
      // income and must not be reported as though it were.
      final settled = await payments
          .where('status', isEqualTo: PaymentStatus.paid.name)
          .aggregate(count(), sum('amount'), sum('commission'))
          .get();

      final gross = (settled.getSum('amount') ?? 0).toInt();
      final commission = (settled.getSum('commission') ?? 0).toInt();

      return PlatformMetrics(
        users: counts[0],
        services: counts[1],
        publishedServices: counts[2],
        orders: counts[3],
        reviews: counts[4],
        ordersByStatus: byStatus,
        settledPayments: settled.count ?? 0,
        grossMerchandiseValue: gross,
        commissionEarned: commission,
        paidOutToFreelancers: gross - commission,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<int> _count(Query<Map<String, dynamic>> query) async {
    final snapshot = await query.count().get();
    return snapshot.count ?? 0;
  }

  /// Orders needing a human: disputes first, then whatever moved most recently.
  Stream<List<WorkOrder>> watchDisputes({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.orders)
        .where('status', isEqualTo: OrderStatus.disputed.name)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(WorkOrder.fromFirestore).toList());
  }

  Stream<List<WorkOrder>> watchRecentOrders({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.orders)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(WorkOrder.fromFirestore).toList());
  }

  Stream<List<FreelanceService>> watchRecentServices({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.services)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(FreelanceService.fromFirestore).toList());
  }

  /// All listings belonging to one student, including drafts and items that
  /// were already taken down. This keeps listing moderation in the staff
  /// profile where the seller and their work can be reviewed together.
  Stream<List<FreelanceService>> watchServicesForSeller(
    String sellerId, {
    int limit = 50,
  }) {
    return _firestore
        .collection(FirestorePaths.services)
        .where('sellerId', isEqualTo: sellerId)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(FreelanceService.fromFirestore).toList());
  }

  /// Closes a dispute. Rules permit this only from `disputed`, and only to
  /// these two outcomes.
  /// Records what [actorId] thinks the outcome should be, for a second
  /// staff member to confirm. Used above [DisputePolicy.secondOpinionFrom];
  /// the rules refuse it as a way to move the status.
  Future<void> proposeDisputeOutcome({
    required String orderId,
    required String actorId,
    required OrderStatus outcome,
    required String note,
  }) async {
    if (outcome != OrderStatus.completed && outcome != OrderStatus.cancelled) {
      throw const InvalidInputFailure(
        'A dispute can only be closed as completed or cancelled.',
      );
    }
    try {
      await _firestore.doc('${FirestorePaths.orders}/$orderId').update({
        'disputeResolution': {
          'outcome': outcome.name,
          'proposedBy': actorId,
          'proposedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _log(
        actorId: actorId,
        action: 'dispute.proposed_${outcome.name}',
        targetType: 'order',
        targetId: orderId,
        note: note,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> resolveDispute({
    required String orderId,
    required String actorId,
    required OrderStatus outcome,
    required String note,
  }) async {
    if (outcome != OrderStatus.completed && outcome != OrderStatus.cancelled) {
      throw const InvalidInputFailure(
        'A dispute can only be closed as completed or cancelled.',
      );
    }
    try {
      final ref = _firestore.doc('${FirestorePaths.orders}/$orderId');
      await _firestore.runTransaction((tx) async {
        final snapshot = await tx.get(ref);
        if (!snapshot.exists) throw const NotFoundFailure();
        final order = WorkOrder.fromFirestore(snapshot);
        if (!order.canResolveDispute(actorId, outcome)) {
          throw InvalidInputFailure(
            DisputePolicy.needsSecondOpinion(order.price)
                ? 'Disputes of ${DisputePolicy.secondOpinionFrom} pesos or '
                      'more need a proposal from one staff member and a '
                      'confirmation from another.'
                : 'This order is no longer disputed.',
          );
        }
        tx.update(ref, {
          'status': outcome.name,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
      await _log(
        actorId: actorId,
        action: 'dispute.${outcome.name}',
        targetType: 'order',
        targetId: orderId,
        note: note,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Removes a listing from the marketplace without altering its content.
  Future<void> takeDownService({
    required String serviceId,
    required String actorId,
    required String note,
    bool archive = false,
  }) async {
    try {
      await _firestore.doc('${FirestorePaths.services}/$serviceId').update({
        'status': archive ? 'archived' : 'paused',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _log(
        actorId: actorId,
        action: archive ? 'service.archived' : 'service.paused',
        targetType: 'service',
        targetId: serviceId,
        note: note,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Transfers not yet settled, oldest first: waiting for a human or for the
  /// gateway to accept them, and in flight with the gateway.
  Stream<List<Payout>> watchPayoutQueue({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.payouts)
        .where(
          'status',
          whereIn: [PayoutStatus.requested.name, PayoutStatus.processing.name],
        )
        .orderBy('requestedAt', descending: false)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(Payout.fromFirestore).toList());
  }

  /// Hands a waiting payout to Xendit (or tries again after an outage).
  Future<String> submitPayout(String payoutId) async {
    final body = await _backend.post('/admin/payouts/$payoutId/submit');
    return body['outcome'] as String? ?? 'unknown';
  }

  /// Records that the transfer was made. The backend moves the balance and
  /// writes the audit entry in one transaction.
  Future<void> settlePayout({
    required String payoutId,
    required String reference,
  }) async {
    final trimmed = reference.trim();
    if (trimmed.isEmpty || trimmed.length > 120) {
      throw const InvalidInputFailure('Enter the transfer reference.');
    }
    await _backend.post(
      '/admin/payouts/$payoutId/settle',
      body: {'reference': trimmed},
    );
  }

  Future<void> rejectPayout({
    required String payoutId,
    required String note,
  }) async {
    final trimmed = note.trim();
    if (trimmed.length < 10 || trimmed.length > 500) {
      throw const InvalidInputFailure(
        'Explain why in at least ten characters.',
      );
    }
    await _backend.post(
      '/admin/payouts/$payoutId/reject',
      body: {'note': trimmed},
    );
  }

  /// Payments whose refund the gateway refused, or that have no gateway id
  /// to refund against. Each one is money the platform owes a client.
  Stream<List<Payment>> watchRefundQueue({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.payments)
        .where('refundStatus', whereIn: ['failed', 'manual-required'])
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(Payment.fromFirestore).toList());
  }

  Future<void> retryRefund(String orderId) async {
    await _backend.post('/admin/payments/$orderId/refund');
  }

  Future<void> markRefundedManually({
    required String orderId,
    required String reference,
  }) async {
    final trimmed = reference.trim();
    if (trimmed.isEmpty || trimmed.length > 120) {
      throw const InvalidInputFailure('Enter the transfer reference.');
    }
    await _backend.post(
      '/admin/payments/$orderId/refund-manual',
      body: {'reference': trimmed},
    );
  }

  /// Passes a card chargeback on to the seller it was released to. The
  /// backend takes the seller's net from their balance and records the rest
  /// as owed; the platform absorbs its commission.
  Future<void> recordChargeback({
    required String orderId,
    required String reason,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.length < 10 || trimmed.length > 500) {
      throw const InvalidInputFailure(
        'Give the gateway case reference and why (10 to 500 characters).',
      );
    }
    await _backend.post(
      '/admin/payments/$orderId/chargeback',
      body: {'reason': trimmed},
    );
  }

  /// Where the platform's held money is, in one read set. The two sides
  /// must agree: what is held or released and not yet paid out has to equal
  /// what the wallets say they are holding. A gap is a bug or a theft.
  Future<MoneyHeld> moneyHeld() async {
    try {
      final payments = _firestore.collection(FirestorePaths.payments);
      final held = await payments
          .where('holdStatus', isEqualTo: HoldStatus.held.name)
          .aggregate(count(), sum('amount'), sum('netToFreelancer'))
          .get();
      final wallets = await _firestore
          .collection(FirestorePaths.wallets)
          .aggregate(sum('available'), sum('clearing'), sum('pendingPayout'))
          .get();
      final stuck = await payments
          .where('refundStatus', whereIn: ['failed', 'manual-required'])
          .aggregate(count(), sum('amount'))
          .get();
      return MoneyHeld(
        heldOrders: held.count ?? 0,
        heldGross: (held.getSum('amount') ?? 0).toInt(),
        heldNet: (held.getSum('netToFreelancer') ?? 0).toInt(),
        walletAvailable: (wallets.getSum('available') ?? 0).toInt(),
        walletClearing: (wallets.getSum('clearing') ?? 0).toInt(),
        walletPending: (wallets.getSum('pendingPayout') ?? 0).toInt(),
        stuckRefunds: stuck.count ?? 0,
        stuckRefundAmount: (stuck.getSum('amount') ?? 0).toInt(),
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Students waiting for an identity check, oldest first.
  Stream<List<VerificationRequest>> watchVerificationQueue({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.verificationRequests)
        .where('status', isEqualTo: VerificationStatus.pending.name)
        .orderBy('createdAt', descending: false)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(VerificationRequest.fromFirestore).toList());
  }

  Future<void> decideVerification({
    required String uid,
    required bool approve,
    required String note,
  }) async {
    await _backend.post(
      '/admin/verification/$uid',
      body: {'approve': approve, 'note': note.trim()},
    );
  }

  Stream<List<AdminAction>> watchActionLog({int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.adminActions)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(AdminAction.fromFirestore).toList());
  }

  /// Records what was done. A failure here must not undo the action itself,
  /// but it is surfaced in the log rather than swallowed silently.
  Future<void> _log({
    required String actorId,
    required String action,
    required String targetType,
    required String targetId,
    required String note,
  }) async {
    final trimmed = note.trim();
    await _firestore.collection(FirestorePaths.adminActions).add({
      'actorId': actorId,
      'action': action,
      'targetType': targetType,
      'targetId': targetId,
      if (trimmed.isNotEmpty)
        'note': trimmed.substring(0, min(trimmed.length, 500)),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  static int min(int a, int b) => a < b ? a : b;
}
