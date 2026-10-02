import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/paged_list.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/viewing.dart';
import '../data/history_repository.dart';

class ViewingHistoryController extends PagedListNotifier<Viewing> {
  @override
  Future<Paged<Viewing>> fetch(String? cursor) =>
      ref.read(historyRepositoryProvider)!.viewings(cursor: cursor);
}

class RecommendationHistoryController
    extends PagedListNotifier<RecommendationRecord> {
  @override
  Future<Paged<RecommendationRecord>> fetch(String? cursor) =>
      ref.read(historyRepositoryProvider)!.recommendations(cursor: cursor);
}

final viewingHistoryProvider =
    AsyncNotifierProvider<ViewingHistoryController, PagedState<Viewing>>(
      ViewingHistoryController.new,
    );

final recommendationHistoryProvider =
    AsyncNotifierProvider<
      RecommendationHistoryController,
      PagedState<RecommendationRecord>
    >(RecommendationHistoryController.new);
