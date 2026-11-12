import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/expense.dart';
import '../../state/ledger_state.dart';
import '../components/common.dart';
import '../theme.dart';

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key, required this.state, required this.onExpense, required this.onManual});
  final LedgerState state;
  final ValueChanged<Expense> onExpense;
  final VoidCallback onManual;
  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  String _query = '';
  ExpenseCategory? _category;
  bool _reviewOnly = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final all = state.monthExpenses;
    final rows = all.where((expense) {
      final search = '${expense.merchant} ${expense.lines.map((line) => line.description).join(' ')}'.toLowerCase();
      return search.contains(_query.toLowerCase()) && (_category == null || expense.allocations.containsKey(_category))
          && (!_reviewOnly || expense.needsReview);
    }).toList();
    final filteredTotal = rows.fold(0, (sum, expense) => sum + expense.totalMinor);
    return ListView(padding: const EdgeInsets.fromLTRB(22, 24, 22, 30), children: [
      Row(children: [Expanded(child: Text('Expenses', style: Theme.of(context).textTheme.headlineMedium)),
        if (state.previewMode) const Tag('Sample data'),
        IconButton(onPressed: widget.onManual, tooltip: 'Add expense', icon: const Icon(Icons.add_rounded))]),
      const SizedBox(height: 8), MonthSelector(state), const SizedBox(height: 14),
      TextField(onChanged: (value) => setState(() => _query = value),
        decoration: const InputDecoration(hintText: 'Search merchants or items', prefixIcon: Icon(Icons.search_rounded, size: 21))),
      const SizedBox(height: 14),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        FilterChip(label: const Text('All expenses'), selected: _category == null && !_reviewOnly,
            onSelected: (_) => setState(() { _category = null; _reviewOnly = false; })),
        const SizedBox(width: 8),
        FilterChip(label: const Text('Needs review'), selected: _reviewOnly,
            onSelected: (value) => setState(() => _reviewOnly = value)),
        for (final category in ExpenseCategory.values) Padding(padding: const EdgeInsets.only(left: 8), child: FilterChip(
          label: Text(category.label), selected: _category == category,
          onSelected: (value) => setState(() => _category = value ? category : null),
        )),
      ])),
      const SizedBox(height: 22),
      Row(children: [Expanded(child: Text('${rows.length} expense${rows.length == 1 ? '' : 's'}', style: Theme.of(context).textTheme.bodySmall)),
        Text(state.currency.format(filteredTotal), style: Theme.of(context).textTheme.titleSmall)]),
      const SizedBox(height: 10),
      if (rows.isEmpty) EmptyState(title: all.isEmpty ? 'A fresh start' : 'Nothing found',
        message: all.isEmpty ? 'Save a receipt or add an expense to begin.' : 'Try another search or category.',
        action: all.isEmpty ? 'Add expense' : null, onAction: widget.onManual)
      else ...[
        for (var index = 0; index < rows.length; index++) ...[
          if (index == 0 || DateUtils.dateOnly(rows[index].date) != DateUtils.dateOnly(rows[index - 1].date))
            Padding(padding: const EdgeInsets.fromLTRB(1, 17, 1, 8), child: Text(
              DateUtils.isSameDay(rows[index].date, DateTime.now()) ? 'TODAY' : DateFormat('EEEE, d MMM').format(rows[index].date).toUpperCase(),
              style: const TextStyle(color: PocketColors.muted, fontSize: 10, letterSpacing: 1.1, fontWeight: FontWeight.w600))),
          PocketCard(padding: const EdgeInsets.symmetric(horizontal: 14), child: ExpenseTile(
              expense: rows[index], onTap: () => widget.onExpense(rows[index]))),
          const SizedBox(height: 7),
        ],
      ],
    ]);
  }
}
