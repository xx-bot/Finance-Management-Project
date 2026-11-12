import '../core/money.dart';

enum ExpenseCategory {
  groceries('Groceries'),
  dining('Food & drinks'),
  transport('Transport'),
  shopping('Shopping'),
  household('Home & bills'),
  health('Health'),
  education('Learning'),
  other('Other');

  const ExpenseCategory(this.label);
  final String label;

  static ExpenseCategory fromName(String? name) => values.firstWhere(
        (category) => category.name == name,
        orElse: () => other,
      );
}

class ExpenseLine {
  const ExpenseLine({
    required this.description,
    required this.amountMinor,
    required this.category,
    this.quantity,
    this.unitPrice,
    this.subItems = const [],
  });

  final String description;
  final int amountMinor;
  final ExpenseCategory category;
  final String? quantity;
  final String? unitPrice;
  final List<Map<String, dynamic>> subItems;

  Map<String, dynamic> toJson() => {
        'description': description,
        'amount_minor': amountMinor,
        'category': category.name,
        'quantity': quantity,
        'unit_price': unitPrice,
        'sub_items': subItems,
      };

  factory ExpenseLine.fromJson(Map<String, dynamic> value) => ExpenseLine(
        description: value['description'] as String,
        amountMinor: value['amount_minor'] as int,
        category: ExpenseCategory.fromName(value['category'] as String?),
        quantity: value['quantity'] as String?,
        unitPrice: value['unit_price'] as String?,
        subItems: (value['sub_items'] as List<dynamic>? ?? [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(),
      );
}

class ExpenseAdjustment {
  const ExpenseAdjustment(this.label, this.amountMinor);
  final String label;
  final int amountMinor;
  Map<String, dynamic> toJson() => {'label': label, 'amount_minor': amountMinor};
  factory ExpenseAdjustment.fromJson(Map<String, dynamic> value) =>
      ExpenseAdjustment(value['label'] as String, value['amount_minor'] as int);
}

class Expense {
  const Expense({
    required this.id,
    required this.merchant,
    required this.date,
    required this.currency,
    required this.totalMinor,
    required this.category,
    required this.lines,
    this.adjustments = const [],
    this.imagePath,
    this.note = '',
    this.status = 'verified',
    this.isDemo = false,
  });

  final String id;
  final String merchant;
  final DateTime date;
  final LedgerCurrency currency;
  final int totalMinor;
  final ExpenseCategory category;
  final List<ExpenseLine> lines;
  final List<ExpenseAdjustment> adjustments;
  final String? imagePath;
  final String note;
  final String status;
  final bool isDemo;

  bool get needsReview => status == 'needs_review';
  int get itemSubtotal => lines.fold(0, (sum, line) => sum + line.amountMinor);
  int get adjustmentTotal =>
      adjustments.fold(0, (sum, adjustment) => sum + adjustment.amountMinor);
  int get difference => totalMinor - itemSubtotal - adjustmentTotal;

  /// Allocate the final paid amount across item categories, including adjustments.
  /// Largest remainders ensure integer allocations add to the receipt total.
  Map<ExpenseCategory, int> get allocations {
    final weights = <ExpenseCategory, int>{};
    for (final line in lines) {
      weights.update(line.category, (value) => value + line.amountMinor,
          ifAbsent: () => line.amountMinor);
    }
    final subtotal = weights.values.fold(0, (sum, value) => sum + value);
    if (subtotal <= 0) return {category: totalMinor};
    final denominator = BigInt.from(subtotal);
    final products = weights.map((key, value) => MapEntry(key, BigInt.from(totalMinor) * BigInt.from(value)));
    final result = <ExpenseCategory, int>{};
    for (final entry in weights.entries) {
      result[entry.key] = (products[entry.key]! ~/ denominator).toInt();
    }
    final ordered = weights.keys.toList()
      ..sort((a, b) {
        final comparison = (products[b]! % denominator)
            .compareTo(products[a]! % denominator);
        return comparison == 0 ? a.index.compareTo(b.index) : comparison;
      });
    var remainder = totalMinor - result.values.fold(0, (sum, value) => sum + value);
    for (final category in ordered) {
      if (remainder == 0) break;
      result[category] = result[category]! + 1;
      remainder--;
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'merchant': merchant,
        'date': date.toIso8601String(),
        'currency': currency.code,
        'total_minor': totalMinor,
        'category': category.name,
        'lines': lines.map((line) => line.toJson()).toList(),
        'adjustments': adjustments.map((value) => value.toJson()).toList(),
        'image_path': imagePath,
        'note': note,
        'status': status,
      };

  factory Expense.fromJson(Map<String, dynamic> value) => Expense(
        id: value['id'] as String,
        merchant: value['merchant'] as String,
        date: DateTime.parse(value['date'] as String),
        currency: LedgerCurrency.fromCode(value['currency'] as String),
        totalMinor: value['total_minor'] as int,
        category: ExpenseCategory.fromName(value['category'] as String?),
        lines: (value['lines'] as List<dynamic>)
            .map((line) => ExpenseLine.fromJson(Map<String, dynamic>.from(line as Map)))
            .toList(),
        adjustments: (value['adjustments'] as List<dynamic>? ?? [])
            .map((item) => ExpenseAdjustment.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        imagePath: value['image_path'] as String?,
        note: value['note'] as String? ?? '',
        status: value['status'] as String? ?? 'verified',
      );
}
