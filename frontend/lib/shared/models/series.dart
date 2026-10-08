import 'movie.dart';

/// Fields every poster and row needs, shared by films and shows so one widget
/// draws both. Identity is never inferred from these: always carry the
/// [MediaType] (TMDB movie and TV ids overlap).
abstract interface class TitleInfo {
  int get tmdbId;
  String get title;
  int? get year;
  List<Genre> get genres;
  String? get posterUrl;
}

enum MediaType { movie, series }

/// A TV series (anime included) as the API summarizes it.
class Series implements TitleInfo {
  const Series({
    required this.tmdbId,
    required this.name,
    required this.year,
    required this.genres,
    this.posterUrl,
    this.status,
    this.voteAverage,
    this.canAdd = true,
  });

  @override
  final int tmdbId;
  final String name;
  @override
  final int? year;
  @override
  final List<Genre> genres;
  @override
  final String? posterUrl;

  /// TMDB status, for example "Returning Series" or "Ended".
  final String? status;
  final double? voteAverage;
  final bool canAdd;

  @override
  String get title => name;
}

/// One regular episode. Unknown air date or runtime stay null.
class Episode {
  const Episode({
    required this.seasonNumber,
    required this.episodeNumber,
    this.name,
    this.airDate,
    this.runtimeMinutes,
  });

  final int seasonNumber;
  final int episodeNumber;
  final String? name;
  final DateTime? airDate;
  final int? runtimeMinutes;

  /// "S1 E5"
  String get code => 'S$seasonNumber E$episodeNumber';
}

/// Where a show stands relative to the saved progress.
enum NextState {
  upNext('up_next'),
  notAired('not_aired'),
  caughtUp('caught_up'),
  completed('completed'),
  unavailable('unavailable');

  const NextState(this.wireName);

  final String wireName;
}

class NextEpisode {
  const NextEpisode({required this.state, this.episode});

  final NextState state;
  final Episode? episode;
}

class SeriesProgress {
  const SeriesProgress({
    required this.season,
    required this.episode,
    required this.version,
  });

  final int season;
  final int episode;
  final int version;

  String get label => 'S$season E$episode';
}

/// A show on the caller's watchlist with its saved progress.
class ShowEntry {
  const ShowEntry({
    required this.id,
    required this.series,
    required this.addedAt,
    required this.progress,
    required this.progressVersion,
    required this.next,
    this.seriesRating,
  });

  final String id;
  final Series series;
  final DateTime addedAt;
  final SeriesProgress? progress;
  final int progressVersion;
  final NextEpisode next;
  final int? seriesRating;
}

class SeriesDetails {
  const SeriesDetails({
    required this.series,
    required this.overview,
    required this.seasonCount,
    required this.stale,
    required this.limitations,
    required this.entry,
  });

  final Series series;
  final String? overview;
  final int seasonCount;
  final bool stale;
  final String limitations;
  final ShowEntry? entry;
}

class SeasonInfo {
  const SeasonInfo({required this.number, required this.episodes});

  final int number;
  final List<Episode> episodes;
}

/// A watched episode (History). Its rating belongs to the episode, never to
/// the show or to film taste.
class EpisodeViewingRecord {
  const EpisodeViewingRecord({
    required this.id,
    required this.series,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.recordedAt,
    this.episodeName,
    this.watchedAt,
    this.rating,
    this.version = 1,
  });

  final String id;
  final Series series;
  final int seasonNumber;
  final int episodeNumber;
  final String? episodeName;
  final DateTime? watchedAt;
  final DateTime recordedAt;
  final int? rating;
  final int version;

  String get code => 'S$seasonNumber E$episodeNumber';
}

class SeriesSearchPage {
  const SeriesSearchPage({
    required this.page,
    required this.totalPages,
    required this.results,
  });

  final int page;
  final int totalPages;
  final List<Series> results;
}

/// What Tonight considers (a saved, server-side preference).
enum TonightMedia {
  movies('movies', 'Movies only'),
  moviesAndShows('movies_and_shows', 'Movies & shows'),
  shows('shows', 'Shows only');

  const TonightMedia(this.wireName, this.label);

  final String wireName;
  final String label;

  static TonightMedia? fromWire(Object? raw) {
    for (final m in values) {
      if (m.wireName == raw) return m;
    }
    return null;
  }
}

/// What the Watchlist tab shows. Display only: never changes data.
enum WatchlistMedia {
  all('all', 'All'),
  movies('movies', 'Movies only'),
  shows('shows', 'Shows only');

  const WatchlistMedia(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// The one episode behind an episode recommendation: the show plus the show's
/// next episode. [continuesSeries] marks a pick boosted by recent confirmed
/// watching (the server explains it; this only labels the card).
class EpisodeCard {
  const EpisodeCard({
    required this.series,
    required this.episode,
    this.continuesSeries = false,
  });

  final Series series;
  final Episode episode;
  final bool continuesSeries;

  /// The show drawn as a poster/hero. Display only: its id is a TV id, so
  /// nothing may use it for a movie lookup.
  Movie get display => Movie(
    tmdbId: series.tmdbId,
    title: series.name,
    year: series.year,
    runtimeMinutes: episode.runtimeMinutes,
    genres: series.genres,
    posterUrl: series.posterUrl,
    voteAverage: series.voteAverage,
  );
}
