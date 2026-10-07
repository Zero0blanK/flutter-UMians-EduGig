import 'package:flutter/material.dart';

import '../../../../core/widgets/lily.dart';
import '../../domain/order.dart';

/// The tone and icon for a status, shared by the pill and the step tracker.
(Tone, IconData) orderStatusVisual(OrderStatus status) => switch (status) {
  OrderStatus.pending => (Tone.neutral, Icons.hourglass_empty_rounded),
  OrderStatus.accepted ||
  OrderStatus.inProgress ||
  OrderStatus.submitted => (Tone.active, Icons.bolt_rounded),
  OrderStatus.revisionRequested ||
  OrderStatus.disputed => (Tone.attention, Icons.priority_high_rounded),
  OrderStatus.completed => (Tone.success, Icons.check_circle_rounded),
  OrderStatus.cancelled ||
  OrderStatus.rejected => (Tone.danger, Icons.block_rounded),
};

/// Status pill whose tone encodes where the order sits in its lifecycle:
/// neutral for waiting, lily for active work, pollen for attention needed,
/// stem green when done, error for bad outcomes.
class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip({super.key, required this.status, this.dense = false});

  final OrderStatus status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (tone, icon) = orderStatusVisual(status);
    return StatusPill(
      label: status.label,
      tone: tone,
      icon: icon,
      dense: dense,
    );
  }
}
