import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/profile.dart';

/// Explicit app-profile setup after sign-in (API_CONTRACT): POST
/// /me/bootstrap creates or reuses the profile; GET /me only reads.
abstract interface class AccountRepository {
  Future<void> bootstrap();

  Future<Profile> me();
}

/// Null in the UI-preview build.
final accountRepositoryProvider = Provider<AccountRepository?>((ref) => null);

class ApiAccountRepository implements AccountRepository {
  ApiAccountRepository(this._api);

  final ApiClient _api;

  @override
  Future<void> bootstrap() async {
    final body = await _api.post('/api/v1/me/bootstrap', body: const {});
    profileFromJson(_map(body['profile']));
  }

  @override
  Future<Profile> me() async => profileFromJson(await _api.get('/api/v1/me'));
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
  if (json['id'] is! String ||
      timezone is! String ||
      (displayName != null && displayName is! String) ||
      (cap != null && cap is! int) ||
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
  );
}
