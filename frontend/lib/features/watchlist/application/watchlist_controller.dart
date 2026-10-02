import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/paged_list.dart';
import '../../../core/state/revision.dart';
import '../../../shared/models/inventory.dart';
import '../../history/application/history_controllers.dart';
import '../../today/application/today_controller.dart';
import '../data/watchlist_repository.dart';

class WatchlistController extends PagedListNotifier<WatchlistEntry> {
  WatchlistRepository get _repo => ref.read(watchlistRepositoryProvider)!;

  @override
  Future<PagedState<WatchlistEntry>> build() {
    ref.watch(inventoryRevisionProvider);
    return super.build();
  }

  @override
  Future<Paged<WatchlistEntry>> fetch(String? cursor) =>
      _repo.list(cursor: cursor);

  /// Not optimistic: the row disappears only after the server confirms.
  /// Throws on failure so the page can explain it and keep the row.
  Future<void> remove(WatchlistEntry entry) async {
    await _repo.remove(entry.id);
    if (!ref.mounted) return;
    final s = state.value;
    if (s != null) {
      state = AsyncData(
        PagedState([
          for (final e in s.items)
            if (e.id != entry.id) e,
        ], s.nextCursor),
      );
    }
    // Removing tonight's pick clears it server-side; history shows that.
    ref.invalidate(todayEnvelopeProvider);
    ref.invalidate(recommendationHistoryProvider);
  }
}

final watchlistControllerProvider =
    AsyncNotifierProvider<WatchlistController, PagedState<WatchlistEntry>>(
      WatchlistController.new,
    );
