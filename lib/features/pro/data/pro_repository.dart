import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/backend/backend_client.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/storage/storage_repository.dart';
import '../../payments/data/payment_gateway.dart';
import '../../payments/data/xendit_gateway.dart';
import '../../payments/domain/payment.dart';
import '../domain/pro_policy.dart';
import '../domain/subscription.dart';

/// The Pro subscription and what it unlocks.
///
/// Nothing here grants anything. Buying a month goes through the backend and
/// Xendit; `proUntil` is written by the callback. Featuring a listing asks
/// the backend, which checks the subscription and the cap. The verified
/// badge is decided by staff. The one client write is the verification
/// request itself, which rules pin to the student's own uid and a Storage
/// path under their own folder.
class ProRepository {
  ProRepository(this._firestore, this._backend, this._storage);

  final FirebaseFirestore _firestore;
  final BackendClient _backend;
  final StorageRepository _storage;

  bool get isAvailable => _backend.isConfigured;

  /// Starts a ₱99 checkout for one Pro month. The price is not sent: the
  /// backend charges [ProPolicy.price] whatever the client claims.
  Future<RedirectCheckout> startCheckout(PaymentChannel channel) async {
    final body = await _backend.post(
      '/pro/checkout',
      body: {'method': channel.wireName},
    );
    return XenditGateway.parseRedirect(body);
  }

  /// Every Pro checkout this student started, newest first.
  Stream<List<Subscription>> watchSubscriptions(String uid, {int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.subscriptions)
        .where('uid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map(Subscription.fromFirestore).toList(),
        );
  }

  /// Asks the backend to check the caller's pending Pro checkouts with the
  /// gateway, so a paid one switches Pro on now rather than at the next
  /// callback or reconciliation. Best-effort: nothing to do offline.
  Future<void> syncPending() async {
    if (!_backend.isConfigured) return;
    await _backend.post('/pro/sync');
  }

  Future<void> setFeatured({
    required String serviceId,
    required bool featured,
  }) async {
    await _backend.post(
      '/services/$serviceId/featured',
      body: {'featured': featured},
    );
  }

  Stream<VerificationRequest?> watchVerification(String uid) {
    return _firestore
        .doc(FirestorePaths.verificationRequest(uid))
        .snapshots()
        .map(
          (snapshot) => snapshot.exists
              ? VerificationRequest.fromFirestore(snapshot)
              : null,
        );
  }

  /// Uploads the ID photo first, then writes the request. A request that
  /// points at a file which failed to upload is worse than no request.
  Future<void> submitVerification({
    required String uid,
    required String schoolEmail,
    required PickedFile idPhoto,
  }) async {
    final email = schoolEmail.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email) ||
        email.length > 120) {
      throw const InvalidInputFailure('Enter your school email address.');
    }
    if (!idPhoto.isImage) {
      throw const InvalidInputFailure('The student ID must be a photo.');
    }

    final path = await _storage.uploadVerificationId(uid: uid, file: idPhoto);
    try {
      final ref = _firestore.doc(FirestorePaths.verificationRequest(uid));
      await _firestore.runTransaction((transaction) async {
        final existing = await transaction.get(ref);
        if (existing.exists) {
          final current = VerificationRequest.fromFirestore(existing);
          if (current.status != VerificationStatus.rejected) {
            throw const InvalidInputFailure(
              'You already have a verification request.',
            );
          }
          transaction.update(ref, {
            'schoolEmail': email,
            'idImagePath': path,
            'status': VerificationStatus.pending.name,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return;
        }
        transaction.set(ref, {
          'uid': uid,
          'schoolEmail': email,
          'idImagePath': path,
          'status': VerificationStatus.pending.name,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }
}
