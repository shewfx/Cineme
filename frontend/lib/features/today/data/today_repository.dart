import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/idempotency.dart';
import '../../../core/network/movie_dto.dart';

import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../../shared/models/viewing.dart';
import 'today_dto.dart';

abstract interface class TodayRepository {
  /// GET /today: reads the current state; never chooses a movie.
  Future<TodayEnvelope> today();

  /// POST /today/choose: applies the reviewed context and returns ONE pick
  /// (or no match). An existing pick with unchanged scoring context is
  /// returned as is. After three rejections an unchanged context needs
  /// [continueAfterPause], else throws `CONTEXT_REVIEW_REQUIRED`.
  Future<TodayEnvelope> choose(
    SessionContext context, {
    bool continueAfterPause = false,
  });

  /// PATCH /today/context: saves without choosing. A mood-only edit keeps the
  /// pick; a changed scoring context clears it.
  Future<TodayEnvelope> saveContext(SessionContext context);

  /// POST /recommendations/{id}/accept: Watch Tonight. Intention only.
  Future<TodayEnvelope> accept(String recommendationId);

  /// POST /recommendations/{id}/reject. With [chooseAnother], selects exactly
  /// one replacement (or no match), unless this is the third rejection.
  Future<RejectResult> reject(
    String recommendationId,
    RejectReason reason, {
    int? maxRuntimeMinutes,
    Set<int> avoidGenreIds = const {},
    required bool chooseAnother,
  });

  /// POST /recommendations/{id}/watched: tonight's completion.
  Future<TodayEnvelope> markWatched(String recommendationId, {Rating? rating});

  /// GET /recommendations/{id}: the winner's score breakdown for Why. Null
  /// when the source has none (the preview's scripted picks).
  Future<WhyBreakdown?> why(String recommendationId);
}

/// Null in builds without a backend. The normal build uses
/// [ApiTodayRepository]; only the preview build uses the scripted fake.
final todayRepositoryProvider = Provider<TodayRepository?>((ref) => null);

/// Real build: Today through the Cinemé API. The server owns state, versions
/// and the one current pick; this client only reads and sends deliberate
/// commands, each with a fresh idempotency key.
class ApiTodayRepository implements TodayRepository {
  ApiTodayRepository(this._api);

  final ApiClient _api;

  /// Version of the last envelope seen; sent as expected_session_version so
  /// a stale screen gets VERSION_CONFLICT instead of acting on another film.
  int _version = 0;

  TodayEnvelope _envelope(Map<String, dynamic> json) {
    final envelope = todayEnvelopeFromJson(json);
    _version = sessionVersionOf(json);
    return envelope;
  }

  /// Documented outcomes the UI explains (pause, stale, expired, limits).
  static const _conflicts = {
    'CONTEXT_REQUIRED',
    'CONTEXT_REVIEW_REQUIRED',
    'VERSION_CONFLICT',
    'INVALID_TRANSITION',
    'SESSION_EXPIRED',
    'TODAY_COMPLETED',
    'DAILY_ATTEMPT_LIMIT',
  };

  /// Keeps a command's key across an ambiguous failure so a retry of the
  /// same command is replayed by the server, never applied twice.
  final _keys = RetryKeys();

  Future<Map<String, dynamic>> _command(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    try {
      return await _keys.send(
        commandFingerprint(method, path, body),
        (key) => method == 'PATCH'
            ? _api.patch(path, body: body, idempotencyKey: key)
            : _api.post(path, body: body, idempotencyKey: key),
      );
    } on ApiError catch (e) {
      throw _conflicts.contains(e.code) ? TodayConflict(e.code) : e;
    }
  }

  String _rec(String id, String action) =>
      '/api/v1/recommendations/${Uri.encodeComponent(id)}/$action';

  @override
  Future<TodayEnvelope> today() async =>
      _envelope(await _api.get('/api/v1/today'));

  @override
  Future<TodayEnvelope> choose(
    SessionContext context, {
    bool continueAfterPause = false,
  }) async => _envelope(
    await _command('POST', '/api/v1/today/choose', {
      'expected_session_version': _version,
      'context': sessionContextToJson(context),
      'continue_after_pause': continueAfterPause,
    }),
  );

  @override
  Future<TodayEnvelope> saveContext(SessionContext context) async => _envelope(
    await _command('PATCH', '/api/v1/today/context', {
      'expected_session_version': _version,
      'context': sessionContextToJson(context),
    }),
  );

  @override
  Future<TodayEnvelope> accept(String recommendationId) async => _envelope(
    await _command('POST', _rec(recommendationId, 'accept'), {
      'expected_session_version': _version,
    }),
  );

  @override
  Future<RejectResult> reject(
    String recommendationId,
    RejectReason reason, {
    int? maxRuntimeMinutes,
    Set<int> avoidGenreIds = const {},
    required bool chooseAnother,
  }) async {
    final body = await _command('POST', _rec(recommendationId, 'reject'), {
      'expected_session_version': _version,
      'reason': reason.wireName,
      'details': {
        if (reason == RejectReason.tooLong && maxRuntimeMinutes != null)
          'max_runtime_minutes': maxRuntimeMinutes,
        if (reason == RejectReason.wrongGenre)
          'avoid_genre_ids': (avoidGenreIds.toList()..sort()),
      },
      'choose_another': chooseAnother,
    });
    return RejectResult(
      outcome: replacementOutcomeFromJson(body['replacement_outcome']),
      today: _envelope(asMap(body['today'])),
    );
  }

  @override
  Future<WhyBreakdown?> why(String recommendationId) async {
    final body = await _api.get(
      '/api/v1/recommendations/${Uri.encodeComponent(recommendationId)}',
    );
    final breakdown = body['breakdown'];
    if (breakdown == null) return null;
    final b = asMap(breakdown);
    Map<String, double> numbers(Object? raw) => {
      for (final e in asMap(raw).entries) e.key: (e.value as num).toDouble(),
    };
    return WhyBreakdown(
      weights: numbers(b['weights']),
      contributions: numbers(b['contributions']),
      engineVersion: asMap(body['recommendation'])['engine_version'] as String,
      configVersion: body['config_version'] as String,
    );
  }

  /// Tonight's completion needs viewing history (P5); the normal build
  /// doesn't offer Mark watched yet.
  @override
  Future<TodayEnvelope> markWatched(
    String recommendationId, {
    Rating? rating,
  }) =>
      throw UnsupportedError('Mark watched arrives with viewing history (P5).');
}
