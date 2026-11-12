import 'package:flutter/material.dart';

import '../../models/expense.dart';
import 'common.dart';

Future<ExpenseCategory?> chooseCategory(BuildContext context, ExpenseCategory current) =>
    showModalBottomSheet<ExpenseCategory>(context: context, builder: (context) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const Padding(padding: EdgeInsets.fromLTRB(22, 0, 22, 12), child: Text('Choose a category', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600))),
        for (final category in ExpenseCategory.values) ListTile(
          leading: CategoryIcon(category, size: 36), title: Text(category.label),
          trailing: current == category ? const Icon(Icons.check_rounded) : null,
          onTap: () => Navigator.pop(context, category),
        ),
      ]),
    ));
