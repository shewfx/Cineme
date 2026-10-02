import 'movie.dart';

/// GET /me with preferences, plus the blocked-movie list for the Profile shell.
class Profile {
  const Profile({
    required this.displayName,
    required this.timezone,
    required this.preferredGenres,
    required this.blockedGenres,
    required this.defaultMaxRuntimeMinutes,
    required this.aiContextEnabled,
    required this.blockedMovies,
  });

  final String? displayName;

  /// IANA zone; "UTC" until the user sets a validated one.
  final String timezone;
  final List<Genre> preferredGenres;
  final List<Genre> blockedGenres;
  final int? defaultMaxRuntimeMinutes;
  final bool aiContextEnabled;
  final List<Movie> blockedMovies;
}
