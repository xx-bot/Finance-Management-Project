import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pocket_ledger/app.dart';
import 'package:pocket_ledger/models/expense.dart';
import 'package:pocket_ledger/services/photo_picker.dart';
import 'package:pocket_ledger/services/receipt_service.dart';
import 'package:pocket_ledger/ui/screens/review_screen.dart';

import 'connection_test.dart' show accountResponse;
import 'support.dart';

class _TestPhotoPicker extends ReceiptPhotoPicker {
  @override
  Future<ReceiptPhoto?> recover() async => null;
  @override
  Future<ReceiptPhoto?> pick(ImageSource source) async => ReceiptPhoto(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7dsAAAAASUVORK5CYII='), 'receipt.png');
}

void main() {
  testWidgets('register, extract, correct merchant/category suggestions and save after review', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var extracts = 0;
    final storage = MemoryConnectionStore();
    final service = BackendReceiptService(baseUrl: 'https://backend.example', connectionStore: storage, client: MockClient((request) async {
      if (request.url.path == '/api/auth/register') return http.Response(jsonEncode(accountResponse()), 201);
      expect(request.url.path, '/api/receipts/extract');
      expect(request.headers['authorization'], 'Bearer ${accountResponse()['access_token']}');
      extracts++;
      return http.Response(jsonEncode({'receipt': {
        'merchant': 'Corner Cafe', 'category': 'dining', 'total': '12.00',
        'items': [{
          'description': 'Coffee', 'quantity': '1', 'unit_price': '12.00',
          'line_total': '12.00', 'category': 'dining', 'sub_items': [{
            'description': 'Oat milk', 'quantity': null, 'unit_price': null,
            'line_total': null, 'category': 'dining', 'sub_items': [],
          }],
        }],
      }}), 200);
    }));
    final repository = MemoryLedgerRepository();
    await tester.pumpWidget(PocketApp(repository: repository, receiptService: service, photoPicker: _TestPhotoPicker()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Connect receipt service'), 250);
    await tester.tap(find.text('Connect receipt service'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account'));
    await tester.enterText(find.byType(TextFormField).at(1), 'alex@example.test');
    await tester.enterText(find.byType(TextFormField).at(2), 'long-test-password');
    await tester.ensureVisible(find.text('Create account & connect'));
    await tester.tap(find.text('Create account & connect'));
    await tester.pumpAndSettle();
    expect(service.isConfigured, isTrue);
    expect(storage.value, isNot(contains('long-test-password')));
    await tester.ensureVisible(find.text('Gallery'));
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Extract receipt'));
    await tester.tap(find.text('Extract receipt'));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);
    expect(extracts, 1);
    expect(repository.saved, isEmpty);
    final reviewScroll = find.descendant(of: find.byType(ReviewScreen), matching: find.byType(Scrollable)).first;
    final merchant = find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Merchant or expense name');
    await tester.scrollUntilVisible(merchant, 200, scrollable: reviewScroll);
    expect(tester.widget<TextField>(merchant).controller!.text, 'Corner Cafe');
    await tester.enterText(merchant, 'Corrected cafe');
    tester.testTextInput.hide();
    await tester.scrollUntilVisible(find.text('1,234.56'), 200, scrollable: reviewScroll);
    await tester.tap(find.text('1,234.56'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byTooltip('Edit item 1'), 200, scrollable: reviewScroll);
    await tester.tap(find.byTooltip('Edit item 1'));
    await tester.pumpAndSettle();
    final itemCategory = find.descendant(of: find.byType(ItemEditor), matching: find.widgetWithText(ListTile, 'Food & drinks')).first;
    expect(itemCategory, findsOneWidget);
    await tester.ensureVisible(itemCategory);
    await tester.tap(itemCategory);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shopping').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Oat milk').last);
    await tester.tap(find.text('Oat milk').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save item'));
    await tester.tap(find.text('Save item'));
    await tester.pumpAndSettle();
    expect(repository.saved, isEmpty);
    await tester.tap(find.text('Save expense'));
    await tester.pumpAndSettle();
    expect(repository.saved.values.single.merchant, 'Corrected cafe');
    expect(repository.saved.values.single.lines.single.category, ExpenseCategory.shopping);
    expect(repository.saved.values.single.lines.single.subItems.single['category'], 'groceries');
    expect(repository.saved.values.single.category, ExpenseCategory.dining);
    expect(tester.takeException(), isNull);
  });
}
