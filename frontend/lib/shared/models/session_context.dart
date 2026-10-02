/// Optional emotion. Recorded for display only; it never scores or picks an
/// intent (PROJECT_SPEC "Context and uncertainty").
enum CurrentMood {
  down('down', 'Down'),
  tired('tired', 'Tired'),
  okay('okay', 'Okay'),
  upbeat('upbeat', 'Upbeat');

  const CurrentMood(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// What the user wants the movie to do. Required before an initial pick.
enum DesiredExperience {
  makeMeLaugh('make_me_laugh', 'Make me laugh'),
  keepMeHooked('keep_me_hooked', 'Keep me hooked'),
  relax('relax', 'Relaxing'),
  deep('deep', 'Deep'),
  exciting('exciting', 'Exciting'),
  comfort('comfort', 'Comforting'),
  feelIt('feel_it', 'Let me feel it'),
  surprise('surprise', 'Surprise me');

  const DesiredExperience(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// Documented follow-ups when the user says they feel down. Each maps to an
/// intent the user must still tap; nothing is selected automatically.
const downFollowUps = <(String, DesiredExperience)>[
  ('Cheer me up', DesiredExperience.makeMeLaugh),
  ('Something comforting', DesiredExperience.comfort),
  ('Let me feel it', DesiredExperience.feelIt),
  ('Surprise me', DesiredExperience.surprise),
];

/// Accepted SessionContext (API_CONTRACT). Pace/complexity arrive later.
class SessionContext {
  const SessionContext({
    required this.desiredExperience,
    this.currentMood,
    this.maxRuntimeMinutes,
    this.avoidGenreIds = const {},
    this.heavinessMax,
  });

  final DesiredExperience desiredExperience;
  final CurrentMood? currentMood;

  /// Inclusive hard cap; null means no limit.
  final int? maxRuntimeMinutes;

  /// Tonight's avoided genres: hard exclusions for this session only.
  final Set<int> avoidGenreIds;

  /// Soft trait target. Unknown traits stay unknown; preview films have none.
  final double? heavinessMax;

  /// Effective scoring fields only. Mood never decides invalidation.
  bool sameScoringAs(SessionContext other) =>
      desiredExperience == other.desiredExperience &&
      maxRuntimeMinutes == other.maxRuntimeMinutes &&
      heavinessMax == other.heavinessMax &&
      avoidGenreIds.length == other.avoidGenreIds.length &&
      avoidGenreIds.containsAll(other.avoidGenreIds);

  SessionContext copyWith({
    DesiredExperience? desiredExperience,
    CurrentMood? Function()? currentMood,
    int? Function()? maxRuntimeMinutes,
    Set<int>? avoidGenreIds,
    double? Function()? heavinessMax,
  }) => SessionContext(
    desiredExperience: desiredExperience ?? this.desiredExperience,
    currentMood: currentMood != null ? currentMood() : this.currentMood,
    maxRuntimeMinutes: maxRuntimeMinutes != null
        ? maxRuntimeMinutes()
        : this.maxRuntimeMinutes,
    avoidGenreIds: avoidGenreIds ?? this.avoidGenreIds,
    heavinessMax: heavinessMax != null ? heavinessMax() : this.heavinessMax,
  );
}
