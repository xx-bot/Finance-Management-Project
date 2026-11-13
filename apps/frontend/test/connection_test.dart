import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_ledger/core/money.dart';
import 'package:pocket_ledger/services/receipt_service.dart';

import 'support.dart';

Map<String, dynamic> accountResponse() => {
  'user': {'id': 'account-id', 'email': 'alex@example.test'},
  'access_token': List.filled(43, 'a').join(),
  'expires_at': DateTime.now().toUtc().add(const Duration(days: 1)).toIso8601String(),
};

void main() {
  test('signup stores a session without storing the password and restoration enables scanning', () async {
    final storage = MemoryConnectionStore();
    final service = BackendReceiptService(baseUrl: '', connectionStore: storage, client: MockClient((request) async {
      expect(request.url.path, '/api/auth/register');
      expect(jsonDecode(request.body)['password'], 'long-test-password');
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(jsonEncode(accountResponse()), 201);
    }));
    expect(service.isConfigured, isFalse);
    await service.authenticate(baseUrl: 'https://backend.example', email: 'alex@example.test', password: 'long-test-password', register: true);
    expect(service.isConfigured, isTrue);
    expect(storage.value, isNot(contains('long-test-password')));
    service.close();

    final restored = BackendReceiptService(baseUrl: '', connectionStore: storage, client: MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer ${accountResponse()['access_token']}');
      return http.Response('{"receipt":{"items":[],"total":"436.20"}}', 200);
    }));
    await restored.initialize();
    expect(restored.baseUrl, 'https://backend.example');
    expect(restored.accountEmail, 'alex@example.test');
    final draft = await restored.extract(ReceiptPhoto(Uint8List.fromList([1]), 'receipt.jpg'), LedgerCurrency.myr);
    expect(draft.total, '436.20');
    restored.close();
  });

  test('a server address without a session cannot upload a photo', () async {
    final service = BackendReceiptService(baseUrl: 'https://backend.example', connectionStore: MemoryConnectionStore(), client: MockClient((_) async {
      fail('A photo was sent without a session.');
    }));
    expect(service.isConfigured, isFalse);
    await expectLater(service.extract(ReceiptPhoto(Uint8List(1), 'photo.jpg'), LedgerCurrency.idr),
      throwsA(isA<ReceiptServiceException>().having((e) => e.needsAuthentication, 'needsAuthentication', isTrue)));
    service.close();
  });

  test('an expired stored session remembers its server but requires sign-in', () async {
    final storage = MemoryConnectionStore()..value = jsonEncode({
      'base_url': 'https://backend.example', 'email': 'alex@example.test', 'access_token': 'old-token',
      'expires_at': DateTime.now().toUtc().subtract(const Duration(days: 1)).toIso8601String(),
    });
    final service = BackendReceiptService(baseUrl: '', connectionStore: storage);
    await service.initialize();
    expect(service.isConfigured, isFalse);
    expect(service.baseUrl, 'https://backend.example');
    service.close();
  });

  test('rejected sessions are cleared and cannot keep uploading', () async {
    final storage = MemoryConnectionStore();
    final service = BackendReceiptService(baseUrl: 'https://backend.example', authToken: 'old-token', connectionStore: storage,
      client: MockClient((_) async => http.Response('{"error":{"message":"expired"}}', 401)));
    await expectLater(service.extract(ReceiptPhoto(Uint8List(1), 'photo.jpg'), LedgerCurrency.idr),
      throwsA(isA<ReceiptServiceException>().having((e) => e.needsAuthentication, 'needsAuthentication', isTrue)));
    expect(service.isConfigured, isFalse);
    expect(jsonDecode(storage.value!)['access_token'], isEmpty);
    service.close();
  });

  test('logout revokes the session and keeps the server address for the next login', () async {
    final storage = MemoryConnectionStore();
    final service = BackendReceiptService(baseUrl: 'https://backend.example', authToken: 'session-token', connectionStore: storage,
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/logout');
        expect(request.headers['authorization'], 'Bearer session-token');
        return http.Response('', 204);
      }));
    await service.signOut();
    expect(service.isConfigured, isFalse);
    final restored = BackendReceiptService(baseUrl: '', connectionStore: storage);
    await restored.initialize();
    expect(restored.isConfigured, isFalse);
    expect(restored.baseUrl, 'https://backend.example');
    service.close(); restored.close();
  });

  test('failed authentication and secure-storage failures do not enable scanning', () async {
    for (final failure in ['credentials', 'storage']) {
      final storage = MemoryConnectionStore()..failWrites = failure == 'storage';
      final service = BackendReceiptService(baseUrl: '', connectionStore: storage, client: MockClient((_) async => failure == 'credentials'
        ? http.Response('{"error":{"message":"Email or password is incorrect."}}', 401)
        : http.Response(jsonEncode(accountResponse()), 200)));
      await expectLater(service.authenticate(baseUrl: 'https://backend.example', email: 'alex@example.test', password: 'password123'),
        throwsA(isA<ReceiptServiceException>()));
      expect(service.isConfigured, isFalse);
      service.close();
    }
  });
}
