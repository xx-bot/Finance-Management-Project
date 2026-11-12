import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/expense.dart';
import '../../models/receipt_draft.dart';
import '../../state/ledger_state.dart';
import '../components/common.dart';
import '../theme.dart';
import 'review_screen.dart';

class ExpenseDetailScreen extends StatelessWidget {
  const ExpenseDetailScreen({super.key, required this.state, required this.expense});
  final LedgerState state;
  final Expense expense;

  Future<void> _delete(BuildContext context, Expense value) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Delete this expense?'),
      content: Text('${value.merchant} and its receipt will be removed from ${value.isDemo ? 'the sample preview' : 'this device'}.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: PocketColors.red)))],
    ));
    if (confirmed != true) return;
    try {
      await state.remove(value);
      if (context.mounted) Navigator.pop(context);
    } on Object {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not delete this expense. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: state, builder: (context, _) {
    final current = state.expenses.where((item) => item.id == expense.id).firstOrNull ?? expense;
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Expense details'), centerTitle: true,
        actions: [PopupMenuButton<String>(onSelected: (action) {
          if (action == 'edit') {
            Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(state: state, draft: ReceiptDraft.fromExpense(current))));
          } else { _delete(context, current); }
        }, itemBuilder: (_) => [const PopupMenuItem(value: 'edit', child: Text('Edit expense')),
          const PopupMenuItem(value: 'delete', child: Text('Delete expense'))])]),
      body: ListView(padding: const EdgeInsets.fromLTRB(22, 10, 22, 30), children: [
        Center(child: CategoryIcon(current.category, size: 64)), const SizedBox(height: 16),
        Text(current.merchant, textAlign: TextAlign.center, style: theme.headlineSmall), const SizedBox(height: 8),
        Text(DateFormat('d MMMM yyyy').format(current.date), textAlign: TextAlign.center, style: theme.bodySmall),
        const SizedBox(height: 12), FittedBox(fit: BoxFit.scaleDown,
          child: Text(current.currency.format(current.totalMinor), style: theme.headlineLarge)),
        const SizedBox(height: 12), Center(child: Tag(current.isDemo ? 'Sample expense' : current.status == 'reviewed_difference' ? 'Difference reviewed' : 'Reviewed',
          color: current.status == 'reviewed_difference' ? PocketColors.amber : PocketColors.green)),
        const SizedBox(height: 26), ReceiptPreview(path: current.imagePath, merchant: current.merchant,
          lines: current.lines.map((line) => (line.description, current.currency.format(line.amountMinor))).toList(),
          total: current.currency.format(current.totalMinor), sample: current.isDemo),
        const SizedBox(height: 24), SectionHeading('Purchased items', action: 'Edit', onAction: () => Navigator.push(context,
          MaterialPageRoute<void>(builder: (_) => ReviewScreen(state: state, draft: ReceiptDraft.fromExpense(current))))),
        if (current.lines.isEmpty) const PocketCard(child: Text('This expense was recorded using its final total.')),
        for (final line in current.lines) Padding(padding: const EdgeInsets.only(bottom: 9), child: PocketCard(
          padding: const EdgeInsets.all(15), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CategoryIcon(line.category, size: 35), const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.description, style: theme.titleSmall), const SizedBox(height: 4),
              Text([line.category.label, if (line.quantity != null) 'Qty ${line.quantity}'].join(' · '), style: theme.bodySmall),
              if (line.subItems.isNotEmpty) Text(line.subItems.map((value) => value['description'] ?? '').join(' · '), style: theme.bodySmall),
            ])),
            const SizedBox(width: 8), Text(current.currency.format(line.amountMinor), style: theme.titleSmall),
          ]))),
        for (final adjustment in current.adjustments) ListTile(contentPadding: EdgeInsets.zero,
          title: Text(adjustment.label), trailing: Text(current.currency.format(adjustment.amountMinor))),
        if (current.note.isNotEmpty) ...[
          const SizedBox(height: 18), const SectionHeading('A little context'), PocketCard(child: Text(current.note)),
        ],
        if (current.status == 'reviewed_difference') Padding(padding: const EdgeInsets.only(top: 20),
          child: PocketCard(color: PocketColors.peach, child: Text('The final total was confirmed with a ${current.currency.format(current.difference.abs())} difference from the item breakdown.'))),
      ]),
    );
  });
}
