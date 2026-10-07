import 'dart:convert';

import 'package:http/http.dart' as http;

import '../errors/app_failure.dart';

/// Authenticated JSON calls to **our own backend** (`functions/`).
///
/// Every route the app calls takes ids only. Amounts, entitlements, and who
/// may do what are all re-derived server-side from Firestore, so a tampered
/// request cannot buy anything it is not owed. The backend is also the only
/// place the Xendit secret key lives — an APK decompiles and a web build
/// ships readable JavaScript, so it can never live here.
///
/// [baseUrl] is empty when the app was built without `PAYMENTS_API_URL`, in
/// which case [isConfigured] is false and every feature that needs a server
/// says so instead of failing mid-flow.
class BackendClient {
  BackendClient({
    required this.baseUrl,
    required Future<String?> Function() idTokenProvider,
    http.Client? client,
  }) : _idToken = idTokenProvider,
       _client = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() _idToken;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  bool get isConfigured => baseUrl.isNotEmpty;

  /// POSTs [body] to [path] and returns the decoded JSON object.
  ///
  /// Maps the backend's status codes onto the app's failure hierarchy: 401/403
  /// are permission problems, 4xx with a message is shown to the user
  /// verbatim (the backend writes those for people), and anything else is a
  /// generic gateway failure with the detail left in server logs.
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic> body = const {},
  }) async {
    if (!isConfigured) throw const BackendUnavailableFailure();
    final token = await _idToken();
    if (token == null) throw const PermissionFailure();

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on Exception {
      throw const NetworkFailure();
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on Object {
      decoded = const {};
    }

    switch (response.statusCode) {
      case 200:
        return decoded;
      case 401:
      case 403:
        throw const PermissionFailure();
      case 404:
        throw const NotFoundFailure();
      case >= 400 && < 500:
        final message = decoded['error'];
        if (message is String && message.isNotEmpty) {
          throw InvalidInputFailure(message);
        }
        throw const PaymentGatewayFailure();
      default:
        throw const PaymentGatewayFailure();
    }
  }

  void dispose() => _client.close();
}
