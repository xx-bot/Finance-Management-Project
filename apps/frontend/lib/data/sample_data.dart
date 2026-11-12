import '../core/money.dart';
import '../models/expense.dart';
import '../models/receipt_draft.dart';

List<Expense> sampleExpenses([DateTime? clock]) {
  final now = clock ?? DateTime.now();
  Expense sample(String id, String merchant, int amount, ExpenseCategory category,
      int days, List<ExpenseLine> lines, {String status = 'verified'}) => Expense(
        id: 'sample-$id', merchant: merchant,
        date: DateTime(now.year, now.month, now.day).subtract(Duration(days: days)),
        currency: LedgerCurrency.idr, totalMinor: amount * 100, category: category,
        lines: lines, isDemo: true, status: status,
      );
  ExpenseLine line(String name, int amount, ExpenseCategory category) => ExpenseLine(
      description: name, amountMinor: amount * 100, category: category, quantity: '1');
  return [
    sample('coffee', 'Kopi Taman', 38000, ExpenseCategory.dining, 0,
        [line('Iced oat latte', 28000, ExpenseCategory.dining), line('Butter croissant', 10000, ExpenseCategory.dining)]),
    sample('market', 'Pasar Segar', 284500, ExpenseCategory.groceries, 1,
        [line('Weekly groceries', 284500, ExpenseCategory.groceries)]),
    sample('ride', 'Gojek', 23000, ExpenseCategory.transport, 1,
        [line('Ride home', 23000, ExpenseCategory.transport)]),
    sample('lunch', 'Sari Rasa Kitchen', 87500, ExpenseCategory.dining, 2,
        [line('Lunch for two', 87500, ExpenseCategory.dining)]),
    sample('home', 'Living Space', 189000, ExpenseCategory.household, 3,
        [line('Ceramic planter', 89000, ExpenseCategory.household), line('Desk lamp', 100000, ExpenseCategory.household)]),
    sample('review', 'Fresh Basket', 130500, ExpenseCategory.groceries, 4,
        [line('Fruit & vegetables', 126000, ExpenseCategory.groceries)], status: 'needs_review'),
    sample('book', 'Periplus', 149000, ExpenseCategory.education, 6,
        [line('A book for the weekend', 149000, ExpenseCategory.education)]),
    sample('bills', 'Home internet', 350000, ExpenseCategory.household, 8,
        [line('Monthly internet', 350000, ExpenseCategory.household)]),
    sample('last-month', 'Daily essentials', 690000, ExpenseCategory.groceries,
        now.day + 3, [line('Last month groceries', 690000, ExpenseCategory.groceries)]),
  ];
}

ReceiptDraft sampleReceipt() => ReceiptDraft(
      currency: LedgerCurrency.idr,
      date: DateTime.now(),
      merchant: 'Kopi Taman',
      total: '38,000',
      category: ExpenseCategory.dining,
      numberStyle: NumberStyle.international,
      isDemo: true,
      lines: [
        DraftLine(description: 'Iced oat latte', quantity: '1', unitPrice: '28,000',
            amount: '28,000', category: ExpenseCategory.dining),
        DraftLine(description: 'Butter croissant', quantity: '1', unitPrice: '10,000',
            amount: '10,000', category: ExpenseCategory.dining),
      ],
    );
