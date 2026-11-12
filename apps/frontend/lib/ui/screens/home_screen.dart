import 'package:flutter/material.dart';

import '../../models/expense.dart';
import '../../state/ledger_state.dart';
import '../components/charts.dart';
import '../components/common.dart';
import '../theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.state, required this.onScan, required this.onManual,
    required this.onExpenses, required this.onInsights, required this.onSettings, required this.onExpense});
  final LedgerState state;
  final VoidCallback onScan, onManual, onExpenses, onInsights, onSettings;
  final ValueChanged<Expense> onExpense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final categories = state.categoryTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final recent = state.monthExpenses.take(4).toList();
    return ListView(padding: const EdgeInsets.fromLTRB(22, 14, 22, 28), children: [
      Row(children: [
        Container(width: 38, height: 38, alignment: Alignment.center,
          decoration: BoxDecoration(color: PocketColors.ink, borderRadius: BorderRadius.circular(13)),
          child: const Icon(Icons.spa_outlined, color: PocketColors.lime, size: 23)),
        const SizedBox(width: 9), Text('pocket.', style: theme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(), if (state.previewMode) const Tag('Sample data'), const SizedBox(width: 8),
        IconButton(onPressed: onSettings, tooltip: 'Settings', icon: const Icon(Icons.tune_rounded, size: 22)),
      ]),
      const SizedBox(height: 25),
      Text('A little clarity,\nevery day.', style: theme.headlineLarge),
      const SizedBox(height: 9),
      Text('Your spending, with the bigger picture.', style: theme.bodyMedium?.copyWith(color: PocketColors.muted)),
      const SizedBox(height: 22),
      PocketCard(color: PocketColors.lime, padding: const EdgeInsets.fromLTRB(23, 17, 23, 22), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: MonthSelector(state)), Tag(state.currency.code)]),
          const SizedBox(height: 8),
          Text('Spent this month', style: theme.bodyMedium), const SizedBox(height: 7),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
            child: Text(state.currency.format(state.monthlyTotal), style: theme.headlineLarge?.copyWith(fontSize: 38))),
          const SizedBox(height: 7), SpendingSparkline(state.dailyTotals), const SizedBox(height: 18),
          ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(
            value: state.budgetFraction, minHeight: 6, backgroundColor: Colors.white.withAlpha(150),
            color: state.remaining < 0 ? PocketColors.amber : PocketColors.green,
          )),
          const SizedBox(height: 10), Row(children: [
            Expanded(child: Text(state.remaining >= 0
                ? '${state.currency.format(state.remaining)} left to spend'
                : '${state.currency.format(state.remaining.abs())} over budget', style: theme.bodySmall?.copyWith(color: PocketColors.ink))),
            Text('of ${state.currency.format(state.budget, compact: true)}', style: theme.bodySmall?.copyWith(color: PocketColors.green)),
          ]),
        ],
      )),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: FilledButton.icon(onPressed: onScan, icon: const Icon(Icons.document_scanner_outlined, size: 19), label: const Text('Scan receipt'))),
        const SizedBox(width: 10),
        Expanded(child: OutlinedButton.icon(onPressed: onManual, icon: const Icon(Icons.add_rounded, size: 19), label: const Text('Add expense'))),
      ]),
      if (state.reviewExpenses.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 18), child: InkWell(
        onTap: () => onExpense(state.reviewExpenses.first), borderRadius: BorderRadius.circular(18),
        child: PocketCard(color: PocketColors.peach, padding: const EdgeInsets.all(16), child: Row(children: [
          const Icon(Icons.fact_check_outlined, color: PocketColors.amber), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${state.reviewExpenses.length} receipt${state.reviewExpenses.length == 1 ? '' : 's'} to review', style: theme.titleSmall),
            Text('A quick check keeps your numbers right.', style: theme.bodySmall?.copyWith(color: PocketColors.amber)),
          ])),
          const Icon(Icons.arrow_forward_rounded, size: 19, color: PocketColors.amber),
        ])),
      )),
      const SizedBox(height: 20), SectionHeading('Where it went', action: 'Insights', onAction: onInsights),
      if (categories.isEmpty)
        const PocketCard(child: Text('Your category breakdown will appear after you save an expense.'))
      else PocketCard(child: Column(children: [
        for (var index = 0; index < categories.take(3).length; index++) Padding(
          padding: EdgeInsets.only(bottom: index < categories.take(3).length - 1 ? 17 : 0),
          child: Row(children: [
            CategoryIcon(categories[index].key, size: 36), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text(categories[index].key.label, style: theme.titleSmall)),
                Text(state.currency.format(categories[index].value), style: theme.titleSmall)]),
              const SizedBox(height: 7), ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
                value: state.monthlyTotal == 0 ? 0 : categories[index].value / state.monthlyTotal,
                minHeight: 4, color: categories[index].key.color, backgroundColor: PocketColors.canvas,
              )),
            ])),
          ]),
        ),
      ])),
      const SizedBox(height: 20), SectionHeading('Recent expenses', action: 'See all', onAction: onExpenses),
      if (recent.isEmpty)
        EmptyState(title: 'Start with one receipt', message: 'Small steps make a clearer picture.', action: 'Add your first expense', onAction: onManual)
      else PocketCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2), child: Column(children: [
        for (var index = 0; index < recent.length; index++) ...[
          ExpenseTile(expense: recent[index], onTap: () => onExpense(recent[index])),
          if (index < recent.length - 1) const Divider(),
        ],
      ])),
      if (state.previewMode) Padding(padding: const EdgeInsets.only(top: 14), child: Text(
        'You’re exploring sample data. Your own expenses stay separate.', textAlign: TextAlign.center, style: theme.bodySmall)),
    ]);
  }
}
