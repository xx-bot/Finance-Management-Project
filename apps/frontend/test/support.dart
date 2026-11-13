import 'dart:typed_data';

import 'package:pocket_ledger/core/money.dart';
import 'package:pocket_ledger/data/ledger_repository.dart';
import 'package:pocket_ledger/models/expense.dart';
import 'package:pocket_ledger/models/receipt_draft.dart';
import 'package:pocket_ledger/services/receipt_service.dart';
import 'package:pocket_ledger/services/connection_store.dart';

class MemoryConnectionStore implements ConnectionStore {
  String? value;
  bool failWrites = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    if (failWrites) throw StateError('Secure storage unavailable');
    value = next;
  }
  @override
  Future<void> clear() async { value = null; }
}

class MemoryLedgerRepository implements LedgerRepository {
  final Map<String, Expense> saved = {};
  final Map<String, String> preferences = {};
  int imagesSaved = 0;
  bool failSave = false;
  @override
  Future<void> open() async {}
  @override
  Future<void> close() async {}
  @override
  Future<List<Expense>> loadExpenses() async => saved.values.toList();
  @override
  Future<Map<String, String>> loadPreferences() async => Map.of(preferences);
  @override
  Future<void> setPreference(String key, String value) async { preferences[key] = value; }
  @override
  Future<void> saveExpense(Expense expense) async {
    if (failSave) throw StateError('Storage unavailable');
    saved[expense.id] = expense;
  }
  @override
  Future<void> deleteExpense(String id) async { saved.remove(id); }
  @override
  Future<String> saveReceiptImage(Uint8List bytes, String id, String filename) async {
    imagesSaved++;
    return '/receipts/$id.jpg';
  }
}

class OfflineReceiptService implements ReceiptService {
  @override
  bool get isConfigured => false;
  @override
  void close() {}
  @override
  Future<ReceiptDraft> extract(ReceiptPhoto photo, LedgerCurrency currency) async =>
      throw const ReceiptServiceException('Not connected');
}

ReceiptDraft validDraft({LedgerCurrency currency = LedgerCurrency.idr}) => ReceiptDraft(
  currency: currency,
  date: DateTime.now(),
  merchant: 'Corner shop',
  numberStyle: NumberStyle.international,
  total: '12.00',
  lines: [DraftLine(description: 'Coffee', amount: '12.00', category: ExpenseCategory.dining)],
);
