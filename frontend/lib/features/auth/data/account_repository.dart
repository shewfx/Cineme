import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/idempotency.dart';
import '../../../shared/models/profile.dart';

/// Explicit app-profile setup after sign-in (API_CONTRACT): POST
/// /me/bootstrap creates or reuses the profile; GET /me only reads.
abstract interface class AccountRepository {
  Future<void> bootstrap();

  Future<Profile> me();

  /// PATCH /me {country_code}; null goes back to the time zone's country.
  Future<void> setRegion(String? countryCode);

  /// GET /watch/regions: (code, name) pairs TMDB has providers for.
  Future<List<(String, String)>> regions();
}

/// Null in the UI-preview build.
final accountRepositoryProvider = Provider<AccountRepository?>((ref) => null);

class ApiAccountRepository implements AccountRepository {
  ApiAccountRepository(this._api);

  final ApiClient _api;
  final _keys = RetryKeys();

  @override
  Future<void> bootstrap() async {
    final body = await _api.post('/api/v1/me/bootstrap', body: const {});
    profileFromJson(_map(body['profile']));
  }

  @override
  Future<Profile> me() async => profileFromJson(await _api.get('/api/v1/me'));

  @override
  Future<void> setRegion(String? countryCode) async {
    final body = {'country_code': countryCode};
    await _keys.send(
      commandFingerprint('PATCH', '/api/v1/me', body),
      (key) => _api.patch('/api/v1/me', body: body, idempotencyKey: key),
    );
  }

  @override
  Future<List<(String, String)>> regions() async {
    final body = await _api.get('/api/v1/watch/regions');
    return [
      for (final r in body['items'] as List<Object?>)
        ((r as Map)['code'] as String, r['name'] as String),
    ];
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw _malformed;
}

const _malformed = ApiError(
  status: 200,
  code: 'MALFORMED_RESPONSE',
  message: 'Cinemé sent an unexpected response.',
);

/// MeResponse -> Profile. Missing required fields are a visible error, not an
/// empty profile. Genre names arrive with the registry in P3; blocked films
/// with GET /me/blocks in P5, so they are "not available" (null) here.
Profile profileFromJson(Map<String, dynamic> json) {
  final prefs = _map(json['preferences']);
  final timezone = json['timezone'];
  final displayName = json['display_name'];
  final cap = prefs['default_max_runtime_minutes'];
  final ai = prefs['ai_context_enabled'];
  final region = json['region'];
  final chosen = json['country_code'];
  if (json['id'] is! String ||
      timezone is! String ||
      (displayName != null && displayName is! String) ||
      (cap != null && cap is! int) ||
      (region != null && region is! String) ||
      (chosen != null && chosen is! String) ||
      ai is! bool) {
    throw _malformed;
  }
  return Profile(
    displayName: displayName as String?,
    timezone: timezone,
    preferredGenres: const [],
    blockedGenres: const [],
    defaultMaxRuntimeMinutes: cap as int?,
    aiContextEnabled: ai,
    blockedMovies: null,
    region: region as String?,
    regionChosen: chosen != null,
  );
}
