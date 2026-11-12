import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/ledger_repository.dart';
import 'services/receipt_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.white, systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(PocketApp(
    repository: SqliteLedgerRepository(),
    receiptService: BackendReceiptService(baseUrl: const String.fromEnvironment('API_BASE_URL')),
  ));
}
