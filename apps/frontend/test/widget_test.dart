import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/app.dart';
import 'package:pocket_ledger/ui/screens/review_screen.dart';

import 'support.dart';

void main() {
  testWidgets('sample scan can be reviewed and saved without calling a backend', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = MemoryLedgerRepository();
    await tester.pumpWidget(PocketApp(repository: repository, receiptService: OfflineReceiptService()));
    await tester.pumpAndSettle();
    expect(find.text('pocket.').first, findsOneWidget);
    expect(find.text('Sample data').first, findsOneWidget);
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    final sample = find.text('Try a sample receipt');
    await tester.scrollUntilVisible(sample, 250);
    await tester.tap(sample);
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);
    await tester.tap(find.text('Save sample expense'));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsNothing);
    expect(repository.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
