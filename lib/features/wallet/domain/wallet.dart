import 'package:cloud_firestore/cloud_firestore.dart';

/// Payout rules the app shows before the backend enforces them. Mirrors
/// MINIMUM_PAYOUT in `functions/policy.js`.
abstract final class WalletPolicy {
  /// A transfer costs a fixed fee whatever its size, so a balance has to be
  /// worth moving before it can be requested.
  static const minimumPayout = 300;

  /// A seller's first releases sit in `clearing` for this long before they
  /// can be paid out, so a card chargeback filed after the fact has
  /// somewhere to land. After [newSellerClearedReleases] releases, funds are
  /// available immediately.
  static const newSellerClearanceDays = 7;
  static const newSellerClearedReleases = 3;

  /// A balance whose owner has not signed in for this long is flagged for
  /// staff to reach out, before a graduate's university account is closed
  /// with money still inside. Mirrors DORMANT_WALLET_DAYS in
  /// `functions/policy.js`.
  static const dormantAfterDays = 90;

  /// Banks a payout can be sent to, as Xendit channel codes. Mirrors
  /// BANK_CHANNELS in `functions/policy.js` and the list in the rules.
  static const banks = <String, String>{
    'PH_BDO': 'BDO',
    'PH_BPI': 'BPI',
    'PH_METROBANK': 'Metrobank',
    'PH_LANDBANK': 'Landbank',
    'PH_UNIONBANK': 'UnionBank',
    'PH_SECURITYBANK': 'Security Bank',
    'PH_PNB': 'PNB',
    'PH_RCBC': 'RCBC',
    'PH_CHINABANK': 'Chinabank',
    'PH_EASTWEST': 'EastWest',
  };

  /// GCash and Maya numbers are 11-digit PH mobiles starting 09; bank
  /// accounts are 10 to 16 digits. Mirrors the backend and the rules.
  static bool validAccountNumber(String type, String number) {
    if (type == 'gcash' || type == 'maya') {
      return RegExp(r'^09\d{9}$').hasMatch(number);
    }
    if (type == 'bank') return RegExp(r'^\d{10,16}$').hasMatch(number);
    return false;
  }
}

/// Where a freelancer wants their money sent. The only part of a wallet the
/// owner may write.
class PayoutAccount {
  const PayoutAccount({
    required this.type,
    required this.accountName,
    required this.accountNumber,
    this.bankCode,
  });

  static const types = ['gcash', 'maya', 'bank'];

  final String type;
  final String accountName;
  final String accountNumber;

  /// Which bank, as a Xendit channel code, for `type == 'bank'`.
  final String? bankCode;

  String get typeLabel => switch (type) {
    'gcash' => 'GCash',
    'maya' => 'Maya',
    _ => WalletPolicy.banks[bankCode] ?? 'Bank account',
  };

  /// All but the last four digits hidden, the way a bank shows a card:
  /// enough to recognise the account, not enough to copy it off a screen.
  String get maskedNumber => accountNumber.length <= 4
      ? accountNumber
      : '${'•' * (accountNumber.length - 4)} ${accountNumber.substring(accountNumber.length - 4)}';

  /// Whether a payout can actually be sent here.
  bool get isComplete =>
      WalletPolicy.validAccountNumber(type, accountNumber) &&
      (type != 'bank' || WalletPolicy.banks.containsKey(bankCode));

  Map<String, dynamic> toMap() => {
    'type': type,
    'accountName': accountName,
    'accountNumber': accountNumber,
    if (type == 'bank' && bankCode != null) 'bankCode': bankCode,
  };

  static PayoutAccount? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final type = data['type'] as String?;
    if (type == null || !types.contains(type)) return null;
    return PayoutAccount(
      type: type,
      accountName: data['accountName'] as String? ?? '',
      accountNumber: data['accountNumber'] as String? ?? '',
      bankCode: data['bankCode'] as String?,
    );
  }
}

/// Money the platform holds for one freelancer, at `wallets/{uid}`.
///
/// Every balance here is written only by the backend and only alongside a
/// [LedgerEntry] that explains it. The client reads; it never adds.
class Wallet {
  const Wallet({
    required this.uid,
    required this.available,
    required this.pendingPayout,
    required this.totalReleased,
    required this.totalPaidOut,
    this.clearing = 0,
    this.releaseCount = 0,
    this.owed = 0,
    this.payoutAccount,
  });

  static Wallet empty(String uid) => Wallet(
    uid: uid,
    available: 0,
    pendingPayout: 0,
    totalReleased: 0,
    totalPaidOut: 0,
  );

  /// Released but inside the new-seller clearance window.
  final int clearing;

  /// What a chargeback took that the balance could not cover; repaid from
  /// the next releases before anything is credited.
  final int owed;

  /// How many releases this seller has had; decides whether the next one
  /// clears immediately.
  final int releaseCount;

  bool get isNewSeller => releaseCount < WalletPolicy.newSellerClearedReleases;

  final String uid;

  /// Released and not yet requested; what a payout would move.
  final int available;

  /// Requested and waiting for staff to make the transfer.
  final int pendingPayout;

  /// Lifetime net credited from completed orders.
  final int totalReleased;

  /// Lifetime transferred out.
  final int totalPaidOut;

  final PayoutAccount? payoutAccount;

  bool get canRequestPayout =>
      (payoutAccount?.isComplete ?? false) &&
      pendingPayout == 0 &&
      available >= WalletPolicy.minimumPayout;

  factory Wallet.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return Wallet(
      uid: doc.id,
      available: (data['available'] as num?)?.toInt() ?? 0,
      pendingPayout: (data['pendingPayout'] as num?)?.toInt() ?? 0,
      totalReleased: (data['totalReleased'] as num?)?.toInt() ?? 0,
      totalPaidOut: (data['totalPaidOut'] as num?)?.toInt() ?? 0,
      clearing: (data['clearing'] as num?)?.toInt() ?? 0,
      releaseCount: (data['releaseCount'] as num?)?.toInt() ?? 0,
      owed: (data['owed'] as num?)?.toInt() ?? 0,
      payoutAccount: PayoutAccount.fromMap(
        (data['payoutAccount'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

/// One append-only line in a freelancer's money history.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.amount,
    required this.createdAt,
    this.orderId,
    this.payoutId,
    this.note,
  });

  final String id;

  /// `release`, `refund`, `payout_requested`, `payout_paid`,
  /// `payout_rejected`, `chargeback`, `chargeback_recovery`.
  final String type;

  /// Signed relative to the available balance: a release adds, a payout
  /// request subtracts, a rejected payout adds back.
  final int amount;
  final DateTime createdAt;
  final String? orderId;
  final String? payoutId;
  final String? note;

  String get label => switch (type) {
    'release' => 'Payment released',
    'refund' => 'Refund to client',
    'payout_requested' => 'Payout requested',
    'payout_paid' => 'Payout sent',
    'payout_rejected' => 'Payout returned',
    'chargeback' => 'Payment charged back',
    'chargeback_recovery' => 'Chargeback repaid from a release',
    _ => type,
  };

  factory LedgerEntry.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return LedgerEntry(
      id: doc.id,
      type: data['type'] as String? ?? '',
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      orderId: data['orderId'] as String?,
      payoutId: data['payoutId'] as String?,
      note: data['note'] as String?,
    );
  }
}

enum PayoutStatus {
  /// Waiting for staff, or for the gateway to accept it.
  requested,

  /// Accepted by Xendit; the transfer is in flight.
  processing,

  /// Money left the platform.
  paid,

  /// Staff returned it to the balance.
  rejected,

  /// The gateway could not deliver it; back in the balance.
  failed;

  static PayoutStatus fromName(String? name) => PayoutStatus.values.firstWhere(
    (s) => s.name == name,
    orElse: () => PayoutStatus.requested,
  );

  bool get isOpen => this == requested || this == processing;

  String get label => switch (this) {
    PayoutStatus.requested => 'Waiting to be sent',
    PayoutStatus.processing => 'Transfer in progress',
    PayoutStatus.paid => 'Sent',
    PayoutStatus.rejected => 'Returned to balance',
    PayoutStatus.failed => 'Failed, returned to balance',
  };
}

/// A transfer request, settled by staff by hand and recorded with the
/// transfer's reference number.
class Payout {
  const Payout({
    required this.id,
    required this.uid,
    required this.amount,
    required this.status,
    required this.requestedAt,
    this.account,
    this.reference,
    this.note,
    this.settledAt,
    this.gatewayPayoutId,
    this.gatewayError,
  });

  final String id;
  final String uid;
  final int amount;
  final PayoutStatus status;
  final DateTime requestedAt;
  final PayoutAccount? account;
  final String? reference;
  final String? note;
  final DateTime? settledAt;

  /// Xendit's id for the transfer, once accepted.
  final String? gatewayPayoutId;

  /// Why the last attempt to hand it to the gateway did not go through.
  final String? gatewayError;

  factory Payout.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Payout(
      id: doc.id,
      uid: data['uid'] as String? ?? '',
      amount: (data['amount'] as num?)?.toInt() ?? 0,
      status: PayoutStatus.fromName(data['status'] as String?),
      requestedAt:
          (data['requestedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      account: PayoutAccount.fromMap(
        (data['account'] as Map?)?.cast<String, dynamic>(),
      ),
      reference: data['reference'] as String?,
      note: data['note'] as String?,
      settledAt: (data['settledAt'] as Timestamp?)?.toDate(),
      gatewayPayoutId: data['gatewayPayoutId'] as String?,
      gatewayError: data['gatewayError'] as String?,
    );
  }
}
