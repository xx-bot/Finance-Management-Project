import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_ledger/core/money.dart';
import 'package:pocket_ledger/services/receipt_service.dart';

void main() {
  final photo = ReceiptPhoto(Uint8List.fromList([0xff, 0xd8, 0xff]), 'receipt.jpg');
  test('uploads one multipart image to the backend and retains the receipt photo', () async {
    final service = BackendReceiptService(baseUrl: 'https://backend.example/', client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://backend.example/api/receipts/extract');
      expect(request.headers['content-type'], startsWith('multipart/form-data'));
      final multipart = latin1.decode(request.bodyBytes);
      expect(multipart, contains('name="image"'));
      expect(multipart, contains('filename="receipt.jpg"'));
      return http.Response(jsonEncode({'receipt': {'items': [], 'total': '436.20'}}), 200);
    }));
    final draft = await service.extract(photo, LedgerCurrency.myr);
    expect(draft.total, '436.20');
    expect(draft.currency, LedgerCurrency.myr);
    expect(draft.numberStyle, isNull);
    expect(draft.imageBytes, photo.bytes);
    service.close();
  });

  test('quota failures and malformed responses cannot become expenses', () async {
    for (final response in [http.Response('{}', 429), http.Response('not json', 200),
        http.Response('{"total":"1"}', 200), http.Response('{"items":[]}', 200),
        http.Response('{"items":[{}],"total":"1"}', 200)]) {
      final service = BackendReceiptService(baseUrl: 'https://backend.example', client: MockClient((_) async => response));
      await expectLater(service.extract(photo, LedgerCurrency.idr), throwsA(isA<ReceiptServiceException>()));
      service.close();
    }
  });

  test('an unconfigured app makes no network request', () async {
    final service = BackendReceiptService(baseUrl: '', client: MockClient((_) async {
      fail('An unconfigured service must not upload a photo.');
    }));
    await expectLater(service.extract(photo, LedgerCurrency.idr), throwsA(isA<ReceiptServiceException>()));
    service.close();
  });
}
