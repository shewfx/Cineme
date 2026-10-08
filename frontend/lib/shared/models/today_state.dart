import 'movie.dart';
import 'series.dart';
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

/// A reason rendered by the server's deterministic template and stored with
/// the pick, so old cards keep their wording.
class ServerReason extends Reason {
  const ServerReason(this.text, {this.uncertain = false});

  final String text;

  /// An unknown requested fact, not a positive reason.
  final bool uncertain;
}

class Recommendation {
  const Recommendation({
    required this.id,
    required this.movie,
    required this.reasons,
    this.status = RecommendationStatus.offered,
    this.episode,
  });

  final String id;

  /// What to draw. For an episode pick this is the show (see [episode]).
  final Movie movie;
  final List<Reason> reasons;

  /// Set when Tonight's pick is an episode rather than a film.
  final EpisodeCard? episode;
  bool get isEpisode => episode != null;

  /// offered, accepted (Watch Tonight) or watched (Mark watched).
  final RecommendationStatus status;

  Recommendation withStatus(RecommendationStatus s) => Recommendation(
    id: id,
    movie: movie,
    reasons: reasons,
    status: s,
    episode: episode,
  );
}

/// Primary exclusion codes, in the engine's precedence order.
enum ExclusionCode {
  movieUnavailable('movie_unavailable', 'not released yet'),
  seriesUnavailable(
    'series_unavailable',
    'shows whose episodes could not load',
  ),
  seriesCompleted('series_completed', 'shows you have finished'),
  seriesCaughtUp('series_caught_up', 'shows you are caught up on'),
  nextEpisodeNotAired(
    'next_episode_not_aired',
    'shows whose next episode has not aired',
  ),
  alreadyWatched('already_watched', 'already watched'),
  movieBlocked('movie_blocked', 'never recommend'),
  seriesBlocked('series_blocked', 'shows set to never recommend'),
  offeredThisSession('offered_this_session', 'already offered tonight'),
  genreBlocked('genre_blocked', 'in a genre you avoided tonight'),
  runtimeUnknown('runtime_unknown', 'runtime unknown under your time limit'),
  runtimeExceeded('runtime_exceeded', 'longer than your time limit');

  const ExclusionCode(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// Aggregate no-match explanation; counts sum to [candidateCount].
class NoMatchSummary {
  const NoMatchSummary({
    required this.candidateCount,
    required this.counts,
    this.hiddenByPreference = 0,
  });

  final int candidateCount;
  final Map<ExclusionCode, int> counts;

  /// Titles of the other media, hidden by the Tonight preference (not part of
  /// [counts]); shown so nobody wonders where their films went.
  final int hiddenByPreference;
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
    this.followUp,
    this.rejectionCount = 0,
    this.media,
    this.emptyReason,
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
  final FollowUpPrompt? followUp;
  final int rejectionCount;

  /// What Tonight considers (null from a backend without shows).
  final TonightMedia? media;

  /// For [TodayStatus.emptyWatchlist]: `none`, `no_movies` or `no_shows`.
  final String? emptyReason;
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

enum ReplacementOutcome { selected, noMatch, paused, dailyLimit, notRequested }

class RejectResult {
  const RejectResult({required this.outcome, required this.today});

  final ReplacementOutcome outcome;
  final TodayEnvelope today;
}

/// The winner's stored score breakdown for the Why drawer.
class WhyBreakdown {
  const WhyBreakdown({
    required this.weights,
    required this.contributions,
    required this.engineVersion,
    required this.configVersion,
  });

  final Map<String, double> weights;
  final Map<String, double> contributions;
  final String engineVersion;
  final String configVersion;
}

/// Documented 409/422 codes the UI must handle, e.g. CONTEXT_REVIEW_REQUIRED.
class TodayConflict implements Exception {
  const TodayConflict(this.code);

  final String code;

  @override
  String toString() => 'TodayConflict($code)';
}
