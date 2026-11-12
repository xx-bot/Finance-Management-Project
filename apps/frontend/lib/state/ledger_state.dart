import 'package:flutter/foundation.dart';

import '../core/money.dart';
import '../data/ledger_repository.dart';
import '../data/sample_data.dart';
import '../models/expense.dart';
import '../models/receipt_draft.dart';

class LedgerState extends ChangeNotifier {
  LedgerState(this.repository);
  final LedgerRepository repository;
  final List<Expense> _personal = [];
  final List<Expense> _samples = sampleExpenses();
  final Map<String, int> _budgets = {'IDR': 300000000, 'MYR': 200000, 'USD': 150000};
  bool previewMode = true;
  LedgerCurrency currency = LedgerCurrency.idr;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  Future<void> initialize() async {
    await repository.open();
    final saved = await repository.loadExpenses();
    final preferences = await repository.loadPreferences();
    _personal..clear()..addAll(saved);
    previewMode = preferences['preview'] != 'false';
    currency = LedgerCurrency.fromCode(preferences['currency'] ?? 'IDR');
    for (final value in LedgerCurrency.values) {
      final budget = int.tryParse(preferences['budget_${value.code}'] ?? '');
      if (budget != null && budget > 0) _budgets[value.code] = budget;
    }
  }

  List<Expense> get expenses => (previewMode ? _samples : _personal)
      .where((expense) => expense.currency == currency).toList()
    ..sort((a, b) => b.date.compareTo(a.date));
  List<Expense> get monthExpenses => expenses
      .where((expense) => expense.date.year == month.year && expense.date.month == month.month).toList();
  List<Expense> get reviewExpenses => expenses.where((expense) => expense.needsReview).toList();
  int get monthlyTotal => monthExpenses.fold(0, (sum, expense) => sum + expense.totalMinor);
  int get budget => _budgets[currency.code]!;
  int get remaining => budget - monthlyTotal;
  double get budgetFraction => (monthlyTotal / budget).clamp(0.0, 1.0).toDouble();

  Map<ExpenseCategory, int> get categoryTotals {
    final result = <ExpenseCategory, int>{};
    for (final expense in monthExpenses) {
      for (final entry in expense.allocations.entries) {
        result.update(entry.key, (value) => value + entry.value, ifAbsent: () => entry.value);
      }
    }
    return result;
  }

  List<int> get dailyTotals {
    final days = DateTime(month.year, month.month + 1, 0).day;
    final result = List<int>.filled(days, 0);
    for (final expense in monthExpenses) {
      result[expense.date.day - 1] += expense.totalMinor;
    }
    return result;
  }

  void setMonth(DateTime value) {
    month = DateTime(value.year, value.month);
    notifyListeners();
  }

  Future<void> setPreview(bool value) async {
    await repository.setPreference('preview', value.toString());
    previewMode = value;
    notifyListeners();
  }

  Future<void> setCurrency(LedgerCurrency value) async {
    await repository.setPreference('currency', value.code);
    currency = value;
    notifyListeners();
  }

  Future<void> setBudget(int value) async {
    if (value <= 0) throw const FormatException('Budget must be greater than zero.');
    await repository.setPreference('budget_${currency.code}', value.toString());
    _budgets[currency.code] = value;
    notifyListeners();
  }

  Future<Expense> saveDraft(ReceiptDraft draft) async {
    if (draft.errors.isNotEmpty) throw FormatException(draft.errors.first);
    final id = draft.originalId ?? DateTime.now().microsecondsSinceEpoch.toString();
    draft.originalId = id;
    String? imagePath;
    if (!draft.isDemo && draft.imageBytes != null && draft.savedImagePath == null) {
      imagePath = await repository.saveReceiptImage(draft.imageBytes!, id, draft.imageName ?? 'receipt.jpg');
      // Retain the copied path if a subsequent database write fails and the user retries.
      draft.savedImagePath = imagePath;
    }
    final expense = draft.toExpense(id: id, imagePath: imagePath);
    if (draft.isDemo) {
      _samples.removeWhere((item) => item.id == id);
      _samples.add(expense);
      await setPreview(true);
    } else {
      await repository.saveExpense(expense);
      _personal.removeWhere((item) => item.id == id);
      _personal.add(expense);
      await repository.setPreference('preview', 'false');
      previewMode = false;
    }
    currency = expense.currency;
    await repository.setPreference('currency', currency.code);
    month = DateTime(expense.date.year, expense.date.month);
    notifyListeners();
    return expense;
  }

  Future<void> remove(Expense expense) async {
    if (expense.isDemo) {
      _samples.removeWhere((value) => value.id == expense.id);
    } else {
      await repository.deleteExpense(expense.id);
      _personal.removeWhere((value) => value.id == expense.id);
    }
    notifyListeners();
  }

  String exportCsv() {
    String quote(String text) => '"${text.replaceAll('"', '""')}"';
    final rows = ['Date,Merchant,Category,Total,Currency,Status'];
    for (final expense in expenses) {
      rows.add([
        expense.date.toIso8601String().split('T').first,
        expense.merchant, expense.category.label,
        printedMinor(expense.totalMinor, NumberStyle.international),
        expense.currency.code, expense.status,
      ].map(quote).join(','));
    }
    return rows.join('\n');
  }
}
