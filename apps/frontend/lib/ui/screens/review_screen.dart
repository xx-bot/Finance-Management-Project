import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../models/expense.dart';
import '../../models/receipt_draft.dart';
import '../../state/ledger_state.dart';
import '../components/category_picker.dart';
import '../components/common.dart';
import '../theme.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.state, required this.draft});
  final LedgerState state;
  final ReceiptDraft draft;
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController _merchant;
  late final TextEditingController _total;
  late final TextEditingController _note;
  bool _saving = false;
  bool _submitted = false;
  String? _saveError;
  ReceiptDraft get draft => widget.draft;

  @override
  void initState() {
    super.initState();
    _merchant = TextEditingController(text: draft.merchant);
    _total = TextEditingController(text: draft.total);
    _note = TextEditingController(text: draft.note);
  }
  @override
  void dispose() {
    _merchant.dispose(); _total.dispose(); _note.dispose(); super.dispose();
  }

  void _amountsChanged() => setState(() { draft.mismatchReviewed = false; _saveError = null; });

  Future<void> _editItem([int? index]) async {
    final item = await showModalBottomSheet<DraftLine>(context: context, isScrollControlled: true,
        builder: (_) => ItemEditor(line: index == null ? DraftLine(category: draft.category) : draft.lines[index], style: draft.numberStyle));
    if (item != null && mounted) {
      setState(() {
        if (index == null) { draft.lines.add(item); } else { draft.lines[index] = item; }
        draft.mismatchReviewed = false;
      });
    }
  }

  Future<void> _adjustment() async {
    final adjustment = await showModalBottomSheet<DraftAdjustment>(context: context, isScrollControlled: true,
        builder: (_) => AdjustmentEditor(style: draft.numberStyle));
    if (adjustment != null && mounted) setState(() { draft.adjustments.add(adjustment); draft.mismatchReviewed = false; });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() { _submitted = true; _saveError = null; });
    if (draft.errors.isNotEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.state.saveDraft(draft);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(draft.isDemo ? 'Sample expense saved in preview.' : 'Expense saved on this device.')));
      Navigator.pop(context, true);
    } on Object {
      if (mounted) setState(() { _saving = false; _saveError = 'We could not save this expense. Your review is still here; please try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final difference = draft.difference;
    final mismatch = draft.lines.isNotEmpty && difference != null && difference != 0;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: Text(draft.originalId == null ? 'Review receipt' : 'Edit expense'), centerTitle: true,
          actions: [if (draft.isDemo) const Padding(padding: EdgeInsets.only(right: 16), child: Center(child: Tag('Sample')))]),
        body: AbsorbPointer(absorbing: _saving, child: ListView(padding: const EdgeInsets.fromLTRB(22, 12, 22, 24), children: [
          Text('Check the little details.', style: theme.headlineMedium), const SizedBox(height: 8),
          Text('Check the merchant, amounts and suggested categories. You can edit them before saving.', style: theme.bodyMedium?.copyWith(color: PocketColors.muted)),
          const SizedBox(height: 22),
          ReceiptPreview(bytes: draft.imageBytes, path: draft.savedImagePath,
            merchant: draft.merchant, lines: draft.lines.map((line) => (line.description, line.amount)).toList(), total: draft.total, sample: draft.isDemo),
          const SizedBox(height: 24), const SectionHeading('The essentials'),
          TextField(controller: _merchant, textCapitalization: TextCapitalization.words,
            onChanged: (value) => setState(() => draft.merchant = value),
            decoration: InputDecoration(labelText: 'Merchant or expense name', hintText: 'Where was this purchase?',
                errorText: _submitted && draft.merchant.trim().isEmpty ? 'Add a name for this expense.' : null)),
          const SizedBox(height: 12),
          PocketCard(padding: const EdgeInsets.symmetric(horizontal: 16), child: Column(children: [
            ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.calendar_today_outlined, size: 20),
              title: Text(DateFormat('EEEE, d MMM yyyy').format(draft.date)), trailing: const Icon(Icons.expand_more_rounded),
              onTap: () async {
                final value = await showDatePicker(context: context, initialDate: draft.date,
                    firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 366)));
                if (value != null && mounted) setState(() => draft.date = value);
              }),
            const Divider(),
            ListTile(contentPadding: EdgeInsets.zero, leading: CategoryIcon(draft.category, size: 30),
              title: Text(draft.category.label), subtitle: const Text('Receipt category · Default for new items'), trailing: const Icon(Icons.expand_more_rounded),
              onTap: () async {
                final value = await chooseCategory(context, draft.category);
                if (value != null && mounted) setState(() => draft.category = value);
              }),
          ])),
          const SizedBox(height: 24), const SectionHeading('Currency & printed numbers'),
          PocketCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text('Receipt currency', style: theme.titleSmall)),
              DropdownButton<LedgerCurrency>(value: draft.currency, underline: const SizedBox.shrink(),
                items: LedgerCurrency.values.map((value) => DropdownMenuItem(value: value, child: Text(value.code))).toList(),
                onChanged: (value) { if (value != null) setState(() { draft.currency = value; draft.mismatchReviewed = false; }); }),
            ]),
            const SizedBox(height: 8), const Text('Which number format is printed on this receipt?'), const SizedBox(height: 12),
            Wrap(spacing: 9, children: [for (final value in NumberStyle.values) ChoiceChip(
              label: Text(value.example), selected: draft.numberStyle == value,
              onSelected: (_) => setState(() { draft.numberStyle = value; draft.mismatchReviewed = false; }),
            )]),
            const SizedBox(height: 8), Text('This keeps separators from changing the meaning of an amount.', style: theme.bodySmall),
          ])),
          const SizedBox(height: 24), SectionHeading('Items (${draft.lines.length})', action: '+ Add item', onAction: _editItem),
          if (draft.lines.isEmpty) PocketCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('No item details yet. You can add them or record the final total only.'),
            CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Record the total without item details'), value: draft.totalOnlyConfirmed,
              onChanged: (value) => setState(() => draft.totalOnlyConfirmed = value ?? false)),
          ])),
          for (var index = 0; index < draft.lines.length; index++) Padding(padding: const EdgeInsets.only(bottom: 10),
            child: PocketCard(padding: const EdgeInsets.fromLTRB(16, 15, 8, 15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CategoryIcon(draft.lines[index].category, size: 36), const SizedBox(width: 11),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(draft.lines[index].description.isEmpty ? 'Item ${index + 1}' : draft.lines[index].description, style: theme.titleSmall),
                  const SizedBox(height: 4), Text(draft.lines[index].category.label, style: theme.bodySmall),
                  const SizedBox(height: 4), Text([
                    if (draft.lines[index].quantity.isNotEmpty) 'Qty ${draft.lines[index].quantity}',
                    if (draft.lines[index].unitPrice.isNotEmpty) 'Unit ${draft.lines[index].unitPrice}',
                  ].join(' · '), style: theme.bodySmall),
                  const SizedBox(height: 8), Text(draft.lines[index].amount.isEmpty ? 'Amount missing' : draft.lines[index].amount,
                      style: theme.titleSmall?.copyWith(color: draft.tryAmount(draft.lines[index].amount) == null ? PocketColors.amber : PocketColors.ink)),
                ])),
                IconButton(onPressed: () => _editItem(index), tooltip: 'Edit item ${index + 1}', icon: const Icon(Icons.edit_outlined, size: 19)),
                IconButton(onPressed: () => setState(() { draft.lines.removeAt(index); draft.mismatchReviewed = false; }),
                  tooltip: 'Remove item ${index + 1}', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close_rounded, size: 18, color: PocketColors.muted)),
              ]),
              if (draft.lines[index].subItems.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 47, top: 8), child: Text(
                draft.lines[index].subItems.map((item) => item['description'] ?? 'Additional detail').join(' · '), style: theme.bodySmall)),
            ]))),
          const SizedBox(height: 12),
          TextButton.icon(onPressed: _adjustment, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Add tax, discount or adjustment')),
          for (var index = 0; index < draft.adjustments.length; index++) ListTile(
            contentPadding: const EdgeInsets.only(left: 4), title: Text(draft.adjustments[index].label), subtitle: Text(draft.adjustments[index].amount),
            trailing: IconButton(tooltip: 'Remove adjustment', icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() { draft.adjustments.removeAt(index); draft.mismatchReviewed = false; }))),
          const SizedBox(height: 16), const SectionHeading('Final total'),
          TextField(controller: _total, keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: theme.headlineSmall, onChanged: (value) { draft.total = value; _amountsChanged(); },
            decoration: InputDecoration(labelText: 'Printed total (${draft.currency.code})',
              hintText: draft.numberStyle?.example ?? 'Amount as printed',
              errorText: _submitted && (draft.totalMinor == null || draft.totalMinor! < 0) ? 'Check the amount and selected number format.' : null)),
          if (draft.lines.isNotEmpty && difference != null && draft.numberStyle != null) Padding(
            padding: const EdgeInsets.only(top: 15), child: PocketCard(color: mismatch ? PocketColors.peach : PocketColors.lime, child: Column(children: [
              _SummaryRow('Item subtotal', draft.currency.format(draft.itemSubtotal!)),
              if (draft.adjustments.isNotEmpty) _SummaryRow('Adjustments', draft.currency.format(draft.adjustmentTotal ?? 0)),
              const SizedBox(height: 8),
              Row(children: [Icon(mismatch ? Icons.info_outline_rounded : Icons.check_circle_outline_rounded,
                size: 18, color: mismatch ? PocketColors.amber : PocketColors.green), const SizedBox(width: 9),
                Expanded(child: Text(mismatch ? 'A ${draft.currency.format(difference.abs())} difference needs a check.' : 'Items and total match.',
                  style: theme.titleSmall?.copyWith(color: mismatch ? PocketColors.amber : PocketColors.green)))]),
              if (mismatch) CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
                title: const Text('I checked the final total. Save with this difference.'), value: draft.mismatchReviewed,
                onChanged: (value) => setState(() => draft.mismatchReviewed = value ?? false)),
            ]))),
          const SizedBox(height: 22), TextField(controller: _note, maxLines: 2,
            onChanged: (value) => draft.note = value,
            decoration: const InputDecoration(labelText: 'A little note (optional)', hintText: 'What was this for?')),
          if (_submitted && draft.errors.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 18),
            child: PocketCard(color: PocketColors.peach, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('A few details need attention', style: theme.titleSmall), const SizedBox(height: 8),
              for (final error in draft.errors) Padding(padding: const EdgeInsets.only(bottom: 5), child: Text('• $error')),
            ]))),
          if (_saveError != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_saveError!, style: const TextStyle(color: PocketColors.red))),
        ])),
        bottomNavigationBar: SafeArea(top: false, child: Container(color: Colors.white,
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 14), child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check_rounded, size: 20),
            label: Text(_saving ? 'Saving…' : draft.isDemo ? 'Save sample expense' : 'Save expense'),
          ))),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 7), child: Row(children: [
    Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)), Text(value, style: Theme.of(context).textTheme.titleSmall),
  ]));
}

class ItemEditor extends StatefulWidget {
  const ItemEditor({super.key, required this.line, required this.style});
  final DraftLine line;
  final NumberStyle? style;
  @override
  State<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<ItemEditor> {
  late final TextEditingController _description, _quantity, _unit, _amount;
  late ExpenseCategory _category;
  late final List<Map<String, dynamic>> _subItems;
  String? _error;
  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.line.description);
    _quantity = TextEditingController(text: widget.line.quantity);
    _unit = TextEditingController(text: widget.line.unitPrice);
    _amount = TextEditingController(text: widget.line.amount);
    _category = widget.line.category;
    _subItems = _copySubItems(widget.line.subItems);
  }
  List<Map<String, dynamic>> _copySubItems(List<Map<String, dynamic>> items) => items.map((item) => {
    ...item,
    'sub_items': _copySubItems((item['sub_items'] as List? ?? [])
        .map((child) => Map<String, dynamic>.from(child as Map)).toList()),
  }).toList();

  Iterable<Widget> _modifierCategories(List<Map<String, dynamic>> items, [int depth = 0]) sync* {
    for (final item in items) {
      final category = ExpenseCategory.fromName(item['category'] as String?);
      yield ListTile(contentPadding: EdgeInsets.only(left: depth * 12.0),
        leading: CategoryIcon(category, size: 30),
        title: Text(item['description'] as String? ?? 'Additional detail'), subtitle: Text(category.label),
        trailing: const Icon(Icons.expand_more_rounded), onTap: () async {
          final value = await chooseCategory(context, category);
          if (value != null && mounted) setState(() => item['category'] = value.name);
        });
      yield* _modifierCategories(item['sub_items'] as List<Map<String, dynamic>>, depth + 1);
    }
  }
  @override
  void dispose() { for (final controller in [_description, _quantity, _unit, _amount]) { controller.dispose(); } super.dispose(); }

  void _save() {
    try {
      if (_description.text.trim().isEmpty || _amount.text.trim().isEmpty) throw const FormatException();
      if (widget.style != null && parseMinor(_amount.text, widget.style!) < 0) throw const FormatException();
      Navigator.pop(context, DraftLine(description: _description.text.trim(), quantity: _quantity.text.trim(),
          unitPrice: _unit.text.trim(), amount: _amount.text.trim(), category: _category, subItems: _subItems));
    } on FormatException { setState(() => _error = 'Add an item name and check its printed amount.'); }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(22, 0, 22, MediaQuery.viewInsetsOf(context).bottom + 22),
    child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Item details', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 20),
      TextField(controller: _description, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Item name')),
      const SizedBox(height: 12), Row(children: [
        Expanded(child: TextField(controller: _quantity, decoration: const InputDecoration(labelText: 'Quantity (optional)'))),
        const SizedBox(width: 12), Expanded(child: TextField(controller: _unit, decoration: const InputDecoration(labelText: 'Unit price (optional)'))),
      ]),
      const SizedBox(height: 12), TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Printed line amount', helperText: widget.style == null ? 'Confirm the number format on the receipt review.' : 'Format: ${widget.style!.example}')),
      const SizedBox(height: 8), ListTile(contentPadding: EdgeInsets.zero, leading: CategoryIcon(_category, size: 34), title: Text(_category.label),
        trailing: const Icon(Icons.expand_more_rounded), onTap: () async {
          final value = await chooseCategory(context, _category);
          if (value != null && mounted) setState(() => _category = value);
        }),
      if (_subItems.isNotEmpty) ...[
        const SizedBox(height: 12), const Text('Modifier categories'),
        ..._modifierCategories(_subItems),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_error!, style: const TextStyle(color: PocketColors.red))),
      const SizedBox(height: 8), SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Save item'))),
    ])),
  );
}

class AdjustmentEditor extends StatefulWidget {
  const AdjustmentEditor({super.key, required this.style});
  final NumberStyle? style;
  @override
  State<AdjustmentEditor> createState() => _AdjustmentEditorState();
}

class _AdjustmentEditorState extends State<AdjustmentEditor> {
  String _label = 'Tax';
  final _amount = TextEditingController();
  String? _error;
  @override
  void dispose() { _amount.dispose(); super.dispose(); }
  void _save() {
    var amount = _amount.text.trim();
    try {
      if (amount.isEmpty) throw const FormatException();
      if (_label == 'Discount' && !amount.startsWith('-')) amount = '-$amount';
      if (widget.style != null) parseMinor(amount, widget.style!);
      Navigator.pop(context, DraftAdjustment(_label, amount));
    } on FormatException { setState(() => _error = 'Check this amount and the printed number format.'); }
  }
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(22, 0, 22, MediaQuery.viewInsetsOf(context).bottom + 24),
    child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Keep the total in balance', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 20),
      DropdownButtonFormField<String>(initialValue: _label,
        items: ['Tax', 'Discount', 'Service charge', 'Rounding', 'Other'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
        onChanged: (value) => setState(() => _label = value!), decoration: const InputDecoration(labelText: 'Adjustment')),
      const SizedBox(height: 12), TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(labelText: 'Amount as printed', errorText: _error,
            helperText: 'Discounts subtract from the total. Use a minus sign for negative rounding.')),
      const SizedBox(height: 22), SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Add adjustment'))),
    ])),
  );
}
