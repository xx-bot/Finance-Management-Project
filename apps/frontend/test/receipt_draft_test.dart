import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_ledger/core/money.dart';
import 'package:pocket_ledger/models/expense.dart';
import 'package:pocket_ledger/models/receipt_draft.dart';

import 'support.dart';

void main() {
  test('a malformed or unconfirmed amount cannot be saved', () {
    final draft = validDraft()..numberStyle = null;
    expect(() => draft.toExpense(id: '1'), throwsFormatException);
    draft.numberStyle = NumberStyle.international;
    draft.total = '3,26000.00';
    expect(() => draft.toExpense(id: '1'), throwsFormatException);
  });

  test('reconcile tax and discounts without recalculating printed item values', () {
    final draft = validDraft()
      ..total = '13.00'
      ..adjustments.addAll([DraftAdjustment('Tax', '2.00'), DraftAdjustment('Discount', '-1.00')]);
    expect(draft.errors, isEmpty);
    final expense = draft.toExpense(id: '1');
    expect(expense.lines.single.amountMinor, 1200);
    expect(expense.totalMinor, 1300);
    expect(expense.difference, 0);
  });

  test('a receipt discrepancy needs explicit review', () {
    final draft = validDraft()..total = '13.00';
    expect(() => draft.toExpense(id: '1'), throwsFormatException);
    draft.mismatchReviewed = true;
    expect(draft.toExpense(id: '1').status, 'reviewed_difference');
  });

  test('no item amounts or final totals are inferred', () {
    final draft = validDraft()..total = '';
    expect(draft.totalMinor, isNull);
    expect(() => draft.toExpense(id: '1'), throwsFormatException);
    draft.total = '12.00';
    draft.lines.single.amount = '';
    expect(() => draft.toExpense(id: '1'), throwsFormatException);
    draft.lines.clear();
    expect(() => draft.toExpense(id: '1'), throwsFormatException);
    draft.totalOnlyConfirmed = true;
    expect(draft.toExpense(id: '1').totalMinor, 1200);
  });

  test('extraction retains printed strings and nested modifiers for review', () {
    final draft = ReceiptDraft.fromExtraction({
      'receipt': {
        'items': [{
          'description': 'Coffee', 'quantity': '1x', 'unit_price': null,
          'line_total': '20.000',
          'sub_items': [{
            'description': 'Oat milk', 'quantity': null, 'unit_price': null,
            'line_total': '2.000', 'sub_items': [],
          }],
        }],
        'total': '22.000',
      },
    }, LedgerCurrency.idr);
    expect(draft.total, '22.000');
    expect(draft.numberStyle, isNull);
    expect(draft.merchant, isEmpty);
    expect(draft.lines.single.quantity, '1x');
    expect(draft.lines.single.unitPrice, isEmpty);
    expect(draft.lines.single.subItems.single['line_total'], '2.000');
    expect(draft.lines.single.category, ExpenseCategory.other);
    expect(draft.errors, isNotEmpty);
  });

  test('category allocations include adjustments and exactly sum to paid total', () {
    final draft = validDraft()
      ..total = '10.01'
      ..lines.clear()
      ..lines.addAll([
        DraftLine(description: 'A', amount: '5.00', category: ExpenseCategory.groceries),
        DraftLine(description: 'B', amount: '5.00', category: ExpenseCategory.household),
      ])
      ..adjustments.add(DraftAdjustment('Rounding', '0.01'));
    final expense = draft.toExpense(id: '1');
    expect(expense.allocations.values.reduce((a, b) => a + b), 1001);
    expect(expense.allocations[ExpenseCategory.groceries], 501);
    expect(expense.allocations[ExpenseCategory.household], 500);
    expect(Expense.fromJson(expense.toJson()).allocations, expense.allocations);
  });
}
