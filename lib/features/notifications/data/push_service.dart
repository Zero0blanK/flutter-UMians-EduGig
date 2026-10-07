import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/firestore_paths.dart';

/// Registers this device for push and hands tapped notifications to the app.
///
/// Push is the same inbox document delivered to a locked screen: the backend
/// watches `users/{uid}/notifications` and sends to every token registered
/// under `users/{uid}/devices`. This class owns that registration and
/// nothing else — it never decides who gets told what.
///
/// Foreground arrivals are deliberately ignored here: the app shell already
/// shows a banner from the Firestore stream, and a second one from FCM would
/// be the same news twice.
class PushService {
  PushService(this._firestore, {required this._messaging});

  final FirebaseFirestore _firestore;

  /// Null on platforms without FCM; every method then does nothing.
  final FirebaseMessaging? _messaging;

  StreamSubscription<String>? _tokenRefresh;
  StreamSubscription<RemoteMessage>? _opened;
  String? _uid;
  String? _token;
  int _registrationGeneration = 0;

  /// Web push needs a VAPID key from the Firebase console
  /// (Project settings → Cloud Messaging → Web push certificates).
  static const _vapidKey = String.fromEnvironment('FCM_VAPID_KEY');

  /// FCM has no desktop implementation; on Windows and Linux the app simply
  /// keeps its in-app inbox and this class does nothing.
  static bool get isSupported =>
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.macOS => true,
        _ => false,
      };

  /// Asks permission, registers the token, and keeps it current. Safe to
  /// call on every sign-in; a second call for the same user is a no-op.
  Future<void> register(String uid) async {
    final messaging = _messaging;
    if (messaging == null || !isSupported || _uid == uid) return;
    final generation = ++_registrationGeneration;
    _uid = uid;
    try {
      final settings = await messaging.requestPermission();
      if (!_isCurrentRegistration(uid, generation)) return;
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        _uid = null;
        return;
      }
      final token = await messaging.getToken(
        vapidKey: kIsWeb && _vapidKey.isNotEmpty ? _vapidKey : null,
      );
      if (!_isCurrentRegistration(uid, generation)) return;
      if (token == null) {
        _uid = null;
        return;
      }
      await _save(uid, token, generation);
      if (!_isCurrentRegistration(uid, generation)) return;
      _tokenRefresh?.cancel();
      _tokenRefresh = messaging.onTokenRefresh.listen((fresh) {
        if (_isCurrentRegistration(uid, generation)) {
          _save(uid, fresh, generation);
        }
      });
    } on Exception {
      if (_isCurrentRegistration(uid, generation)) _uid = null;
      // No push on this device (no Play services, permission dialog
      // dismissed, no service worker). The inbox still works.
    }
  }

  /// Forgets this device so the next account on it is not sent the previous
  /// account's notifications.
  Future<void> unregister() async {
    _registrationGeneration++;
    final uid = _uid;
    final token = _token;
    _uid = null;
    _token = null;
    await _tokenRefresh?.cancel();
    _tokenRefresh = null;
    if (uid == null || token == null) return;
    try {
      await _firestore.doc('${FirestorePaths.devices(uid)}/$token').delete();
      await _messaging?.deleteToken();
    } on Exception {
      // Best effort; the backend prunes dead tokens on send anyway.
    }
  }

  /// Delivers the payload of a tapped notification — both the one that
  /// launched a terminated app and any tapped while it ran in the background.
  void listenForTaps(void Function(Map<String, dynamic> data) onTap) {
    final messaging = _messaging;
    if (messaging == null || !isSupported) return;
    messaging.getInitialMessage().then((message) {
      if (message != null) onTap(message.data);
    });
    _opened?.cancel();
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => onTap(message.data),
    );
  }

  bool _isCurrentRegistration(String uid, int generation) =>
      _uid == uid && _registrationGeneration == generation;

  Future<void> _save(String uid, String token, int generation) async {
    if (!_isCurrentRegistration(uid, generation)) return;
    _token = token;
    try {
      await _firestore.doc('${FirestorePaths.devices(uid)}/$token').set({
        'token': token,
        'platform': _platform,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Sign-out may have happened while the write was in flight. Removing
      // the old registration is safer than allowing a later account on this
      // device to receive the previous student's notifications.
      if (!_isCurrentRegistration(uid, generation)) {
        await _firestore.doc('${FirestorePaths.devices(uid)}/$token').delete();
      }
    } on Exception {
      // Rules or network; retried on the next launch.
    }
  }

  static String get _platform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'macos',
    };
  }

  void dispose() {
    _tokenRefresh?.cancel();
    _opened?.cancel();
  }
}
