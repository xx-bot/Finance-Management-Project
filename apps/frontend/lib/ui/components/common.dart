import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/expense.dart';
import '../../state/ledger_state.dart';
import '../theme.dart';

class PocketCard extends StatelessWidget {
  const PocketCard({super.key, required this.child, this.color = Colors.white, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: color == Colors.white ? PocketColors.line : color)),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color = PocketColors.green});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(color: color.withAlpha(18), borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12, top: 6),
    child: Row(children: [
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
      if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
    ]),
  );
}

class CategoryIcon extends StatelessWidget {
  const CategoryIcon(this.category, {super.key, this.size = 46});
  final ExpenseCategory category;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(color: category.color.withAlpha(30), borderRadius: BorderRadius.circular(14)),
    child: Icon(category.icon, color: category.color, size: size * .48),
  );
}

class ExpenseTile extends StatelessWidget {
  const ExpenseTile({super.key, required this.expense, required this.onTap});
  final Expense expense;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(14),
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Row(children: [
      CategoryIcon(expense.category), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(expense.merchant, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('${expense.category.label} · ${DateFormat('d MMM').format(expense.date)}',
            style: Theme.of(context).textTheme.bodySmall),
      ])),
      const SizedBox(width: 8),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(expense.currency.format(expense.totalMinor), style: Theme.of(context).textTheme.titleSmall),
        if (expense.needsReview) const Padding(padding: EdgeInsets.only(top: 4), child: Tag('Review', color: PocketColors.amber)),
      ]),
    ])),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.message, this.action, this.onAction, this.icon = Icons.receipt_long_outlined});
  final String title, message;
  final String? action;
  final VoidCallback? onAction;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 18),
    child: Column(children: [
      CircleAvatar(radius: 32, backgroundColor: PocketColors.lime, child: Icon(icon, color: PocketColors.green, size: 30)),
      const SizedBox(height: 18), Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8), Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: PocketColors.muted)),
      if (action != null) Padding(padding: const EdgeInsets.only(top: 20), child: FilledButton(onPressed: onAction, child: Text(action!))),
    ]),
  );
}

class MonthSelector extends StatelessWidget {
  const MonthSelector(this.state, {super.key});
  final LedgerState state;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () async {
      final now = DateTime.now();
      final value = await showModalBottomSheet<DateTime>(context: context, builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 12), child: Text('Choose a month', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
          for (var index = 0; index < 12; index++) Builder(builder: (context) {
            final month = DateTime(now.year, now.month - index);
            final selected = state.month.year == month.year && state.month.month == month.month;
            return ListTile(title: Text(DateFormat('MMMM yyyy').format(month)),
                trailing: selected ? const Icon(Icons.check_rounded, color: PocketColors.green) : null,
                onTap: () => Navigator.pop(context, month));
          }),
        ]),
      ));
      if (value != null) state.setMonth(value);
    },
    borderRadius: BorderRadius.circular(12),
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(DateFormat('MMMM yyyy').format(state.month), style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(width: 5), const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
    ])),
  );
}

class ReceiptPreview extends StatelessWidget {
  const ReceiptPreview({super.key, this.bytes, this.path, required this.merchant,
    required this.lines, required this.total, this.sample = false});
  final Uint8List? bytes;
  final String? path;
  final String merchant, total;
  final List<(String, String)> lines;
  final bool sample;
  @override
  Widget build(BuildContext context) {
    final hasImage = bytes != null || path != null;
    Widget paper() => Container(
      width: 265, padding: const EdgeInsets.all(22), color: Colors.white,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.spa_outlined, color: PocketColors.green, size: 24),
        const SizedBox(height: 8), Text(merchant.isEmpty ? 'Your receipt' : merchant.toUpperCase(), textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6), Text(sample ? 'SAMPLE RECEIPT' : 'EXPENSE SUMMARY', textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'monospace', color: PocketColors.muted, fontSize: 9)),
        const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider()),
        for (final line in lines.take(5)) Padding(padding: const EdgeInsets.only(bottom: 9), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(line.$1, style: const TextStyle(fontFamily: 'monospace', fontSize: 10))),
          const SizedBox(width: 8), Text(line.$2, style: const TextStyle(fontFamily: 'monospace', fontSize: 10)),
        ])),
        const Padding(padding: EdgeInsets.symmetric(vertical: 9), child: Divider()),
        Row(children: [const Expanded(child: Text('TOTAL', style: TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w700))),
          Text(total, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w700))]),
        const SizedBox(height: 16), const Text('THANK YOU · HAVE A LOVELY DAY', textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'monospace', color: PocketColors.muted, fontSize: 8)),
      ]),
    );
    Widget image() => bytes != null
        ? Image.memory(bytes!, fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Center(child: Text('This photo format cannot be previewed.')))
        : Image.file(File(path!), fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Center(child: Text('Original photo is unavailable.')));
    return Container(
      height: 260, clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: const Color(0xFFE9EDE5), borderRadius: BorderRadius.circular(20)),
      child: Stack(children: [
        Positioned.fill(child: hasImage
            ? InteractiveViewer(minScale: 1, maxScale: 5, child: image())
            : Center(child: Padding(padding: const EdgeInsets.all(16), child: FittedBox(
                fit: BoxFit.scaleDown, child: Transform.rotate(angle: -.045, child: paper()))))),
        Positioned(right: 10, bottom: 10, child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.white.withAlpha(240), borderRadius: BorderRadius.circular(9)),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Text(hasImage ? 'Pinch to zoom' : sample ? 'Sample preview' : 'Receipt summary', style: const TextStyle(fontSize: 10, color: PocketColors.ink))),
        )),
      ]),
    );
  }
}
