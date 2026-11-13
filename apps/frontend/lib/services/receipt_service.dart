import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';

import '../core/money.dart';
import '../models/receipt_draft.dart';
import 'connection_store.dart';

class ReceiptPhoto {
  const ReceiptPhoto(this.bytes, this.filename);
  final Uint8List bytes;
  final String filename;
}

abstract interface class ReceiptService {
  bool get isConfigured;
  Future<ReceiptDraft> extract(ReceiptPhoto photo, LedgerCurrency currency);
  void close();
}

abstract interface class ConnectableReceiptService implements ReceiptService, Listenable {
  String get baseUrl;
  String? get accountEmail;
  Future<void> initialize();
  Future<void> authenticate({required String baseUrl, required String email, required String password, bool register = false});
  Future<String> checkConnection(String baseUrl);
  Future<void> signOut();
}

class ReceiptServiceException implements Exception {
  const ReceiptServiceException(this.message, {this.needsAuthentication = false});
  final String message;
  final bool needsAuthentication;
  @override
  String toString() => message;
}

/// Calls the application's backend. Gemini API keys never enter the mobile app.
class BackendReceiptService extends ChangeNotifier implements ConnectableReceiptService {
  BackendReceiptService({required String baseUrl, String authToken = '', http.Client? client, ConnectionStore? connectionStore})
      : _baseUrl = baseUrl.trim(), _authToken = authToken.trim(),
        _client = client ?? http.Client(), _store = connectionStore ?? SecureConnectionStore();
  String _baseUrl;
  String _authToken;
  String? _email;
  DateTime? _expiresAt;
  bool _closed = false;
  final ConnectionStore _store;
  final http.Client _client;

  @override
  String get baseUrl => _baseUrl;
  @override
  String? get accountEmail => _email;

  static bool validBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty &&
        uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment;
  }

  Uri _endpoint(String base, String path) => Uri.parse(base.endsWith('/') ? base : '$base/').resolve(path);

  @override
  Future<void> initialize() async {
    // A connection saved in the app takes precedence over build-time defaults.
    try {
      final saved = await _store.read();
      if (saved == null) return;
      final value = jsonDecode(saved) as Map<String, dynamic>;
      final url = value['base_url'] as String;
      if (!validBaseUrl(url)) return;
      final token = value['access_token'] as String? ?? '';
      final expiresText = value['expires_at'] as String?;
      final expires = expiresText == null ? null : DateTime.parse(expiresText);
      _baseUrl = url;
      _email = value['email'] as String?;
      _authToken = token.isNotEmpty && expires != null && expires.isAfter(DateTime.now()) ? token : '';
      _expiresAt = expires;
      if (!_closed) notifyListeners();
    } on Object {
      // A missing/unreadable saved session must not prevent access to local expenses.
    }
  }

  @override
  bool get isConfigured {
    return validBaseUrl(baseUrl) && _authToken.isNotEmpty &&
        (_expiresAt == null || _expiresAt!.isAfter(DateTime.now()));
  }

  Future<http.Response> _sendAccountRequest(String base, String path, Map<String, String> body) async {
    try {
      return await _client.post(_endpoint(base, path), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } on Exception {
      throw const ReceiptServiceException('Could not connect to the receipt service. Check the server address and your connection.');
    }
  }

  String _message(http.Response response, String fallback) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final message = body['error']['message'];
      if (message is String && message.isNotEmpty && message.length <= 400) return message;
    } on Object { /* Use the safe local fallback for non-JSON gateway responses. */ }
    return fallback;
  }

  @override
  Future<void> authenticate({required String baseUrl, required String email, required String password, bool register = false}) async {
    baseUrl = baseUrl.trim();
    if (!validBaseUrl(baseUrl)) throw const ReceiptServiceException('Enter a valid HTTP or HTTPS server address.');
    final response = await _sendAccountRequest(baseUrl, register ? 'api/auth/register' : 'api/auth/login', {'email': email.trim(), 'password': password});
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ReceiptServiceException(_message(response, 'Could not sign in. Check the server address and account details.'));
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final token = body['access_token'] as String;
      final expires = DateTime.parse(body['expires_at'] as String);
      final userEmail = (body['user'] as Map<String, dynamic>)['email'] as String;
      if (token.isEmpty || !expires.isAfter(DateTime.now()) || userEmail.isEmpty) throw const FormatException();
      final saved = jsonEncode({'base_url': baseUrl, 'access_token': token, 'expires_at': expires.toIso8601String(), 'email': userEmail});
      try { await _store.write(saved); }
      on Object { throw const ReceiptServiceException('Could not save the session on this device. Try signing in again.'); }
      _baseUrl = baseUrl; _authToken = token; _expiresAt = expires; _email = userEmail;
      if (!_closed) notifyListeners();
    } on ReceiptServiceException { rethrow; }
    on Object { throw const ReceiptServiceException('The server returned an incomplete sign-in response.'); }
  }

  @override
  Future<String> checkConnection(String baseUrl) async {
    baseUrl = baseUrl.trim();
    if (!validBaseUrl(baseUrl)) throw const ReceiptServiceException('Enter a valid HTTP or HTTPS server address.');
    http.Response response;
    try { response = await _client.get(_endpoint(baseUrl, 'health/ready')).timeout(const Duration(seconds: 8)); }
    on Exception { throw const ReceiptServiceException('Could not reach this server. Check the address and your connection.'); }
    if (response.statusCode != 200) throw const ReceiptServiceException('The receipt service is not ready. Please try again shortly.');
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['status'] != 'ready') throw const FormatException();
      return body['extraction_configured'] == true
          ? 'Receipt service is available. Sign in to start scanning.'
          : 'Server is available, but receipt extraction is not configured yet.';
    } on Object { throw const ReceiptServiceException('This address did not return a receipt service response.'); }
  }

  Future<void> _clearSession() async {
    _authToken = ''; _email = null; _expiresAt = null;
    try {
      await _store.write(jsonEncode({'base_url': _baseUrl, 'access_token': '', 'email': null, 'expires_at': null}));
    } on Object {
      try { await _store.clear(); } on Object { /* The current session is still cleared from memory. */ }
    }
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> signOut() async {
    final token = _authToken;
    if (validBaseUrl(baseUrl) && token.isNotEmpty) {
      try { await _client.post(_endpoint(baseUrl, 'api/auth/logout'), headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 8)); }
      on Exception { /* Allow local sign-out while the server is unreachable. */ }
    }
    await _clearSession();
  }

  @override
  Future<ReceiptDraft> extract(ReceiptPhoto photo, LedgerCurrency currency) async {
    if (!isConfigured) {
      throw const ReceiptServiceException('Connect your receipt service and sign in to scan a photo.', needsAuthentication: true);
    }
    if (photo.bytes.length > 15 * 1024 * 1024) {
      throw const ReceiptServiceException('This photo is too large. Choose an image smaller than 15 MB.');
    }
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    final request = http.MultipartRequest('POST', base.resolve('api/receipts/extract'));
    request.headers['Authorization'] = 'Bearer $_authToken';
    final mime = lookupMimeType(photo.filename, headerBytes: photo.bytes.take(32).toList()) ?? 'application/octet-stream';
    request.files.add(http.MultipartFile.fromBytes('image', photo.bytes,
        filename: photo.filename, contentType: MediaType.parse(mime)));
    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(const Duration(seconds: 120));
      response = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 120));
    } on Exception {
      throw const ReceiptServiceException('We could not reach the receipt service. Check your connection and try again.');
    }
    if (response.statusCode == 429) {
      throw const ReceiptServiceException('Receipt scanning has reached its usage limit. Please try again later.');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      await _clearSession();
      throw const ReceiptServiceException('Your receipt service session has expired. Please sign in again.', needsAuthentication: true);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ReceiptServiceException(_message(response, 'This receipt could not be read. Try a clearer photo or enter it manually.'));
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) throw const FormatException();
      final draft = ReceiptDraft.fromExtraction(body, currency);
      draft.imageBytes = photo.bytes;
      draft.imageName = photo.filename;
      return draft;
    } on Object {
      throw const ReceiptServiceException('The receipt result was incomplete. Please retry or enter it manually.');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
    dispose();
  }
}
