import 'package:flutter/material.dart';

import '../../state/ledger_state.dart';
import '../components/charts.dart';
import '../components/common.dart';
import '../theme.dart';

class InsightsScreen extends StatelessWidget {
  const InsightsScreen({super.key, required this.state});
  final LedgerState state;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final categories = state.categoryTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final days = state.monthExpenses.map((expense) => DateUtils.dateOnly(expense.date)).toSet().length;
    return ListView(padding: const EdgeInsets.fromLTRB(22, 24, 22, 30), children: [
      Row(children: [Expanded(child: Text('Your bigger picture', style: theme.headlineMedium)),
        if (state.previewMode) const Tag('Sample data')]),
      const SizedBox(height: 8), MonthSelector(state),
      const SizedBox(height: 18),
      if (state.monthExpenses.isEmpty) const EmptyState(title: 'Insights start here',
        message: 'Add a few expenses and we’ll turn them into a clearer view of your spending.', icon: Icons.insights_rounded)
      else ...[
        PocketCard(child: Column(children: [
          Text('SPENDING BY CATEGORY', style: theme.bodySmall?.copyWith(letterSpacing: 1.3)),
          const SizedBox(height: 24),
          CategoryRing(state.categoryTotals, size: 190, center: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${categories.length}', style: theme.headlineLarge), Text('categories', style: theme.bodySmall),
          ])),
          const SizedBox(height: 22), Text(state.currency.format(state.monthlyTotal), style: theme.headlineMedium),
          Text('${state.monthExpenses.length} expenses this month', style: theme.bodySmall),
          const SizedBox(height: 20), const Divider(), const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Column(children: [Text('Per spending day', style: theme.bodySmall), const SizedBox(height: 4),
              Text(state.currency.format(state.monthlyTotal ~/ (days == 0 ? 1 : days)), style: theme.titleSmall)])),
            Container(width: 1, height: 35, color: PocketColors.line),
            Expanded(child: Column(children: [Text('Largest category', style: theme.bodySmall), const SizedBox(height: 4),
              Text(categories.first.key.label, style: theme.titleSmall)])),
          ]),
        ])),
        const SizedBox(height: 24), const SectionHeading('A closer look'),
        PocketCard(child: Column(children: [
          for (var index = 0; index < categories.length; index++) Padding(
            padding: EdgeInsets.only(bottom: index == categories.length - 1 ? 0 : 22),
            child: Row(children: [
              CategoryIcon(categories[index].key, size: 40), const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Expanded(child: Text(categories[index].key.label, style: theme.titleSmall)),
                  Text(state.currency.format(categories[index].value), style: theme.titleSmall)]),
                const SizedBox(height: 6), Row(children: [
                  Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(5), child: LinearProgressIndicator(
                    value: state.monthlyTotal == 0 ? 0 : categories[index].value / state.monthlyTotal,
                    color: categories[index].key.color, backgroundColor: PocketColors.canvas, minHeight: 5))),
                  const SizedBox(width: 10), Text('${state.monthlyTotal == 0 ? 0 : (categories[index].value / state.monthlyTotal * 100).round()}%', style: theme.bodySmall),
                ]),
              ])),
            ]),
          ),
        ])),
        const SizedBox(height: 22),
        PocketCard(color: PocketColors.lime, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lightbulb_outline_rounded, color: PocketColors.green), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('A small check-in goes a long way.', style: theme.titleSmall), const SizedBox(height: 5),
            Text('${categories.first.key.label} makes up ${(state.monthlyTotal == 0 ? 0 : categories.first.value / state.monthlyTotal * 100).round()}% of your spending. '
                'Use this view to make your next month a little more intentional.', style: theme.bodyMedium),
          ])),
        ])),
        const SizedBox(height: 12), Text('Category totals allocate the final paid amount across items. Taxes and discounts are shared proportionally.',
            textAlign: TextAlign.center, style: theme.bodySmall),
      ],
    ]);
  }
}
