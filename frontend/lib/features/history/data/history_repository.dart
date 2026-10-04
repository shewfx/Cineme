import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/idempotency.dart';
import '../../../core/network/movie_dto.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/viewing.dart';

abstract interface class HistoryRepository {
  /// GET /viewings: newest watched (or recorded) first.
  Future<Paged<Viewing>> viewings({String? cursor});

  /// GET /recommendations: newest first, including cleared picks.
  Future<Paged<RecommendationRecord>> recommendations({String? cursor});

  /// POST /viewings: logs a known past viewing with an unknown date and no
  /// rating. Never completes Tonight.
  Future<RecordWatchedResult> recordAlreadyWatched(int tmdbId);

  /// PATCH /viewings/{id}: replaces the rating (null clears it). Long-term
  /// taste evidence; never changes tonight's pick.
  Future<Viewing> rateViewing(
    String viewingId,
    Rating? rating, {
    int expectedVersion = 1,
  });

  Future<RecordWatchedResult> recordManual(int tmdbId);
}

class ApiHistoryRepository implements HistoryRepository {
  ApiHistoryRepository(this._api);
  final ApiClient _api;
  final _keys = RetryKeys();

  @override
  Future<Paged<Viewing>> viewings({String? cursor}) async {
    final json = await _api.get(
      '/api/v1/viewings',
      query: {
        'limit': 20,
        ...?(cursor == null ? null : {'cursor': cursor}),
      },
    );
    return Paged([
      for (final row in asList(json['items'])) _viewingFromJson(asMap(row)),
    ], json['next_cursor'] as String?);
  }

  @override
  Future<Paged<RecommendationRecord>> recommendations({String? cursor}) async {
    final json = await _api.get(
      '/api/v1/recommendations',
      query: {
        'limit': 20,
        ...?(cursor == null ? null : {'cursor': cursor}),
      },
    );
    return Paged([
      for (final row in asList(json['items']))
        _recommendationFromJson(asMap(row)),
    ], json['next_cursor'] as String?);
  }

  @override
  Future<RecordWatchedResult> recordAlreadyWatched(int tmdbId) =>
      _record(tmdbId);

  @override
  Future<RecordWatchedResult> recordManual(int tmdbId) => _record(tmdbId);

  Future<RecordWatchedResult> _record(int tmdbId) async {
    const path = '/api/v1/viewings';
    final body = {'tmdb_id': tmdbId};
    final json = await _keys.send(
      commandFingerprint('POST', path, body),
      (key) => _api.post(path, body: body, idempotencyKey: key),
    );
    return RecordWatchedResult(
      viewing: _viewingFromJson(asMap(json['viewing'])),
      alreadyRecorded: json['already_recorded'] as bool? ?? false,
    );
  }

  @override
  Future<Viewing> rateViewing(
    String viewingId,
    Rating? rating, {
    int expectedVersion = 1,
  }) async {
    final path = '/api/v1/viewings/${Uri.encodeComponent(viewingId)}';
    final body = {'expected_version': expectedVersion, 'rating': rating?.name};
    final json = await _keys.send(
      commandFingerprint('PATCH', path, body),
      (key) => _api.patch(path, body: body, idempotencyKey: key),
    );
    return _viewingFromJson(json);
  }
}

Viewing _viewingFromJson(Map<String, dynamic> json) {
  final watched = json['watched_at'];
  final recorded = DateTime.tryParse(json['recorded_at'] as String? ?? '');
  final rating = json['rating'];
  if (recorded == null || (watched != null && watched is! String)) {
    throw malformedResponse;
  }
  return Viewing(
    id: json['id'] as String,
    movie: movieSummaryFromJson(asMap(json['movie'])).$1,
    watchedAt: watched == null ? null : DateTime.tryParse(watched as String),
    recordedAt: recorded,
    rating: rating == null
        ? null
        : Rating.values.firstWhere(
            (value) => value.name == rating,
            orElse: () => throw malformedResponse,
          ),
    version: json['version'] as int? ?? 1,
  );
}

RecommendationRecord _recommendationFromJson(Map<String, dynamic> json) {
  final status = switch (json['status']) {
    'offered' => RecommendationStatus.offered,
    'accepted' => RecommendationStatus.accepted,
    'rejected' => RecommendationStatus.rejected,
    'watched' => RecommendationStatus.watched,
    'superseded' => RecommendationStatus.superseded,
    'no_match' => RecommendationStatus.noMatch,
    _ => throw malformedResponse,
  };
  final created = DateTime.tryParse(json['created_at'] as String? ?? '');
  if (created == null) throw malformedResponse;
  return RecommendationRecord(
    id: json['id'] as String,
    movie: json['movie'] == null
        ? null
        : movieSummaryFromJson(asMap(json['movie'])).$1,
    status: status,
    createdAt: created,
    desiredExperience: DesiredExperience.values.firstWhere(
      (value) => value.wireName == json['desired_experience'],
      orElse: () => throw malformedResponse,
    ),
  );
}

/// Null until the real API repository exists; preview overrides it.
final historyRepositoryProvider = Provider<HistoryRepository?>((ref) => null);
