// Platform commission maths.
//
// All money in this app is an integer number of whole currency units (see
// `FreelanceService.startingPrice`). Commission is therefore computed with
// integer arithmetic only — never doubles — so a split can never drift by a
// centavo and `commission + netToFreelancer` always equals `gross` exactly.

/// How much of an order's value the platform keeps.
///
/// The rate is held in basis points (1 bp = 0.01%) so that the rate itself is
/// an integer and survives storage and comparison without float error.
///
/// There is one policy. The Pro subscription deliberately does **not**
/// discount it: a cheaper rate for the most active sellers would cut the
/// primary revenue stream exactly where it is largest. Pro buys visibility
/// and a verified badge instead (see `ProPolicy`).
///
/// The backend holds a twin of this maths in `functions/policy.js`; its answer
/// is the one that is charged. This copy exists so the UI can show the same
/// figure before the request is made.
class CommissionPolicy {
  const CommissionPolicy(this.rateBasisPoints, {this.minimumCommission = 0});

  /// Default: 5% of every paid order, rounded half-up to whole pesos.
  static const standard = CommissionPolicy(500);

  static const _scale = 10000;

  final int rateBasisPoints;

  /// Smallest commission on any order, in whole currency units. Never
  /// exceeds the gross itself: a ₱10 order owes ₱10, not ₱20.
  final int minimumCommission;

  /// Human-readable rate, e.g. `5%` or `2.5%`.
  String get rateLabel {
    final whole = rateBasisPoints ~/ 100;
    final fraction = rateBasisPoints % 100;
    return fraction == 0 ? '$whole%' : '$whole.${fraction ~/ 10}%';
  }

  /// Splits [gross] into the platform's cut and the freelancer's payout.
  ///
  /// Rounds the commission half-up, applies the floor, then derives the
  /// payout by subtraction so the two parts always reconstitute [gross] with
  /// no rounding remainder.
  CommissionBreakdown breakdownOf(int gross) {
    if (gross < 0) {
      throw ArgumentError.value(
        gross,
        'gross',
        'Order value cannot be negative',
      );
    }
    var commission = (gross * rateBasisPoints + _scale ~/ 2) ~/ _scale;
    if (commission < minimumCommission) {
      commission = minimumCommission < gross ? minimumCommission : gross;
    }
    return CommissionBreakdown(
      gross: gross,
      commission: commission,
      netToFreelancer: gross - commission,
      rateBasisPoints: rateBasisPoints,
    );
  }
}

/// The three numbers shown to both parties before money changes hands.
class CommissionBreakdown {
  const CommissionBreakdown({
    required this.gross,
    required this.commission,
    required this.netToFreelancer,
    required this.rateBasisPoints,
  });

  /// What the client pays.
  final int gross;

  /// What the platform keeps — the primary revenue stream.
  final int commission;

  /// What the freelancer receives.
  final int netToFreelancer;

  final int rateBasisPoints;

  /// Invariant the UI, the repository, and the backend all rely on.
  bool get isBalanced => commission + netToFreelancer == gross;
}
