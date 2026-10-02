import 'movie.dart';
import 'session_context.dart';
import 'viewing.dart';

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

/// No known genre matches the intent: an honest weak match, not hidden.
class WeakIntentMatch extends Reason {
  const WeakIntentMatch(this.intent);

  final DesiredExperience intent;
}

class Recommendation {
  const Recommendation({
    required this.id,
    required this.movie,
    required this.reasons,
    this.status = RecommendationStatus.offered,
  });

  final String id;
  final Movie movie;
  final List<Reason> reasons;

  /// offered, accepted (Watch Tonight) or watched (Mark watched).
  final RecommendationStatus status;

  Recommendation withStatus(RecommendationStatus s) =>
      Recommendation(id: id, movie: movie, reasons: reasons, status: s);
}

/// Primary exclusion codes, in the engine's precedence order.
enum ExclusionCode {
  movieBlocked('never recommend'),
  offeredThisSession('already offered tonight'),
  genreBlocked('in a genre you avoided tonight'),
  runtimeUnknown('runtime unknown under your time limit'),
  runtimeExceeded('longer than your time limit');

  const ExclusionCode(this.label);

  final String label;
}

/// Aggregate no-match explanation; counts sum to [candidateCount].
class NoMatchSummary {
  const NoMatchSummary({required this.candidateCount, required this.counts});

  final int candidateCount;
  final Map<ExclusionCode, int> counts;
}

/// Today states (API_CONTRACT precedence).
enum TodayStatus {
  notStarted,
  ready,
  offered,
  accepted,
  completed,
  paused,
  noMatch,
  emptyWatchlist,
}

/// TodayEnvelope: at most ONE current recommendation plus the saved context.
class TodayEnvelope {
  const TodayEnvelope({
    required this.state,
    this.context,
    this.recommendation,
    this.noMatch,
    this.viewing,
    this.rejectionCount = 0,
  });

  const TodayEnvelope.notStarted() : this(state: TodayStatus.notStarted);

  const TodayEnvelope.emptyWatchlist()
    : this(state: TodayStatus.emptyWatchlist);

  final TodayStatus state;
  final SessionContext? context;

  /// Set for offered, accepted and completed.
  final Recommendation? recommendation;
  final NoMatchSummary? noMatch;

  /// Tonight's viewing once completed; carries the optional rating.
  final Viewing? viewing;
  final int rejectionCount;
}

/// Rejection reason codes (PROJECT_SPEC feedback semantics).
enum RejectReason {
  notTonight('not_tonight'),
  tooLong('too_long'),
  wantLighter('want_lighter'),
  wrongGenre('wrong_genre'),
  alreadyWatched('already_watched'),
  neverRecommend('never_recommend');

  const RejectReason(this.wireName);

  final String wireName;
}

enum ReplacementOutcome { selected, noMatch, paused, notRequested }

class RejectResult {
  const RejectResult({required this.outcome, required this.today});

  final ReplacementOutcome outcome;
  final TodayEnvelope today;
}

/// Documented 409/422 codes the UI must handle, e.g. CONTEXT_REVIEW_REQUIRED.
class TodayConflict implements Exception {
  const TodayConflict(this.code);

  final String code;

  @override
  String toString() => 'TodayConflict($code)';
}
