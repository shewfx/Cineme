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
  });

  final int tmdbId;
  final String title;
  final int? year;

  /// Null means "Runtime unavailable", never zero.
  final int? runtimeMinutes;
  final List<Genre> genres;
  final String? posterUrl;
}
