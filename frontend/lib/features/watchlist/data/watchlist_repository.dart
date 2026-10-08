import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/idempotency.dart';
import '../../../core/network/movie_dto.dart';
import '../../../core/network/series_dto.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';

abstract interface class WatchlistRepository {
  /// GET /watchlist: active entries in [sort] order (default newest first),
  /// [pageSize] per page. A cursor belongs to the sort that produced it.
  Future<Paged<WatchlistEntry>> list({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
  });

  /// GET /watchlist across films and shows, filtered server-side by [media]
  /// (display only: it never changes data). Each item names its media type.
  Future<Paged<WatchlistItem>> items({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
    WatchlistMedia media = WatchlistMedia.all,
  });

  /// POST /watchlist. A duplicate succeeds with `alreadyPresent`; conflicts
  /// throw [InventoryConflict].
  Future<WatchlistAddResult> add(int tmdbId);

  /// DELETE /watchlist/{id}: archives the entry; already removed succeeds.
  Future<void> remove(String entryId);
}

const pageSize = 20;

/// Null in builds without a backend; the preview overrides it with a fake.
final watchlistRepositoryProvider = Provider<WatchlistRepository?>(
  (ref) => null,
);

/// Real build: the caller's watchlist through the Cinemé API. Membership is
/// inventory only; nothing here touches taste or preferences.
class ApiWatchlistRepository implements WatchlistRepository {
  ApiWatchlistRepository(this._api);

  final ApiClient _api;

  /// Same command after an ambiguous failure -> same key (server replay).
  final _keys = RetryKeys();

  @override
  Future<Paged<WatchlistEntry>> list({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
  }) async {
    final body = await _api.get(
      '/api/v1/watchlist',
      // Films only: shows have their own item type (see [items]).
      query: {
        'limit': pageSize,
        'sort': sort.apiValue,
        'media': 'movies',
        'cursor': ?cursor,
      },
    );
    return Paged([
      for (final e in asList(body['items'])) watchlistEntryFromJson(asMap(e)),
    ], body['next_cursor'] as String?);
  }

  @override
  Future<Paged<WatchlistItem>> items({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
    WatchlistMedia media = WatchlistMedia.all,
  }) async {
    final body = await _api.get(
      '/api/v1/watchlist',
      query: {
        'limit': pageSize,
        'sort': sort.apiValue,
        'media': media.wireName,
        'cursor': ?cursor,
      },
    );
    return Paged([
      for (final e in asList(body['items'])) watchlistItemFromJson(asMap(e)),
    ], body['next_cursor'] as String?);
  }

  @override
  Future<WatchlistAddResult> add(int tmdbId) async {
    try {
      final request = {'tmdb_id': tmdbId};
      final body = await _keys.send(
        commandFingerprint('POST', '/api/v1/watchlist', request),
        (key) =>
            _api.post('/api/v1/watchlist', body: request, idempotencyKey: key),
      );
      final already = body['already_present'];
      if (already is! bool) throw malformedResponse;
      return WatchlistAddResult(
        entry: watchlistEntryFromJson(asMap(body['entry'])),
        alreadyPresent: already,
      );
    } on ApiError catch (e) {
      throw _conflicts.contains(e.code) ? InventoryConflict(e.code) : e;
    }
  }

  @override
  Future<void> remove(String entryId) async {
    final path = '/api/v1/watchlist/${Uri.encodeComponent(entryId)}';
    await _keys.send(
      commandFingerprint('DELETE', path, null),
      (key) => _api.delete(path, idempotencyKey: key),
    );
  }

  /// Documented outcomes the UI explains rather than treating as failures.
  static const _conflicts = {
    'MOVIE_INELIGIBLE',
    'MOVIE_ALREADY_WATCHED',
    'MOVIE_BLOCKED',
    'WATCHLIST_LIMIT',
  };
}
