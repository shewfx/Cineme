import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/idempotency.dart';
import '../../../core/network/movie_dto.dart';
import '../../../shared/models/movie.dart';
import '../../../shared/models/profile.dart';
import '../../../shared/models/series.dart';

/// Explicit app-profile setup after sign-in (API_CONTRACT): POST
/// /me/bootstrap creates or reuses the profile; GET /me only reads.
abstract interface class AccountRepository {
  Future<void> bootstrap();

  Future<Profile> me();

  /// PATCH /me/preferences {tonight_media}. Reads the current version first
  /// and retries once on a version conflict; changes nothing but the setting.
  Future<void> setTonightMedia(TonightMedia media);

  /// PATCH /me {onboarding_completed: true}. One-way and idempotent: Skip and
  /// Continue both call it, and a retry keeps the original completion time.
  Future<void> completeOnboarding();

  /// PATCH /me {country_code}; null goes back to the time zone's country.
  Future<void> setRegion(String? countryCode);

  /// GET /watch/regions: (code, name) pairs TMDB has providers for.
  Future<List<(String, String)>> regions();

  Future<void> unblock(int tmdbId);

  Future<void> block(int tmdbId);
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
  Future<Profile> me() async {
    final profile = await _api.get('/api/v1/me');
    final blockedMovies = <Movie>[];
    String? cursor;
    do {
      final blocks = await _api.get(
        '/api/v1/me/blocks',
        query: {
          'limit': 50,
          ...?(cursor == null ? null : {'cursor': cursor}),
        },
      );
      for (final item in asList(blocks['items'])) {
        blockedMovies.add(movieSummaryFromJson(asMap(asMap(item)['movie'])).$1);
      }
      cursor = blocks['next_cursor'] as String?;
    } while (cursor != null);
    return profileFromJson(profile, blockedMovies: blockedMovies);
  }

  @override
  Future<void> setRegion(String? countryCode) async {
    final body = {'country_code': countryCode};
    await _keys.send(
      commandFingerprint('PATCH', '/api/v1/me', body),
      (key) => _api.patch('/api/v1/me', body: body, idempotencyKey: key),
    );
  }

  @override
  Future<void> setTonightMedia(TonightMedia media) async {
    Future<void> attempt() async {
      final me = await _api.get('/api/v1/me');
      final version = asMap(me['preferences'])['version'];
      if (version is! int) throw _malformed;
      final body = {
        'expected_version': version,
        'tonight_media': media.wireName,
      };
      await _keys.send(
        commandFingerprint('PATCH', '/api/v1/me/preferences', body),
        (key) => _api.patch(
          '/api/v1/me/preferences',
          body: body,
          idempotencyKey: key,
        ),
      );
    }

    try {
      await attempt();
    } on ApiError catch (e) {
      if (e.code != 'VERSION_CONFLICT') rethrow;
      await attempt();
    }
  }

  @override
  Future<void> completeOnboarding() async {
    const body = {'onboarding_completed': true};
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

  @override
  Future<void> unblock(int tmdbId) async {
    final path = '/api/v1/me/blocks/$tmdbId';
    await _keys.send(
      commandFingerprint('DELETE', path, null),
      (key) => _api.delete(path, idempotencyKey: key),
    );
  }

  @override
  Future<void> block(int tmdbId) async {
    final path = '/api/v1/me/blocks/$tmdbId';
    await _keys.send(
      commandFingerprint('POST', path, null),
      (key) => _api.post(path, idempotencyKey: key),
    );
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
Profile profileFromJson(
  Map<String, dynamic> json, {
  List<Movie>? blockedMovies,
}) {
  final prefs = _map(json['preferences']);
  final timezone = json['timezone'];
  final displayName = json['display_name'];
  final cap = prefs['default_max_runtime_minutes'];
  final ai = prefs['ai_context_enabled'];
  final region = json['region'];
  final chosen = json['country_code'];
  final onboardedAt = json['onboarding_completed_at'];
  if (json['id'] is! String ||
      timezone is! String ||
      (displayName != null && displayName is! String) ||
      (cap != null && cap is! int) ||
      (region != null && region is! String) ||
      (chosen != null && chosen is! String) ||
      (onboardedAt != null && onboardedAt is! String) ||
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
    blockedMovies: blockedMovies,
    region: region as String?,
    regionChosen: chosen != null,
    tonightMedia: TonightMedia.fromWire(prefs['tonight_media']),
    preferencesVersion: (prefs['version'] as int?) ?? 1,
    // Absent key: older backend, treated as complete. Present null: pending.
    onboardingComplete:
        !json.containsKey('onboarding_completed_at') || onboardedAt != null,
  );
}
