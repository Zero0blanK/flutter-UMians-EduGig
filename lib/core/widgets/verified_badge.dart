import 'package:flutter/material.dart';

/// The check mark next to a verified student's name.
///
/// It certifies that staff checked this student's ID and school email, and
/// it is shown only while their Pro subscription is active — the same rule
/// as `UserProfile.hasVerifiedBadge`. A badge that merely meant "paid ₱99"
/// would be the fake trust signal the platform exists to replace, so it is
/// never shown on payment alone.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Verified student',
      child: Semantics(
        label: 'Verified student',
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.secondary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: ExcludeSemantics(
                child: Icon(
                  Icons.check_rounded,
                  size: size * 0.72,
                  color: scheme.onSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
