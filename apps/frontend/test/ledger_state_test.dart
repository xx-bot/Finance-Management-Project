import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/core/money.dart';
import 'package:pocket_ledger/data/sample_data.dart';
import 'package:pocket_ledger/state/ledger_state.dart';

import 'support.dart';

void main() {
  test('sample receipt saves stay out of persistent personal records', () async {
    final repository = MemoryLedgerRepository();
    final state = LedgerState(repository);
    await state.initialize();
    await state.saveDraft(sampleReceipt());
    expect(state.previewMode, isTrue);
    expect(repository.saved, isEmpty);
    expect(repository.imagesSaved, 0);
    await state.setPreview(false);
    expect(state.expenses, isEmpty);
    state.dispose();
  });

  test('real expenses persist, leave preview, and keep currencies separate', () async {
    final repository = MemoryLedgerRepository();
    final state = LedgerState(repository);
    await state.initialize();
    await state.saveDraft(validDraft());
    expect(state.previewMode, isFalse);
    expect(state.monthlyTotal, 1200);
    await state.saveDraft(validDraft(currency: LedgerCurrency.myr)..total = '24.00'..lines.single.amount = '24.00');
    expect(state.currency, LedgerCurrency.myr);
    expect(state.monthlyTotal, 2400);
    final reloaded = LedgerState(repository);
    await reloaded.initialize();
    expect(reloaded.currency, LedgerCurrency.myr);
    expect(reloaded.monthlyTotal, 2400);
    await reloaded.setCurrency(LedgerCurrency.idr);
    expect(reloaded.monthlyTotal, 1200);
    state.dispose();
    reloaded.dispose();
  });

  test('retry after a database failure reuses the receipt copy and ID', () async {
    final repository = MemoryLedgerRepository()..failSave = true;
    final state = LedgerState(repository);
    await state.initialize();
    final draft = validDraft()
      ..imageBytes = Uint8List.fromList([1, 2, 3])
      ..imageName = 'receipt.jpg';
    await expectLater(state.saveDraft(draft), throwsStateError);
    final id = draft.originalId;
    repository.failSave = false;
    await state.saveDraft(draft);
    await state.saveDraft(draft);
    expect(draft.originalId, id);
    expect(repository.saved.length, 1);
    expect(repository.imagesSaved, 1);
    expect(repository.saved.values.single.imagePath, '/receipts/$id.jpg');
    await state.initialize();
    expect(state.expenses.length, 1);
    state.dispose();
  });
}
