import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/inventory.dart';
import '../../../shared/models/viewing.dart';

abstract interface class HistoryRepository {
  /// GET /viewings: newest watched (or recorded) first.
  Future<Paged<Viewing>> viewings({String? cursor});

  /// GET /recommendations: newest first, including cleared picks.
  Future<Paged<RecommendationRecord>> recommendations({String? cursor});

  /// POST /viewings: logs a known past viewing with an unknown date and no
  /// rating. Never completes Tonight.
  Future<RecordWatchedResult> recordAlreadyWatched(int tmdbId);

  /// PATCH /viewings/{id}: replaces the rating (null clears it). Long-term
  /// taste evidence; never changes tonight's pick.
  Future<Viewing> rateViewing(String viewingId, Rating? rating);
}

/// Null until the real API repository exists; preview overrides it.
final historyRepositoryProvider = Provider<HistoryRepository?>((ref) => null);
