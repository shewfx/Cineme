import '../../../core/network/movie_dto.dart';
import '../../../core/network/series_dto.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../../shared/models/viewing.dart';

/// TodayEnvelope JSON -> app models. Unknown states or codes are a visible
/// malformed-response error, never a guess.

T _byWire<T>(Iterable<T> values, String Function(T) wire, Object? raw) {
  for (final v in values) {
    if (wire(v) == raw) return v;
  }
  throw malformedResponse;
}

T? _optByWire<T extends Object>(
  Iterable<T> values,
  String Function(T) wire,
  Object? raw,
) => raw == null ? null : _byWire<T>(values, wire, raw);

const _states = {
  'not_started': TodayStatus.notStarted,
  'ready': TodayStatus.ready,
  'offered': TodayStatus.offered,
  'accepted': TodayStatus.accepted,
  'completed': TodayStatus.completed,
  'paused': TodayStatus.paused,
  'no_match': TodayStatus.noMatch,
  'empty_watchlist': TodayStatus.emptyWatchlist,
};

const _statuses = {
  'offered': RecommendationStatus.offered,
  'accepted': RecommendationStatus.accepted,
  'watched': RecommendationStatus.watched,
};

SessionContext sessionContextFromJson(Map<String, dynamic> json) {
  final cap = json['max_runtime_minutes'];
  final heaviness = json['heaviness_max'];
  if ((cap != null && cap is! int) ||
      (heaviness != null && heaviness is! num)) {
    throw malformedResponse;
  }
  return SessionContext(
    desiredExperience: _byWire(
      DesiredExperience.values,
      (d) => d.wireName,
      json['desired_experience'],
    ),
    currentMood: _optByWire(
      CurrentMood.values,
      (m) => m.wireName,
      json['current_mood'],
    ),
    maxRuntimeMinutes: cap as int?,
    avoidGenreIds: {for (final g in asList(json['avoid_genre_ids'])) g as int},
    heavinessMax: (heaviness as num?)?.toDouble(),
  );
}

/// Complete replacement context for PATCH/choose. Fields the app doesn't
/// edit yet (pace, complexity, preferred genres) are sent as unset.
Map<String, Object?> sessionContextToJson(SessionContext c) => {
  'current_mood': c.currentMood?.wireName,
  'desired_experience': c.desiredExperience.wireName,
  'max_runtime_minutes': c.maxRuntimeMinutes,
  'heaviness_max': c.heavinessMax,
  'avoid_genre_ids': (c.avoidGenreIds.toList()..sort()),
};

/// The episode payload of a recommendation, viewing or follow-up.
EpisodeCard episodeCardFromJson(Map<String, dynamic> json) {
  final continues = json['continues_series'];
  return EpisodeCard(
    series: seriesFromJson(asMap(json['series'])),
    episode: episodeFromJson(json),
    continuesSeries: continues == true,
  );
}

List<Reason> _reasons(Object? raw, {bool uncertain = false}) => [
  for (final r in asList(raw))
    ServerReason(asMap(r)['text'] as String, uncertain: uncertain),
];

TodayEnvelope todayEnvelopeFromJson(Map<String, dynamic> json) {
  final state = _states[json['state']];
  if (state == null) throw malformedResponse;
  final session = json['session'] == null ? null : asMap(json['session']);
  final rec = json['recommendation'] == null
      ? null
      : asMap(json['recommendation']);
  final followUpJson = json['follow_up'] == null
      ? null
      : asMap(json['follow_up']);
  final viewingJson = json['viewing'] == null ? null : asMap(json['viewing']);

  Recommendation? recommendation;
  NoMatchSummary? noMatch;
  if (rec != null && rec['status'] == 'no_match') {
    final summary = asMap(rec['no_match_summary']);
    final counts = asMap(summary['primary_exclusion_counts']);
    noMatch = NoMatchSummary(
      candidateCount: summary['candidate_count'] as int,
      hiddenByPreference: (summary['hidden_by_preference'] as int?) ?? 0,
      counts: {
        for (final e in counts.entries)
          _byWire(ExclusionCode.values, (c) => c.wireName, e.key):
              e.value as int,
      },
    );
  } else if (rec != null) {
    final status = _statuses[rec['status']];
    final episodeJson = rec['episode'];
    if (status == null || (rec['movie'] == null && episodeJson == null)) {
      throw malformedResponse;
    }
    final card = episodeJson == null
        ? null
        : episodeCardFromJson(asMap(episodeJson));
    recommendation = Recommendation(
      id: rec['id'] as String,
      movie: card != null
          ? card.display
          : movieSummaryFromJson(asMap(rec['movie'])).$1,
      episode: card,
      status: status,
      reasons: [
        ..._reasons(rec['reasons']),
        ..._reasons(rec['uncertainties'], uncertain: true),
      ],
    );
  }
  if ((state == TodayStatus.offered || state == TodayStatus.accepted) &&
      recommendation == null) {
    throw malformedResponse; // never "offered" without a film
  }
  Viewing? viewing;
  if (viewingJson != null) {
    final recordedAt = DateTime.tryParse(
      viewingJson['recorded_at'] as String? ?? '',
    );
    final watchedAtRaw = viewingJson['watched_at'];
    final ratingRaw = viewingJson['rating'];
    if (recordedAt == null ||
        (watchedAtRaw != null && watchedAtRaw is! String)) {
      throw malformedResponse;
    }
    final viewingCard = viewingJson['episode'] == null
        ? null
        : episodeCardFromJson(asMap(viewingJson['episode']));
    viewing = Viewing(
      id: viewingJson['id'] as String,
      episode: viewingCard,
      movie: viewingCard != null
          ? viewingCard.display
          : movieSummaryFromJson(asMap(viewingJson['movie'])).$1,
      watchedAt: watchedAtRaw == null
          ? null
          : DateTime.tryParse(watchedAtRaw as String),
      recordedAt: recordedAt,
      rating: _parseRating(ratingRaw),
      version: viewingJson['version'] as int? ?? 1,
    );
  }
  return TodayEnvelope(
    state: state,
    context: session == null
        ? null
        : sessionContextFromJson(asMap(session['context'])),
    recommendation: recommendation,
    noMatch: noMatch,
    viewing: viewing,
    followUp: followUpJson == null
        ? null
        : FollowUpPrompt(
            recommendationId: followUpJson['recommendation_id'] as String,
            episode: followUpJson['episode'] == null
                ? null
                : episodeCardFromJson(asMap(followUpJson['episode'])),
            movie: followUpJson['episode'] != null
                ? episodeCardFromJson(asMap(followUpJson['episode'])).display
                : movieSummaryFromJson(asMap(followUpJson['movie'])).$1,
            acceptedLocalDate: DateTime.parse(
              followUpJson['accepted_local_date'] as String,
            ),
          ),
    rejectionCount: (session?['rejection_count'] as int?) ?? 0,
    media: TonightMedia.fromWire(json['media']),
    emptyReason: json['empty_reason'] as String?,
  );
}

int sessionVersionOf(Map<String, dynamic> envelope) {
  final session = envelope['session'];
  return session is Map<String, dynamic> ? session['version'] as int : 0;
}

Rating? _parseRating(Object? value) {
  try {
    return Rating.fromValue(value);
  } on FormatException {
    throw malformedResponse;
  }
}

ReplacementOutcome replacementOutcomeFromJson(Object? raw) => switch (raw) {
  'selected' => ReplacementOutcome.selected,
  'no_match' => ReplacementOutcome.noMatch,
  'paused' => ReplacementOutcome.paused,
  'daily_limit' => ReplacementOutcome.dailyLimit,
  'not_requested' => ReplacementOutcome.notRequested,
  _ => throw malformedResponse,
};
