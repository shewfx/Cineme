import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/idempotency.dart';
import '../../../core/network/movie_dto.dart';
import '../../../core/network/series_dto.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/viewing.dart';

/// POST /watchlist for a show: a duplicate is a success.
class SeriesAddResult {
  const SeriesAddResult({required this.entry, required this.alreadyPresent});

  final ShowEntry entry;
  final bool alreadyPresent;
}

/// Result of marking the next episode watched.
class EpisodeWatchedResult {
  const EpisodeWatchedResult({
    required this.entry,
    required this.viewingId,
    required this.alreadyRecorded,
  });

  final ShowEntry entry;
  final String viewingId;
  final bool alreadyRecorded;
}

/// Shows and anime through the Cinemé API (ADR 011). Flutter never calls
/// TMDB; media identity is explicit in every call.
abstract interface class SeriesRepository {
  /// GET /tv/search: title length 2..100.
  Future<SeriesSearchPage> search(String query, {int page = 1});

  /// GET /tv/{id}: details plus the caller's entry (null when not on the list).
  Future<SeriesDetails> details(int tmdbId);

  /// GET /tv/{id}/seasons: regular seasons only (specials are not included).
  Future<List<SeasonInfo>> seasons(int tmdbId);

  /// POST /watchlist {media_type: series}. Conflicts throw [InventoryConflict].
  Future<SeriesAddResult> add(int tmdbId);

  /// PUT /series/{id}/progress. [last] null means "not started". A stale
  /// [expectedVersion] throws `VERSION_CONFLICT`. Creates no viewings.
  Future<ShowEntry> setProgress(
    int tmdbId, {
    required int expectedVersion,
    required (int, int)? last,
  });

  /// GET /me/blocks/series: shows set to Never recommend.
  Future<List<Series>> blocked();

  /// DELETE /me/blocks/series/{id}: reverses it; the watchlist entry and its
  /// progress were never touched.
  Future<void> unblock(int tmdbId);

  /// GET /episode-viewings: watched episodes, newest first.
  Future<Paged<EpisodeViewingRecord>> viewings({String? cursor});

  /// POST /series/{id}/episodes/watched: the NEXT episode only, atomic with
  /// the progress pointer. Anything else is refused by the server.
  Future<EpisodeWatchedResult> markNextWatched(
    int tmdbId, {
    required int season,
    required int episode,
    Rating? rating,
  });
}

/// Null in the UI-preview build and against a backend without shows.
final seriesRepositoryProvider = Provider<SeriesRepository?>((ref) => null);

class ApiSeriesRepository implements SeriesRepository {
  ApiSeriesRepository(this._api);

  final ApiClient _api;
  final _keys = RetryKeys();

  static const _conflicts = {
    'SERIES_INELIGIBLE',
    'SERIES_BLOCKED',
    'WATCHLIST_LIMIT',
  };

  @override
  Future<SeriesSearchPage> search(String query, {int page = 1}) async {
    final body = await _api.get(
      '/api/v1/tv/search',
      query: {'q': query, 'page': page},
    );
    final pageNo = body['page'];
    final total = body['total_pages'];
    if (pageNo is! int || total is! int) throw malformedResponse;
    return SeriesSearchPage(
      page: pageNo,
      totalPages: total,
      results: [
        for (final r in asList(body['results'])) seriesFromJson(asMap(r)),
      ],
    );
  }

  @override
  Future<SeriesDetails> details(int tmdbId) async =>
      seriesDetailsFromJson(await _api.get('/api/v1/tv/$tmdbId'));

  @override
  Future<List<SeasonInfo>> seasons(int tmdbId) async =>
      seasonsFromJson(await _api.get('/api/v1/tv/$tmdbId/seasons'));

  @override
  Future<SeriesAddResult> add(int tmdbId) async {
    try {
      final request = {'media_type': 'series', 'tmdb_id': tmdbId};
      final body = await _keys.send(
        commandFingerprint('POST', '/api/v1/watchlist', request),
        (key) =>
            _api.post('/api/v1/watchlist', body: request, idempotencyKey: key),
      );
      final already = body['already_present'];
      if (already is! bool) throw malformedResponse;
      return SeriesAddResult(
        entry: showEntryFromJson(asMap(body['entry'])),
        alreadyPresent: already,
      );
    } on ApiError catch (e) {
      throw _conflicts.contains(e.code) ? InventoryConflict(e.code) : e;
    }
  }

  @override
  Future<ShowEntry> setProgress(
    int tmdbId, {
    required int expectedVersion,
    required (int, int)? last,
  }) async {
    final path = '/api/v1/series/$tmdbId/progress';
    final request = {
      'expected_version': expectedVersion,
      'last_watched': last == null
          ? null
          : {'season': last.$1, 'episode': last.$2},
    };
    final body = await _keys.send(
      commandFingerprint('PUT', path, request),
      (key) => _api.put(path, body: request, idempotencyKey: key),
    );
    return showEntryFromJson(asMap(body['entry']));
  }

  @override
  Future<List<Series>> blocked() async {
    final body = await _api.get('/api/v1/me/blocks/series');
    return [
      for (final item in asList(body['items']))
        seriesFromJson(asMap(asMap(item)['series'])),
    ];
  }

  @override
  Future<void> unblock(int tmdbId) async {
    final path = '/api/v1/me/blocks/series/$tmdbId';
    await _keys.send(
      commandFingerprint('DELETE', path, null),
      (key) => _api.delete(path, idempotencyKey: key),
    );
  }

  @override
  Future<Paged<EpisodeViewingRecord>> viewings({String? cursor}) async {
    final body = await _api.get(
      '/api/v1/episode-viewings',
      query: {'limit': 20, 'cursor': ?cursor},
    );
    return Paged([
      for (final v in asList(body['items'])) episodeViewingFromJson(asMap(v)),
    ], body['next_cursor'] as String?);
  }

  @override
  Future<EpisodeWatchedResult> markNextWatched(
    int tmdbId, {
    required int season,
    required int episode,
    Rating? rating,
  }) async {
    final path = '/api/v1/series/$tmdbId/episodes/watched';
    final request = {
      'season': season,
      'episode': episode,
      'rating': ?rating?.value,
    };
    final body = await _keys.send(
      commandFingerprint('POST', path, request),
      (key) => _api.post(path, body: request, idempotencyKey: key),
    );
    final recorded = body['already_recorded'];
    final viewing = asMap(body['viewing']);
    if (recorded is! bool || viewing['id'] is! String) throw malformedResponse;
    return EpisodeWatchedResult(
      entry: showEntryFromJson(asMap(body['entry'])),
      viewingId: viewing['id'] as String,
      alreadyRecorded: recorded,
    );
  }
}
