import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';

import '../core/money.dart';
import '../models/receipt_draft.dart';

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

class ReceiptServiceException implements Exception {
  const ReceiptServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Calls the application's backend. Gemini API keys never enter the mobile app.
class BackendReceiptService implements ReceiptService {
  BackendReceiptService({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();
  final String baseUrl;
  final http.Client _client;

  @override
  bool get isConfigured {
    final uri = Uri.tryParse(baseUrl);
    return uri != null && {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty;
  }

  @override
  Future<ReceiptDraft> extract(ReceiptPhoto photo, LedgerCurrency currency) async {
    if (!isConfigured) {
      throw const ReceiptServiceException('Receipt scanning is not connected yet. You can try a sample or add an expense manually.');
    }
    if (photo.bytes.length > 15 * 1024 * 1024) {
      throw const ReceiptServiceException('This photo is too large. Choose an image smaller than 15 MB.');
    }
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    final request = http.MultipartRequest('POST', base.resolve('api/receipts/extract'));
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
      throw const ReceiptServiceException('The receipt service did not authorize this request.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const ReceiptServiceException('This receipt could not be read. Try a clearer photo or enter it manually.');
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
  void close() => _client.close();
}
