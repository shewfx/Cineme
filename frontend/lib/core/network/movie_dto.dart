import '../../shared/models/inventory.dart';
import '../../shared/models/movie.dart';
import 'api_client.dart';

/// API JSON -> app models. A missing required field is a visible error, not
/// an empty result; nullable fields stay null (unknown runtime is never 0).

const malformedResponse = ApiError(
  status: 200,
  code: 'MALFORMED_RESPONSE',
  message: 'Cinemé sent an unexpected response.',
);

T _req<T>(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is T) return v;
  throw malformedResponse;
}

T? _opt<T>(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is T) return v;
  throw malformedResponse;
}

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw malformedResponse;
}

List<Object?> asList(Object? value) {
  if (value is List<Object?>) return value;
  throw malformedResponse;
}

/// MovieSummary -> (Movie, can_add).
(Movie, bool) movieSummaryFromJson(Map<String, dynamic> json) {
  final genres = [
    for (final g in asList(json['genres']))
      Genre(_req<int>(asMap(g), 'id'), _req<String>(asMap(g), 'name')),
  ];
  return (
    Movie(
      tmdbId: _req<int>(json, 'tmdb_id'),
      title: _req<String>(json, 'title'),
      year: _opt<int>(json, 'year'),
      runtimeMinutes: _opt<int>(json, 'runtime_minutes'),
      genres: genres,
      posterUrl: _opt<String>(json, 'poster_url'),
      voteAverage: _opt<num>(json, 'vote_average')?.toDouble(),
      released: _req<bool>(json, 'released'),
    ),
    _req<bool>(json, 'can_add'),
  );
}

WatchlistEntry watchlistEntryFromJson(Map<String, dynamic> json) {
  final added = DateTime.tryParse(_req<String>(json, 'added_at'));
  if (added == null) throw malformedResponse;
  return WatchlistEntry(
    id: _req<String>(json, 'id'),
    movie: movieSummaryFromJson(asMap(json['movie'])).$1,
    addedAt: added,
  );
}
