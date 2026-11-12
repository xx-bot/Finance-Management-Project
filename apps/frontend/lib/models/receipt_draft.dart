import 'dart:typed_data';

import '../core/money.dart';
import 'expense.dart';

class DraftLine {
  DraftLine({
    this.description = '',
    this.quantity = '',
    this.unitPrice = '',
    this.amount = '',
    this.category = ExpenseCategory.other,
    this.subItems = const [],
  });
  String description;
  String quantity;
  String unitPrice;
  String amount;
  ExpenseCategory category;
  List<Map<String, dynamic>> subItems;
}

class DraftAdjustment {
  DraftAdjustment(this.label, this.amount);
  String label;
  String amount;
}

class ReceiptDraft {
  ReceiptDraft({
    required this.currency,
    required this.date,
    this.merchant = '',
    this.total = '',
    this.category = ExpenseCategory.other,
    this.numberStyle,
    this.isDemo = false,
    this.totalOnlyConfirmed = false,
    this.originalId,
    this.savedImagePath,
    this.imageBytes,
    this.imageName,
    List<DraftLine>? lines,
    List<DraftAdjustment>? adjustments,
    this.note = '',
  })  : lines = lines ?? [],
        adjustments = adjustments ?? [];

  LedgerCurrency currency;
  DateTime date;
  String merchant;
  String total;
  ExpenseCategory category;
  NumberStyle? numberStyle;
  bool isDemo;
  bool totalOnlyConfirmed;
  bool mismatchReviewed = false;
  String? originalId;
  String? savedImagePath;
  Uint8List? imageBytes;
  String? imageName;
  List<DraftLine> lines;
  List<DraftAdjustment> adjustments;
  String note;

  int? tryAmount(String value) {
    if (numberStyle == null || value.trim().isEmpty) return null;
    try {
      return parseMinor(value, numberStyle!);
    } on FormatException {
      return null;
    }
  }

  int? get totalMinor => tryAmount(total);
  int? get itemSubtotal {
    var result = 0;
    for (final line in lines) {
      final amount = tryAmount(line.amount);
      if (amount == null) return null;
      result += amount;
    }
    return result;
  }

  int? get adjustmentTotal {
    var result = 0;
    for (final adjustment in adjustments) {
      final amount = tryAmount(adjustment.amount);
      if (amount == null) return null;
      result += amount;
    }
    return result;
  }

  int? get difference {
    if (totalMinor == null || itemSubtotal == null || adjustmentTotal == null) return null;
    return totalMinor! - itemSubtotal! - adjustmentTotal!;
  }

  List<String> get errors {
    final result = <String>[];
    if (merchant.trim().isEmpty) result.add('Add a merchant or expense name.');
    if (numberStyle == null) result.add('Confirm the number format printed on the receipt.');
    if (totalMinor == null || totalMinor! < 0) result.add('Enter a valid, nonnegative final total.');
    if (lines.isEmpty && !totalOnlyConfirmed) result.add('Add items or confirm recording the total only.');
    for (var index = 0; index < lines.length; index++) {
      if (lines[index].description.trim().isEmpty) result.add('Item ${index + 1} needs a name.');
      final amount = tryAmount(lines[index].amount);
      if (amount == null || amount < 0) result.add('Check the amount for item ${index + 1}.');
    }
    for (final adjustment in adjustments) {
      if (tryAmount(adjustment.amount) == null) result.add('Check the ${adjustment.label.toLowerCase()} amount.');
    }
    if (lines.isNotEmpty && difference != null && difference != 0 && !mismatchReviewed) {
      result.add('Resolve the amount difference or confirm you have reviewed it.');
    }
    return result;
  }

  Expense toExpense({required String id, String? imagePath}) {
    if (errors.isNotEmpty) throw FormatException(errors.first);
    return Expense(
      id: id,
      merchant: merchant.trim(),
      date: date,
      currency: currency,
      totalMinor: totalMinor!,
      category: category,
      lines: lines.map((line) => ExpenseLine(
        description: line.description.trim(),
        quantity: line.quantity.trim().isEmpty ? null : line.quantity.trim(),
        unitPrice: line.unitPrice.trim().isEmpty ? null : line.unitPrice.trim(),
        amountMinor: tryAmount(line.amount)!,
        category: line.category,
        subItems: line.subItems,
      )).toList(),
      adjustments: adjustments.map((value) => ExpenseAdjustment(value.label, tryAmount(value.amount)!)).toList(),
      imagePath: imagePath ?? savedImagePath,
      note: note.trim(),
      status: lines.isNotEmpty && difference != 0 ? 'reviewed_difference' : 'verified',
      isDemo: isDemo,
    );
  }

  factory ReceiptDraft.fromExpense(Expense expense) => ReceiptDraft(
    currency: expense.currency,
    date: expense.date,
    merchant: expense.merchant,
    total: printedMinor(expense.totalMinor, NumberStyle.international),
    category: expense.category,
    numberStyle: NumberStyle.international,
    isDemo: expense.isDemo,
    originalId: expense.id,
    savedImagePath: expense.imagePath,
    totalOnlyConfirmed: expense.lines.isEmpty,
    note: expense.note,
    lines: expense.lines.map((line) => DraftLine(
      description: line.description,
      quantity: line.quantity ?? '',
      unitPrice: line.unitPrice ?? '',
      amount: printedMinor(line.amountMinor, NumberStyle.international),
      category: line.category,
      subItems: line.subItems,
    )).toList(),
    adjustments: expense.adjustments.map((value) => DraftAdjustment(
      value.label, printedMinor(value.amountMinor, NumberStyle.international),
    )).toList(),
  );

  factory ReceiptDraft.fromExtraction(Map<String, dynamic> value, LedgerCurrency currency) {
    final raw = value['receipt'] is Map ? Map<String, dynamic>.from(value['receipt'] as Map) : value;
    if (raw['items'] is! List || !raw.containsKey('total') || (raw['total'] != null && raw['total'] is! String)) {
      throw const FormatException('The receipt service returned an unexpected result.');
    }
    String text(dynamic item) {
      if (item == null) return '';
      if (item is! String) throw const FormatException('Receipt fields must be printed strings.');
      return item;
    }
    void validateItem(dynamic entry, int depth) {
      const fields = ['description', 'quantity', 'unit_price', 'line_total'];
      if (depth > 16 || entry is! Map || entry['sub_items'] is! List || !fields.every(entry.containsKey)) {
        throw const FormatException('An extracted item could not be read.');
      }
      for (final field in fields) { text(entry[field]); }
      for (final child in entry['sub_items'] as List) { validateItem(child, depth + 1); }
    }
    return ReceiptDraft(
      currency: currency,
      date: DateTime.now(),
      total: text(raw['total']),
      lines: (raw['items'] as List).map((entry) {
        validateItem(entry, 0);
        return DraftLine(
          description: text(entry['description']),
          quantity: text(entry['quantity']),
          unitPrice: text(entry['unit_price']),
          amount: text(entry['line_total']),
          subItems: (entry['sub_items'] as List).map((item) => Map<String, dynamic>.from(item as Map)).toList(),
        );
      }).toList(),
    );
  }
}
