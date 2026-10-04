/// MovieSummary from API_CONTRACT. Only the fields the UI uses so far.
class Genre {
  const Genre(this.id, this.name);

  final int id;
  final String name;
}

class Movie {
  const Movie({
    required this.tmdbId,
    required this.title,
    required this.year,
    required this.runtimeMinutes,
    required this.genres,
    this.posterUrl,
    this.voteAverage,
    this.released = true,
  });

  final int tmdbId;
  final String title;
  final int? year;

  /// Null means "Runtime unavailable", never zero.
  final int? runtimeMinutes;
  final List<Genre> genres;
  final String? posterUrl;

  /// TMDB community rating (0-10), display-only. Null means unknown; it is
  /// never shown as 0.0 or a placeholder.
  final double? voteAverage;

  /// Known release date on or before the user's local date. Upcoming and
  /// unknown-date films can be saved but are never Tonight-eligible.
  final bool released;
}
