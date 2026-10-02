import 'dart:convert';
import 'dart:math';

import 'api_client.dart';

final _random = Random.secure();

/// Random UUID v4 for one deliberate action's `Idempotency-Key`.
String newIdempotencyKey() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// One key per deliberate command. When the outcome is unknown (no response,
/// timeout, 5xx) the key is kept, so retrying the *same* command reuses it
/// and the server replays its committed result instead of applying it twice.
/// Success or a definite error (4xx) settles it; the next action is new.
class RetryKeys {
  final _pending = <String, String>{};

  /// [fingerprint] identifies the command (method, path, body).
  Future<T> send<T>(
    String fingerprint,
    Future<T> Function(String key) call,
  ) async {
    final key = _pending[fingerprint] ?? newIdempotencyKey();
    try {
      final result = await call(key);
      _pending.remove(fingerprint);
      return result;
    } on ApiError catch (e) {
      if (isAmbiguous(e)) {
        _pending[fingerprint] = key;
      } else {
        _pending.remove(fingerprint);
      }
      rethrow;
    }
  }
}

/// The request may or may not have been applied.
bool isAmbiguous(ApiError e) => e.status == null || e.status! >= 500;

String commandFingerprint(String method, String path, Object? body) =>
    '$method $path ${jsonEncode(body)}';
