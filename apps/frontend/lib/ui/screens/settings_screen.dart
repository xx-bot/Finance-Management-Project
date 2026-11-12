import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../services/receipt_service.dart';
import '../../state/ledger_state.dart';
import '../components/common.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state, required this.receiptService});
  final LedgerState state;
  final ReceiptService receiptService;

  Future<void> _changePreview(BuildContext context, bool value) async {
    try { await state.setPreview(value); }
    on Object { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save this preference. Please try again.'))); }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(22, 24, 22, 30), children: [
      Text('Make it yours', style: theme.headlineMedium), const SizedBox(height: 8),
      Text('A calmer home for your everyday money.', style: theme.bodyMedium?.copyWith(color: PocketColors.muted)),
      const SizedBox(height: 26),
      PocketCard(color: PocketColors.lime, child: Row(children: [
        Container(width: 52, height: 52, decoration: BoxDecoration(color: PocketColors.ink, borderRadius: BorderRadius.circular(18)),
          child: const Icon(Icons.spa_outlined, color: PocketColors.lime, size: 29)),
        const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your personal pocket', style: theme.titleMedium),
          const SizedBox(height: 4), Text('Stored on this device', style: theme.bodySmall?.copyWith(color: PocketColors.green)),
        ])),
      ])),
      const SizedBox(height: 26), const SectionHeading('Your preferences'),
      PocketCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.payments_outlined), title: const Text('Display currency'),
          subtitle: const Text('Balances are kept separate; no conversion.'),
          trailing: DropdownButton<LedgerCurrency>(value: state.currency, underline: const SizedBox.shrink(),
            items: LedgerCurrency.values.map((value) => DropdownMenuItem(value: value, child: Text(value.code))).toList(),
            onChanged: (value) async {
              if (value == null) return;
              try { await state.setCurrency(value); }
              on Object { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not change currency.'))); }
            },
          )),
        const Divider(),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.donut_large_outlined), title: const Text('Monthly budget'),
          subtitle: Text(state.currency.format(state.budget)), trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true,
              builder: (_) => BudgetSheet(state: state))),
      ])),
      const SizedBox(height: 24), const SectionHeading('Your receipts'),
      PocketCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.cloud_outlined), title: const Text('Receipt scanning'),
          subtitle: Text(receiptService.isConfigured ? 'Ready to send photos for extraction' : 'Not connected yet. Sample scans are available.'),
          trailing: Icon(receiptService.isConfigured ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
              color: receiptService.isConfigured ? PocketColors.green : PocketColors.muted)),
        const Divider(),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.ios_share_rounded), title: const Text('Export expenses'),
          subtitle: Text('Copy ${state.currency.code} expenses as CSV'), trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: state.exportCsv()));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
              state.previewMode ? 'Sample expenses copied as CSV.' : 'Expenses copied as CSV.')));
          }),
      ])),
      const SizedBox(height: 24), const SectionHeading('Explore at your pace'),
      PocketCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero, title: const Text('Show sample data'),
        subtitle: const Text('Explore Pocket without changing your own expenses.'), value: state.previewMode,
        onChanged: (value) => _changePreview(context, value),
      )),
      if (state.previewMode) Padding(padding: const EdgeInsets.only(top: 16), child: OutlinedButton(
        onPressed: () => _changePreview(context, false), child: const Text('Start tracking my expenses'))),
      const SizedBox(height: 30),
      Text('pocket.', textAlign: TextAlign.center, style: theme.titleLarge?.copyWith(color: PocketColors.green)),
      const SizedBox(height: 6), Text('Small moments. A clearer picture.', textAlign: TextAlign.center, style: theme.bodySmall),
      const SizedBox(height: 6), Text('Receipts are sent to your configured service only when you request a scan.',
          textAlign: TextAlign.center, style: theme.bodySmall),
    ]);
  }
}

class BudgetSheet extends StatefulWidget {
  const BudgetSheet({super.key, required this.state});
  final LedgerState state;
  @override
  State<BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<BudgetSheet> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: printedMinor(widget.state.budget, NumberStyle.international));
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final value = parseMinor(_controller.text, NumberStyle.international);
      await widget.state.setBudget(value);
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() { _saving = false; _error = 'Enter a valid budget greater than zero.'; });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(22, 0, 22, MediaQuery.viewInsetsOf(context).bottom + 24),
    child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('A little room to spend', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8), const Text('Choose a monthly budget that feels right for you.'), const SizedBox(height: 22),
      TextField(controller: _controller, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: 'Monthly budget (${widget.state.currency.code})',
            helperText: 'Use a decimal point, for example 3000000.00', errorText: _error)),
      const SizedBox(height: 22), SizedBox(width: double.infinity, child: FilledButton(
        onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save budget'))),
    ])),
  );
}
