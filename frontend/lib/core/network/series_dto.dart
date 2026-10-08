import '../../shared/models/inventory.dart';
import '../../shared/models/movie.dart';
import '../../shared/models/series.dart';
import 'movie_dto.dart';

/// API JSON -> show models. A missing required field is a visible error;
/// nullable fields stay null (unknown runtime or air date is never guessed).

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

Series seriesFromJson(Map<String, dynamic> json) => Series(
  tmdbId: _req<int>(json, 'tmdb_id'),
  name: _req<String>(json, 'name'),
  year: _opt<int>(json, 'year'),
  genres: [
    for (final g in asList(json['genres']))
      Genre(_req<int>(asMap(g), 'id'), _req<String>(asMap(g), 'name')),
  ],
  posterUrl: _opt<String>(json, 'poster_url'),
  status: _opt<String>(json, 'status'),
  voteAverage: _opt<num>(json, 'vote_average')?.toDouble(),
  canAdd: _req<bool>(json, 'can_add'),
);

DateTime? _date(Map<String, dynamic> json, String key) {
  final raw = _opt<String>(json, key);
  if (raw == null) return null;
  final d = DateTime.tryParse(raw);
  if (d == null) throw malformedResponse;
  return d;
}

Episode episodeFromJson(Map<String, dynamic> json) => Episode(
  seasonNumber: _req<int>(json, 'season_number'),
  episodeNumber: _req<int>(json, 'episode_number'),
  name: _opt<String>(json, 'name'),
  airDate: _date(json, 'air_date'),
  runtimeMinutes: _opt<int>(json, 'runtime_minutes'),
);

NextEpisode nextEpisodeFromJson(Map<String, dynamic> json) {
  final raw = _req<String>(json, 'state');
  final state = NextState.values.where((s) => s.wireName == raw);
  if (state.isEmpty) throw malformedResponse;
  final episode = json['episode'];
  return NextEpisode(
    state: state.first,
    episode: episode == null ? null : episodeFromJson(asMap(episode)),
  );
}

ShowEntry showEntryFromJson(Map<String, dynamic> json) {
  final added = DateTime.tryParse(_req<String>(json, 'added_at'));
  if (added == null) throw malformedResponse;
  final progress = json['progress'];
  return ShowEntry(
    id: _req<String>(json, 'id'),
    series: seriesFromJson(asMap(json['series'])),
    addedAt: added,
    progress: progress == null
        ? null
        : SeriesProgress(
            season: _req<int>(asMap(progress), 'season'),
            episode: _req<int>(asMap(progress), 'episode'),
            version: _req<int>(asMap(progress), 'version'),
          ),
    progressVersion: _req<int>(json, 'progress_version'),
    next: nextEpisodeFromJson(asMap(json['next'])),
    seriesRating: _opt<int>(json, 'series_rating'),
  );
}

/// A watchlist item names its media type; a missing type is a movie (older
/// backends), anything unknown is an error.
WatchlistItem watchlistItemFromJson(Map<String, dynamic> json) {
  final type = json['media_type'] ?? 'movie';
  return switch (type) {
    'movie' => MovieItem(watchlistEntryFromJson(json)),
    'series' => ShowItem(showEntryFromJson(json)),
    _ => throw malformedResponse,
  };
}

EpisodeViewingRecord episodeViewingFromJson(Map<String, dynamic> json) {
  final recorded = DateTime.tryParse(_req<String>(json, 'recorded_at'));
  if (recorded == null) throw malformedResponse;
  return EpisodeViewingRecord(
    id: _req<String>(json, 'id'),
    series: seriesFromJson(asMap(json['series'])),
    seasonNumber: _req<int>(json, 'season_number'),
    episodeNumber: _req<int>(json, 'episode_number'),
    episodeName: _opt<String>(json, 'episode_name'),
    watchedAt: _date(json, 'watched_at'),
    recordedAt: recorded,
    rating: _opt<int>(json, 'rating'),
    version: _opt<int>(json, 'version') ?? 1,
  );
}

SeriesDetails seriesDetailsFromJson(Map<String, dynamic> json) {
  final entry = json['entry'];
  return SeriesDetails(
    series: seriesFromJson(asMap(json['series'])),
    overview: _opt<String>(json, 'overview'),
    seasonCount: _req<int>(json, 'season_count'),
    stale: _req<bool>(json, 'stale'),
    limitations: _req<String>(json, 'limitations'),
    entry: entry == null ? null : showEntryFromJson(asMap(entry)),
  );
}

List<SeasonInfo> seasonsFromJson(Map<String, dynamic> json) => [
  for (final s in asList(json['seasons']))
    SeasonInfo(
      number: _req<int>(asMap(s), 'season_number'),
      episodes: [
        for (final e in asList(asMap(s)['episodes'])) episodeFromJson(asMap(e)),
      ],
    ),
];
