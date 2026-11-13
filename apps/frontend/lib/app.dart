import 'dart:async';

import 'package:flutter/material.dart';

import 'data/ledger_repository.dart';
import 'models/expense.dart';
import 'models/receipt_draft.dart';
import 'services/photo_picker.dart';
import 'services/receipt_service.dart';
import 'state/ledger_state.dart';
import 'ui/screens/expense_detail_screen.dart';
import 'ui/screens/expenses_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/insights_screen.dart';
import 'ui/screens/review_screen.dart';
import 'ui/screens/scan_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/theme.dart';

class PocketApp extends StatefulWidget {
  const PocketApp({super.key, required this.repository, required this.receiptService, this.photoPicker});
  final LedgerRepository repository;
  final ReceiptService receiptService;
  final ReceiptPhotoPicker? photoPicker;
  @override
  State<PocketApp> createState() => _PocketAppState();
}

class _PocketAppState extends State<PocketApp> {
  late final LedgerState _state;
  late Future<void> _initialization;
  @override
  void initState() {
    super.initState();
    _state = LedgerState(widget.repository);
    _initialization = _initialize();
  }
  Future<void> _initialize() async {
    await _state.initialize();
    final service = widget.receiptService;
    if (service is ConnectableReceiptService) await service.initialize();
  }
  @override
  void dispose() {
    widget.receiptService.close();
    unawaited(widget.repository.close());
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pocket Ledger', debugShowCheckedModeBanner: false, theme: pocketTheme(),
    home: FutureBuilder<void>(future: _initialization, builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      }
      if (snapshot.hasError) {
        return Scaffold(body: SafeArea(child: Center(child: Padding(padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_off_outlined, size: 42, color: PocketColors.green),
            const SizedBox(height: 20), Text('Your pocket needs a moment.', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 10), const Text('We couldn’t open your saved expenses. Try again to keep your records intact.', textAlign: TextAlign.center),
            const SizedBox(height: 20), FilledButton(onPressed: () => setState(() => _initialization = _initialize()), child: const Text('Try again')),
          ])))));
      }
      return PocketShell(state: _state, service: widget.receiptService, picker: widget.photoPicker ?? ReceiptPhotoPicker());
    }),
  );
}

class PocketShell extends StatefulWidget {
  const PocketShell({super.key, required this.state, required this.service, required this.picker});
  final LedgerState state;
  final ReceiptService service;
  final ReceiptPhotoPicker picker;
  @override
  State<PocketShell> createState() => _PocketShellState();
}

class _PocketShellState extends State<PocketShell> {
  int _tab = 0;
  late final Listenable _changes;
  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _changes = Listenable.merge([widget.state, if (service is ConnectableReceiptService) service]);
  }
  Future<void> _scan() async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) =>
        ScanScreen(state: widget.state, service: widget.service, picker: widget.picker)));
    if (saved == true && mounted) setState(() => _tab = 0);
  }
  Future<void> _manual() async {
    final draft = ReceiptDraft(currency: widget.state.currency, date: DateTime.now(), totalOnlyConfirmed: true);
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => ReviewScreen(state: widget.state, draft: draft)));
    if (saved == true && mounted) setState(() => _tab = 0);
  }
  void _expense(Expense value) {
    if (value.needsReview) {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(state: widget.state, draft: ReceiptDraft.fromExpense(value))));
    } else {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ExpenseDetailScreen(state: widget.state, expense: value)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: _changes, builder: (context, _) => Scaffold(
    body: SafeArea(bottom: false, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
      child: IndexedStack(index: _tab, children: [
        HomeScreen(state: widget.state, onScan: _scan, onManual: _manual,
          onExpenses: () => setState(() => _tab = 1), onInsights: () => setState(() => _tab = 2),
          onSettings: () => setState(() => _tab = 3), onExpense: _expense),
        ExpensesScreen(state: widget.state, onExpense: _expense, onManual: _manual),
        InsightsScreen(state: widget.state),
        SettingsScreen(state: widget.state, receiptService: widget.service),
      ]),
    ))),
    bottomNavigationBar: Container(decoration: const BoxDecoration(color: Colors.white,
      border: Border(top: BorderSide(color: PocketColors.line))),
      child: SafeArea(top: false, child: Center(heightFactor: 1, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
        child: SizedBox(height: 78, child: Row(children: [
          _navItem(0, 'Home', Icons.home_outlined, Icons.home_rounded),
          _navItem(1, 'Expenses', Icons.receipt_long_outlined, Icons.receipt_long_rounded),
          Expanded(child: Semantics(button: true, label: 'Scan receipt', child: InkWell(onTap: _scan, child: Padding(
            padding: const EdgeInsets.only(top: 5, bottom: 3), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width: 47, height: 43, decoration: BoxDecoration(color: PocketColors.ink, borderRadius: BorderRadius.circular(15)),
                child: const Icon(Icons.document_scanner_outlined, color: PocketColors.lime, size: 23)),
              const SizedBox(height: 4), const Text('Scan', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: PocketColors.ink)),
            ]))))),
          _navItem(2, 'Insights', Icons.donut_large_outlined, Icons.donut_large_rounded),
          _navItem(3, 'Settings', Icons.tune_outlined, Icons.tune_rounded),
        ])),
      )))),
  ));

  Widget _navItem(int index, String label, IconData icon, IconData selectedIcon) {
    final selected = _tab == index;
    return Expanded(child: Semantics(selected: selected, button: true, label: label, child: InkWell(
      onTap: () => setState(() => _tab = index), child: SizedBox(height: 76, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(selected ? selectedIcon : icon, size: 23, color: selected ? PocketColors.green : PocketColors.muted),
        const SizedBox(height: 6), Text(label, style: TextStyle(fontSize: 10, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? PocketColors.green : PocketColors.muted)),
      ])),
    )));
  }
}
