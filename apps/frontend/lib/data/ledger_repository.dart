import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/expense.dart';

abstract interface class LedgerRepository {
  Future<void> open();
  Future<List<Expense>> loadExpenses();
  Future<void> saveExpense(Expense expense);
  Future<void> deleteExpense(String id);
  Future<Map<String, String>> loadPreferences();
  Future<void> setPreference(String key, String value);
  Future<String> saveReceiptImage(Uint8List bytes, String id, String filename);
  Future<void> close();
}

class SqliteLedgerRepository implements LedgerRepository {
  Database? _database;
  Database get db => _database!;

  @override
  Future<void> open() async {
    if (_database != null) return;
    _database = await openDatabase(
      p.join(await getDatabasesPath(), 'pocket_ledger.db'),
      version: 1,
      onCreate: (database, version) async {
        await database.execute('CREATE TABLE expenses (id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
        await database.execute('CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      },
    );
  }

  @override
  Future<List<Expense>> loadExpenses() async => (await db.query('expenses'))
      .map((row) => Expense.fromJson(jsonDecode(row['payload'] as String) as Map<String, dynamic>))
      .toList();

  @override
  Future<void> saveExpense(Expense expense) async {
    await db.transaction((transaction) async {
      await transaction.insert('expenses', {'id': expense.id, 'payload': jsonEncode(expense.toJson())},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> deleteExpense(String id) async {
    final rows = await db.query('expenses', where: 'id = ?', whereArgs: [id]);
    await db.delete('expenses', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final expense = Expense.fromJson(jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>);
      final path = expense.imagePath;
      if (path != null) {
        final directory = await getApplicationDocumentsDirectory();
        // Delete only this application's managed receipt file.
        if (p.isWithin(p.join(directory.path, 'receipts'), path)) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
    }
  }

  @override
  Future<Map<String, String>> loadPreferences() async => {
        for (final row in await db.query('preferences')) row['key'] as String: row['value'] as String,
      };

  @override
  Future<void> setPreference(String key, String value) async {
    await db.insert('preferences', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<String> saveReceiptImage(Uint8List bytes, String id, String filename) async {
    final directory = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'receipts'));
    await directory.create(recursive: true);
    final suffix = p.extension(filename).toLowerCase();
    final extension = {'.jpg', '.jpeg', '.png', '.webp', '.heic'}.contains(suffix) ? suffix : '.jpg';
    final file = File(p.join(directory.path, '$id$extension'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
