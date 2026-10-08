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
    this.region,
    this.regionChosen = false,
    this.onboardingComplete = true,
  });

  final String? displayName;

  /// IANA zone; "UTC" until the user sets a validated one.
  final String timezone;
  final List<Genre> preferredGenres;
  final List<Genre> blockedGenres;
  final int? defaultMaxRuntimeMinutes;
  final bool aiContextEnabled;

  /// Null when the build cannot list blocks yet (GET /me/blocks arrives
  /// with blocks in P5); never shown as "None" in that case.
  final List<Movie>? blockedMovies;

  /// Streaming region (ISO country) for "Available on": the user's choice,
  /// else the one the time zone implies; null when unknown.
  final String? region;

  /// Whether [region] was chosen rather than derived from the time zone.
  final bool regionChosen;

  /// False only when the server says this new account has not finished
  /// onboarding. A response without the field (an older backend) counts as
  /// complete: a client never forces onboarding on ambiguity.
  final bool onboardingComplete;
}
