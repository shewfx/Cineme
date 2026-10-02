import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';

abstract interface class TodayRepository {
  /// GET /today: reads the current state; never chooses a movie.
  Future<TodayEnvelope> today();

  /// POST /today/choose: applies the reviewed context and returns ONE pick.
  Future<TodayEnvelope> choose(SessionContext context);
}

/// Null until a real backend repository exists (P4). Only the explicit UI
/// preview build overrides this with the scripted fake; a normal build never
/// falls back to fake data.
final todayRepositoryProvider = Provider<TodayRepository?>((ref) => null);
