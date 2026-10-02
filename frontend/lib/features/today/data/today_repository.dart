import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../../shared/models/viewing.dart';

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
}

/// Null until a real backend repository exists (P4). Only the explicit UI
/// preview build overrides this with the scripted fake; a normal build never
/// falls back to fake data.
final todayRepositoryProvider = Provider<TodayRepository?>((ref) => null);
