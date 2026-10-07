import 'package:flutter_test/flutter_test.dart';
import 'package:student_freelance_services/features/orders/domain/order_transitions.dart';

WorkOrder orderWithStatus(
  OrderStatus status, {
  int price = 500,
  DisputeProposal? proposal,
}) => WorkOrder(
  id: 'order1',
  serviceId: 'service1',
  serviceTitle: 'Tutoring',
  clientId: 'client-uid',
  freelancerId: 'freelancer-uid',
  price: price,
  currency: 'PHP',
  deliveryDays: 3,
  revisionCount: 1,
  requirements: 'Please help me with calculus',
  status: status,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  disputeResolution: proposal,
);

void main() {
  group('order role resolution', () {
    test('maps uid to client and freelancer roles', () {
      final order = orderWithStatus(OrderStatus.pending);
      expect(order.roleOf('client-uid'), OrderRole.client);
      expect(order.roleOf('freelancer-uid'), OrderRole.freelancer);
      // A stranger is treated as neither participant; transitions are denied.
      expect(order.involves('stranger'), isFalse);
    });
  });

  group('happy path', () {
    test('pending → accepted → inProgress → submitted → completed', () {
      var order = orderWithStatus(OrderStatus.pending);

      expect(
        order.canTransition('freelancer-uid', OrderStatus.accepted),
        isTrue,
      );
      order = orderWithStatus(OrderStatus.accepted);

      expect(
        order.canTransition('freelancer-uid', OrderStatus.inProgress),
        isTrue,
      );
      order = orderWithStatus(OrderStatus.inProgress);

      expect(
        order.canTransition('freelancer-uid', OrderStatus.submitted),
        isTrue,
      );
      order = orderWithStatus(OrderStatus.submitted);

      expect(order.canTransition('client-uid', OrderStatus.completed), isTrue);
    });

    test('revision loop submitted → revisionRequested → submitted', () {
      final submitted = orderWithStatus(OrderStatus.submitted);
      expect(
        submitted.canTransition('client-uid', OrderStatus.revisionRequested),
        isTrue,
      );

      final revisionRequested = orderWithStatus(OrderStatus.revisionRequested);
      expect(
        revisionRequested.canTransition(
          'freelancer-uid',
          OrderStatus.submitted,
        ),
        isTrue,
      );
    });
  });

  group('illegal transitions are rejected', () {
    for (final (from, next) in const [
      (OrderStatus.pending, OrderStatus.inProgress),
      (OrderStatus.pending, OrderStatus.completed),
      (OrderStatus.completed, OrderStatus.inProgress),
      (OrderStatus.cancelled, OrderStatus.accepted),
      (OrderStatus.rejected, OrderStatus.accepted),
      (OrderStatus.disputed, OrderStatus.completed),
      (OrderStatus.revisionRequested, OrderStatus.completed),
      (OrderStatus.accepted, OrderStatus.submitted),
    ]) {
      test('$from → $next is denied', () {
        final order = orderWithStatus(from);
        expect(order.canTransition('client-uid', next), isFalse);
        expect(order.canTransition('freelancer-uid', next), isFalse);
      });
    }
  });

  group('wrong actor is rejected', () {
    test('client cannot accept their own pending order', () {
      final order = orderWithStatus(OrderStatus.pending);
      expect(order.canTransition('client-uid', OrderStatus.accepted), isFalse);
    });

    test('freelancer cannot complete the order themselves', () {
      final order = orderWithStatus(OrderStatus.submitted);
      expect(
        order.canTransition('freelancer-uid', OrderStatus.completed),
        isFalse,
      );
    });

    test('client cannot start or submit work', () {
      final accepted = orderWithStatus(OrderStatus.accepted);
      expect(
        accepted.canTransition('client-uid', OrderStatus.inProgress),
        isFalse,
      );
      final inProgress = orderWithStatus(OrderStatus.inProgress);
      expect(
        inProgress.canTransition('client-uid', OrderStatus.submitted),
        isFalse,
      );
    });

    test('stranger can never transition anything', () {
      const statuses = OrderStatus.values;
      for (final status in statuses) {
        final order = orderWithStatus(status);
        for (final next in statuses) {
          expect(
            order.canTransition('stranger-uid', next),
            isFalse,
            reason: '$status → $next by stranger must be denied',
          );
        }
      }
    });
  });

  group('transition table integrity', () {
    test('every status has a transition entry', () {
      for (final status in OrderStatus.values) {
        expect(kOrderTransitions.containsKey(status), isTrue);
      }
    });

    test('isFinished agrees with the transition table', () {
      // The two must not drift: a status with no way out is finished, and a
      // status with a way out is not.
      for (final status in OrderStatus.values) {
        expect(
          status.isFinished,
          kOrderTransitions[status]!.isEmpty,
          reason: '${status.name} disagrees with its outgoing transitions',
        );
      }
    });

    test('terminal states have no outgoing transitions', () {
      expect(kOrderTransitions[OrderStatus.completed], isEmpty);
      expect(kOrderTransitions[OrderStatus.cancelled], isEmpty);
      expect(kOrderTransitions[OrderStatus.rejected], isEmpty);
      expect(kOrderTransitions[OrderStatus.disputed], isEmpty);
    });

    test('every reachable edge has a defined actor set', () {
      kOrderTransitions.forEach((from, targets) {
        for (final target in targets) {
          expect(
            kTransitionActors.containsKey((from, target)),
            isTrue,
            reason: '$from → $target lacks an actor rule',
          );
        }
      });
    });

    test('actor rules describe no edge the state machine cannot take', () {
      for (final edge in kTransitionActors.keys) {
        expect(
          kOrderTransitions[edge.$1]!.contains(edge.$2),
          isTrue,
          reason: '${edge.$1} → ${edge.$2} has actors but is unreachable',
        );
      }
    });

    test('only the buyer may withdraw a pending request', () {
      // Mirrors firestore.rules: the seller declines with `rejected`, and a
      // seller-side Cancel would be rejected server-side.
      final order = orderWithStatus(OrderStatus.pending);
      expect(order.canTransition('client-uid', OrderStatus.cancelled), isTrue);
      expect(
        order.canTransition('freelancer-uid', OrderStatus.cancelled),
        isFalse,
      );
      expect(
        order.canTransition('freelancer-uid', OrderStatus.rejected),
        isTrue,
      );
    });

    test('either party may cancel or dispute work already under way', () {
      for (final status in [OrderStatus.accepted, OrderStatus.inProgress]) {
        final order = orderWithStatus(status);
        for (final uid in ['client-uid', 'freelancer-uid']) {
          expect(order.canTransition(uid, OrderStatus.cancelled), isTrue);
          expect(order.canTransition(uid, OrderStatus.disputed), isTrue);
        }
      }
    });
  });

  group('dispute resolution', () {
    const small = 500;
    const big = DisputePolicy.secondOpinionFrom;
    final proposal = DisputeProposal(
      outcome: OrderStatus.completed,
      proposedBy: 'staff-a',
      proposedAt: DateTime(2026),
    );

    test('a small dispute is closed by any staff member alone', () {
      final order = orderWithStatus(OrderStatus.disputed, price: small);
      expect(order.canResolveDispute('staff-a', OrderStatus.completed), isTrue);
      expect(order.canResolveDispute('staff-a', OrderStatus.cancelled), isTrue);
      // Only the two closing outcomes exist.
      expect(
        order.canResolveDispute('staff-a', OrderStatus.inProgress),
        isFalse,
      );
    });

    test('a large dispute needs a proposal from someone else', () {
      // The threshold itself counts as large; mirrors the rules' `< 2000`.
      final open = orderWithStatus(OrderStatus.disputed, price: big);
      expect(open.canResolveDispute('staff-a', OrderStatus.completed), isFalse);

      final proposed = orderWithStatus(
        OrderStatus.disputed,
        price: big,
        proposal: proposal,
      );
      expect(
        proposed.canResolveDispute('staff-a', OrderStatus.completed),
        isFalse,
        reason: 'the proposer cannot confirm their own proposal',
      );
      expect(
        proposed.canResolveDispute('staff-b', OrderStatus.completed),
        isTrue,
      );
      expect(
        proposed.canResolveDispute('staff-b', OrderStatus.cancelled),
        isFalse,
        reason: 'a different outcome is a new decision, not a confirmation',
      );
    });

    test('nothing but a disputed order can be resolved', () {
      final done = orderWithStatus(OrderStatus.completed, proposal: proposal);
      expect(done.canResolveDispute('staff-b', OrderStatus.completed), isFalse);
    });
  });
}
