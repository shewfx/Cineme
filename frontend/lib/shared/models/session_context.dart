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

/// Accepted SessionContext (API_CONTRACT); advanced fields arrive later.
class SessionContext {
  const SessionContext({
    required this.desiredExperience,
    this.currentMood,
    this.maxRuntimeMinutes,
  });

  final DesiredExperience desiredExperience;
  final CurrentMood? currentMood;

  /// Inclusive hard cap; null means no limit.
  final int? maxRuntimeMinutes;
}
