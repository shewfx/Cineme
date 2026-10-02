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

/// TodayEnvelope states implemented so far (API_CONTRACT precedence).
enum TodayStatus { notStarted, emptyWatchlist, offered }

/// TodayEnvelope subset: at most one current recommendation plus its context.
/// `offered` always carries both; other states carry neither.
class TodayEnvelope {
  const TodayEnvelope({required this.state, this.context, this.recommendation})
    : assert((state == TodayStatus.offered) == (recommendation != null));

  const TodayEnvelope.notStarted() : this(state: TodayStatus.notStarted);

  const TodayEnvelope.emptyWatchlist()
    : this(state: TodayStatus.emptyWatchlist);

  final TodayStatus state;
  final SessionContext? context;
  final Recommendation? recommendation;
}
