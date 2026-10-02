import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persists the Supabase session in Android Keystore-backed secure storage
/// instead of plain shared preferences (ARCHITECTURE "Configuration").
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage([this._storage = const FlutterSecureStorage()]);

  static const key = 'cineme.supabase.session';

  final FlutterSecureStorage _storage;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => _storage.containsKey(key: key);

  @override
  Future<String?> accessToken() => _storage.read(key: key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: key);
}
