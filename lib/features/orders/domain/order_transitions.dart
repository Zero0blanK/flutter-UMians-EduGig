import 'order.dart';

export 'order.dart';

/// Order lifecycle transitions. Enforced in three layers:
/// 1. UI only offers buttons for allowed actions ([WorkOrder.canTransition])
/// 2. The repository re-checks inside a transaction before writing
/// 3. Firestore security rules reject illegal writes server-side
const Map<OrderStatus, Set<OrderStatus>> kOrderTransitions = {
  OrderStatus.pending: {
    OrderStatus.accepted,
    OrderStatus.rejected,
    OrderStatus.cancelled,
  },
  OrderStatus.accepted: {
    OrderStatus.inProgress,
    OrderStatus.cancelled,
    OrderStatus.disputed,
  },
  OrderStatus.inProgress: {
    OrderStatus.submitted,
    OrderStatus.cancelled,
    OrderStatus.disputed,
  },
  OrderStatus.submitted: {
    OrderStatus.completed,
    OrderStatus.revisionRequested,
    OrderStatus.disputed,
  },
  // A freelancer redelivers work after the client requested revisions.
  OrderStatus.revisionRequested: {OrderStatus.submitted},
  OrderStatus.completed: {},
  OrderStatus.rejected: {},
  OrderStatus.cancelled: {},
  OrderStatus.disputed: {},
};

/// Which party may trigger each transition, keyed by the **edge** rather than
/// by the destination alone.
///
/// The destination is not enough to identify the actor: cancelling a *pending*
/// request is the buyer's to make (the seller declines with `rejected`),
/// whereas cancelling work already under way is open to either party. Keying
/// on `(from, to)` lets this table mirror `firestore.rules` exactly — when it
/// was keyed on the destination only, the UI offered freelancers a "Cancel"
/// button on pending orders that the rules always rejected.
const Map<(OrderStatus, OrderStatus), Set<OrderRole>> kTransitionActors = {
  // The seller answers a request; declining is `rejected`, not `cancelled`.
  (OrderStatus.pending, OrderStatus.accepted): {OrderRole.freelancer},
  (OrderStatus.pending, OrderStatus.rejected): {OrderRole.freelancer},
  // Only the buyer withdraws their own request.
  (OrderStatus.pending, OrderStatus.cancelled): {OrderRole.client},

  (OrderStatus.accepted, OrderStatus.inProgress): {OrderRole.freelancer},
  (OrderStatus.accepted, OrderStatus.cancelled): {
    OrderRole.client,
    OrderRole.freelancer,
  },
  (OrderStatus.accepted, OrderStatus.disputed): {
    OrderRole.client,
    OrderRole.freelancer,
  },

  (OrderStatus.inProgress, OrderStatus.submitted): {OrderRole.freelancer},
  (OrderStatus.inProgress, OrderStatus.cancelled): {
    OrderRole.client,
    OrderRole.freelancer,
  },
  (OrderStatus.inProgress, OrderStatus.disputed): {
    OrderRole.client,
    OrderRole.freelancer,
  },

  (OrderStatus.submitted, OrderStatus.completed): {OrderRole.client},
  (OrderStatus.submitted, OrderStatus.revisionRequested): {OrderRole.client},
  (OrderStatus.submitted, OrderStatus.disputed): {
    OrderRole.client,
    OrderRole.freelancer,
  },

  (OrderStatus.revisionRequested, OrderStatus.submitted): {
    OrderRole.freelancer,
  },
};
