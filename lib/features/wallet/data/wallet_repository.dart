import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/backend/backend_client.dart';
import '../../../core/constants/firestore_paths.dart';
import '../../../core/errors/app_failure.dart';
import '../domain/wallet.dart';

/// What happened to a payout request once the backend had it.
class PayoutRequestResult {
  const PayoutRequestResult({required this.amount, required this.delivery});

  final int amount;

  /// `manual` (staff queue), `submitted` (with Xendit), `refused` (returned
  /// to the balance at once) or `unreachable` (queued for staff to retry).
  final String delivery;

  String get message => switch (delivery) {
    'submitted' => 'Sent to Xendit. It usually lands within minutes.',
    'refused' =>
      'Xendit could not accept the account details; the money is back in '
          'your balance. Check the account and try again.',
    'unreachable' =>
      'Xendit is not responding right now; staff will send it shortly.',
    _ => 'Requested. Staff make transfers in weekly batches.',
  };
}

/// Reads a freelancer's held money and asks the backend to move it.
///
/// Balances are never written from here. The one client write is the payout
/// account, and rules restrict the wallet document to exactly that field.
class WalletRepository {
  WalletRepository(this._firestore, this._backend);

  final FirebaseFirestore _firestore;
  final BackendClient _backend;

  bool get payoutsAvailable => _backend.isConfigured;

  Stream<Wallet> watchWallet(String uid) {
    return _firestore
        .doc(FirestorePaths.wallet(uid))
        .snapshots()
        .map(
          (snapshot) => snapshot.exists
              ? Wallet.fromFirestore(snapshot)
              : Wallet.empty(uid),
        );
  }

  Stream<List<LedgerEntry>> watchLedger(String uid, {int limit = 50}) {
    return _firestore
        .collection(FirestorePaths.ledger)
        .where('uid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((s) => s.docs.map(LedgerEntry.fromFirestore).toList());
  }

  Stream<List<Payout>> watchPayouts(String uid) {
    return _firestore
        .collection(FirestorePaths.payouts)
        .where('uid', isEqualTo: uid)
        .orderBy('requestedAt', descending: true)
        .limit(20)
        .snapshots()
        .map((s) => s.docs.map(Payout.fromFirestore).toList());
  }

  Future<void> savePayoutAccount({
    required String uid,
    required PayoutAccount account,
  }) async {
    if (account.accountName.trim().isEmpty || account.accountName.length > 80) {
      throw const InvalidInputFailure('Enter the account holder\'s name.');
    }
    final number = account.accountNumber.trim();
    if (!WalletPolicy.validAccountNumber(account.type, number)) {
      throw InvalidInputFailure(
        account.type == 'bank'
            ? 'Enter the account number: 10 to 16 digits.'
            : 'Enter an 11-digit mobile number starting with 09.',
      );
    }
    if (account.type == 'bank' &&
        !WalletPolicy.banks.containsKey(account.bankCode)) {
      throw const InvalidInputFailure('Choose your bank.');
    }
    try {
      await _firestore.doc(FirestorePaths.wallet(uid)).set({
        'uid': uid,
        'payoutAccount': PayoutAccount(
          type: account.type,
          accountName: account.accountName.trim(),
          accountNumber: number,
          bankCode: account.type == 'bank' ? account.bankCode : null,
        ).toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on Exception catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Moves the whole available balance into a payout request. The backend
  /// re-checks the minimum, the account, and that nothing is already pending,
  /// and — when payouts are automated — hands it to Xendit at once.
  Future<PayoutRequestResult> requestPayout() async {
    final body = await _backend.post('/wallet/payout');
    return PayoutRequestResult(
      amount: (body['amount'] as num?)?.toInt() ?? 0,
      delivery: body['delivery'] as String? ?? 'manual',
    );
  }
}
