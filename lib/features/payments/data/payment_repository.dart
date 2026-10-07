import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../notifications/data/notification_repository.dart';
import '../../notifications/domain/app_notification.dart';
import '../../orders/domain/order.dart';
import '../domain/commission.dart';
import '../domain/payment.dart';
import '../payment_config.dart';
import 'payment_gateway.dart';

/// Reads and writes payment records, and is the only place that does.
///
/// Payments live at `payments/{orderId}` — the document id *is* the order id,
/// mirroring the reviews collection. One order therefore cannot accumulate two
/// payment records, because there is only one address for them to live at.
class PaymentRepository {
  PaymentRepository(this._firestore, this._gateway, this._config);

  final FirebaseFirestore _firestore;
  final PaymentGateway _gateway;
  final PaymentConfig _config;

  static const maxReferenceLength = 120;

  PaymentConfig get config => _config;

  CommissionBreakdown breakdownFor(WorkOrder order) =>
      _config.commissionPolicy.breakdownOf(order.price);

  DocumentReference<Map<String, dynamic>> _ref(String orderId) =>
      _firestore.doc('${FirestorePaths.payments}/$orderId');

  /// Every payment this student was party to, newest first: what they paid
  /// and what they were paid, with where each one stands.
  Stream<List<Payment>> watchHistory(String uid, {int limit = 100}) {
    return _firestore
        .collection(FirestorePaths.payments)
        .where('participantIds', arrayContains: uid)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(Payment.fromFirestore).toList());
  }

  /// Checks a pending gateway payment against the gateway right now, so a
  /// buyer back from GCash sees "paid" without waiting for the callback.
  /// The backend applies the answer; this only returns the status it saw.
  Future<PaymentStatus?> syncPayment(String orderId) =>
      _gateway.syncWithGateway(orderId);

  /// The payment for [orderId], or null while the order is unpaid.
  Stream<Payment?> watchForOrder(String orderId) {
    return _ref(orderId).snapshots().map(
      (snapshot) => snapshot.exists ? Payment.fromFirestore(snapshot) : null,
    );
  }

  /// Starts payment for [order] and records a `pending` payment document.
  ///
  /// Only the client may pay. The amount is taken from the order document
  /// rather than from any caller-supplied figure, and the commission split is
  /// computed here so both parties see identical numbers.
  ///
  /// In gateway mode the returned [RedirectCheckout] sends the client to
  /// Xendit; the authoritative `paid` write arrives later from the backend's
  /// webhook handler. In manual mode the record waits for the freelancer to
  /// confirm receipt.
  Future<CheckoutIntent> beginPayment({
    required WorkOrder order,
    required String actorId,
    PaymentChannel channel = PaymentChannel.other,
    String? reference,
  }) async {
    if (actorId != order.clientId) throw const PermissionFailure();
    if (order.price < 1) {
      throw const InvalidInputFailure('This order has no amount to pay.');
    }

    final note = reference?.trim();
    if (note != null && note.length > maxReferenceLength) {
      throw const InvalidInputFailure(
        'Reference must be $maxReferenceLength characters or fewer.',
      );
    }

    final breakdown = breakdownFor(order);
    // Guards against a future change to the commission maths silently losing
    // or inventing money; the split must always reconstitute the gross.
    assert(breakdown.isBalanced, 'commission split must equal the gross');

    final intent = await _gateway.startCheckout(
      order: order,
      breakdown: breakdown,
      channel: channel,
    );

    // Gateway mode: the backend created this record with the Admin SDK while
    // it created the checkout session, and its webhook will settle it. Writing
    // it again from here races that webhook — if settlement lands first, the
    // client's update is refused for a payment that actually succeeded.
    if (intent is! ManualCheckout) return intent;

    try {
      await _firestore.runTransaction((transaction) async {
        final paymentRef = _ref(order.id);
        final existing = await transaction.get(paymentRef);
        if (existing.exists) {
          final current = Payment.fromFirestore(existing);
          // Re-paying a settled order would double-charge the client.
          if (current.isSettled) {
            throw const InvalidInputFailure(
              'This order has already been paid.',
            );
          }
          transaction.update(paymentRef, {
            'status': PaymentStatus.pending.name,
            if (note != null && note.isNotEmpty) 'reference': note,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return;
        }

        transaction.set(paymentRef, {
          'orderId': order.id,
          'clientId': order.clientId,
          'freelancerId': order.freelancerId,
          'participantIds': [order.clientId, order.freelancerId]..sort(),
          'amount': breakdown.gross,
          'currency': order.currency,
          'commission': breakdown.commission,
          'netToFreelancer': breakdown.netToFreelancer,
          'status': PaymentStatus.pending.name,
          'method': _gateway.method.name,
          // Never settable by a client; rules reject any write that raises it.
          'verified': false,
          if (note != null && note.isNotEmpty) 'reference': note,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }

    return intent;
  }

  /// Manual mode only: the **freelancer** confirms the money arrived.
  ///
  /// The payer cannot confirm their own payment — that is the entire value of
  /// the attestation, and security rules enforce it independently. In gateway
  /// mode this path is unnecessary: the webhook settles the record.
  Future<void> confirmManualReceipt({
    required String orderId,
    required String actorId,
  }) async {
    try {
      Payment? settled;
      await _firestore.runTransaction((transaction) async {
        final paymentRef = _ref(orderId);
        final snapshot = await transaction.get(paymentRef);
        if (!snapshot.exists) throw const NotFoundFailure();
        final payment = Payment.fromFirestore(snapshot);

        if (actorId != payment.freelancerId) throw const PermissionFailure();
        if (payment.method != PaymentMethod.manual) {
          throw const InvalidInputFailure(
            'Gateway payments are confirmed automatically.',
          );
        }
        if (payment.isSettled) return;
        if (payment.status != PaymentStatus.pending) {
          throw const InvalidInputFailure(
            'This payment is no longer awaiting confirmation.',
          );
        }

        transaction.update(paymentRef, {
          'status': PaymentStatus.paid.name,
          'paidAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        settled = payment;
      });

      if (settled != null) {
        try {
          await NotificationRepository(_firestore).create(
            toUid: settled!.clientId,
            type: AppNotificationType.paymentConfirmed,
            title: 'Payment confirmed',
            orderId: orderId,
          );
        } on AppFailure {
          // A notification failure never unsettles a real payment.
        }
      }
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Lifetime earnings for a freelancer, derived from settled payments.
  ///
  /// Computed from immutable payment documents rather than stored on the
  /// profile, for the same reason rating averages are: a stored total is a
  /// number a client could try to write.
  ///
  /// Uses an aggregate query, like `ReviewRepository.ratingOf`. Streaming the
  /// documents and summing them client-side capped the total at whatever page
  /// size was chosen — a freelancer past that many paid orders would have been
  /// shown a figure that was simply wrong, with nothing to indicate it.
  Future<EarningsSummary> earningsOf(String uid) async {
    try {
      final aggregate = await _firestore
          .collection(FirestorePaths.payments)
          // participantIds is what the security rule inspects, so the query
          // must constrain it: for a list, Firestore can only prove a query
          // safe over the fields the query itself filters on. Filtering by
          // freelancerId alone left participantIds unknown and every earnings
          // read was denied. freelancerId narrows it further to money earned
          // rather than money spent.
          .where('participantIds', arrayContains: uid)
          .where('freelancerId', isEqualTo: uid)
          .where('status', isEqualTo: PaymentStatus.paid.name)
          .aggregate(count(), sum('amount'), sum('commission'))
          .get();

      final gross = (aggregate.getSum('amount') ?? 0).toInt();
      final commission = (aggregate.getSum('commission') ?? 0).toInt();
      return EarningsSummary(
        orderCount: aggregate.count ?? 0,
        gross: gross,
        commission: commission,
        // Derived by subtraction so it agrees with the split by construction.
        net: gross - commission,
      );
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }
}

/// Aggregate of a freelancer's settled payments.
class EarningsSummary {
  const EarningsSummary({
    required this.orderCount,
    required this.gross,
    required this.commission,
    required this.net,
  });

  static const empty = EarningsSummary(
    orderCount: 0,
    gross: 0,
    commission: 0,
    net: 0,
  );

  final int orderCount;

  /// Total value of settled orders — the platform's gross merchandise value.
  final int gross;

  /// Total platform commission earned from this freelancer's work.
  final int commission;

  /// Total paid out to the freelancer.
  final int net;
}
