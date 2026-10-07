import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Central notification routing. Every entry point (foreground tap, background
/// tap, terminated cold start) funnels through [route] so navigation logic for
/// notifications lives in exactly one place.
///
/// IDs arrive from outside the app (FCM payloads) and are validated before
/// they are ever placed into a route. A tapped push and a tapped inbox row
/// carry the same payload and land on the same screen.
class NotificationRouter {
  /// From a widget: taps on inbox rows.
  NotificationRouter(BuildContext context)
    : _push = context.push,
      _go = context.go;

  /// From the app root: taps on push notifications arrive before any screen
  /// has a context, so the router itself does the navigating.
  NotificationRouter.withRouter(GoRouter router)
    : _push = router.push,
      _go = router.go;

  final Future<Object?> Function(String location) _push;
  final void Function(String location) _go;

  void route({required String type, String? conversationId, String? orderId}) {
    switch (type) {
      case 'chat.message':
      case 'offer.received':
      case 'offer.accepted':
      case 'offer.declined':
        final id = _safeId(conversationId);
        if (id != null) {
          _push('/chat/$id');
        } else {
          _fallback();
        }
      case 'order.created':
      case 'order.accepted':
      case 'order.rejected':
      case 'order.started':
      case 'order.submitted':
      case 'order.revision_requested':
      case 'order.completed':
      case 'order.cancelled':
      case 'order.auto_complete_reminder':
      case 'payment.confirmed':
      case 'payment.released':
      case 'payment.refunded':
        final id = _safeId(orderId);
        if (id != null) {
          _push('/order/$id');
        } else {
          _fallback();
        }
      // Money and account events live on the profile: the wallet, the Pro
      // card, and the verification card are all there.
      case 'payment.charged_back':
      case 'wallet.dormant':
        _push('/wallet');
      case 'payout.paid':
      case 'payout.rejected':
      case 'pro.activated':
      case 'verification.approved':
      case 'verification.rejected':
        _go('/profile');
      // Staff alerts land on the console, whatever tab needs them.
      case 'admin.refund_attention':
      case 'admin.payout_requested':
      case 'admin.verification_pending':
      case 'admin.dormant_wallet':
        _go('/admin');
      default:
        _fallback();
    }
  }

  /// Unknown or malformed payloads land in the notifications inbox rather
  /// than being dropped or guessed at.
  void _fallback() => _go('/notifications');

  void routeFromData(Map<String, dynamic> data) {
    route(
      type: data['type'] as String? ?? '',
      conversationId: data['conversationId'] as String?,
      orderId: data['orderId'] as String?,
    );
  }

  /// Guards against malformed or hostile deep-link identifiers.
  String? _safeId(String? id) {
    if (id == null || id.isEmpty || id.length > 120) return null;
    if (id.contains('/') || id.contains('..') || id.contains('\n')) return null;
    return id;
  }
}
