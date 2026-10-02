import 'movie.dart';
import 'session_context.dart';

/// Factual reason, rendered by a deterministic template (API_CONTRACT reasons).
sealed class Reason {
  const Reason();
}

/// `fits_runtime`: the film is within the user's inclusive cap.
class FitsRuntime extends Reason {
  const FitsRuntime({required this.runtimeMinutes, required this.capMinutes});

  final int runtimeMinutes;
  final int capMinutes;
}

/// One of the film's genres approximately matches the chosen intent.
class GenreMatchesIntent extends Reason {
  const GenreMatchesIntent({required this.genre, required this.intent});

  final Genre genre;
  final DesiredExperience intent;
}

/// The user chose Surprise me, so no intent match was applied.
class SurpriseChosen extends Reason {
  const SurpriseChosen();
}

class Recommendation {
  const Recommendation({
    required this.id,
    required this.movie,
    required this.reasons,
  });

  final String id;
  final Movie movie;
  final List<Reason> reasons;
}

enum TodayStatus { offered }

/// TodayEnvelope subset: one current recommendation plus the context it used.
class TodayEnvelope {
  const TodayEnvelope({
    required this.state,
    required this.context,
    required this.recommendation,
  });

  final TodayStatus state;
  final SessionContext context;
  final Recommendation recommendation;
}
