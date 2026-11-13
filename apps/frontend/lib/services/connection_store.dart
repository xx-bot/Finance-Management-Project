import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One encrypted entry keeps the server address and its session together.
abstract interface class ConnectionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureConnectionStore implements ConnectionStore {
  SecureConnectionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'pocket.receipt_connection.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}
