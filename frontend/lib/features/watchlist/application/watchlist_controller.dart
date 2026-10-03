import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/state/paged_list.dart';
import '../../../core/state/revision.dart';
import '../../../shared/models/inventory.dart';
import '../../auth/application/auth_controller.dart';
import '../../history/application/history_controllers.dart';
import '../../today/application/today_controller.dart';
import '../data/watchlist_repository.dart';

class WatchlistController extends PagedListNotifier<WatchlistEntry> {
  WatchlistRepository get _repo => ref.read(watchlistRepositoryProvider)!;

  WatchlistSort _sort = WatchlistSort.addedDesc;

  @override
  Future<PagedState<WatchlistEntry>> build() async {
    ref.watch(inventoryRevisionProvider);
    // Per signed-in user: sign-out or an account switch reloads, never leaks.
    ref.watch(currentUserIdProvider);
    // A new sort reloads from the first page: the server owns the order, so
    // paging stays correct however many films there are. Until the saved
    // preference is read (a local lookup) the default order is requested.
    _sort = ref.watch(watchlistSortProvider);
    return super.build();
  }

  @override
  Future<Paged<WatchlistEntry>> fetch(String? cursor) =>
      _repo.list(cursor: cursor, sort: _sort);

  final _removing = <String>{};

  /// Not optimistic: the row disappears only after the server confirms.
  /// Throws on failure so the page can explain it and keep the row. Returns
  /// false, without a request, while the same entry is already being removed.
  Future<bool> remove(WatchlistEntry entry) async {
    if (!_removing.add(entry.id)) return false;
    try {
      await _repo.remove(entry.id);
    } finally {
      _removing.remove(entry.id);
    }
    if (!ref.mounted) return true;
    final s = state.value;
    if (s != null) {
      state = AsyncData(
        PagedState([
          for (final e in s.items)
            if (e.id != entry.id) e,
        ], s.nextCursor),
      );
    }
    _invalidateToday();
    return true;
  }

  /// Undo for a removal: re-adds through the normal add path (the server
  /// restores the archived entry; its added date starts again).
  Future<void> restore(WatchlistEntry entry) async {
    final result = await _repo.add(entry.movie.tmdbId);
    if (!ref.mounted) return;
    final s = state.value;
    if (s != null && !s.items.any((e) => e.id == result.entry.id)) {
      if (_sort == WatchlistSort.addedDesc) {
        state = AsyncData(PagedState([result.entry, ...s.items], s.nextCursor));
      } else {
        // Its place depends on the sort; let the server say where it goes.
        ref.invalidateSelf();
      }
    }
    _invalidateToday();
  }

  // Removing tonight's pick clears it server-side; history shows that.
  void _invalidateToday() {
    ref.invalidate(todayEnvelopeProvider);
    ref.invalidate(recommendationHistoryProvider);
  }
}

enum WatchlistLayout { list, posters }

/// Presentation preference only, kept on this device (no backend).
class WatchlistLayoutController extends Notifier<WatchlistLayout> {
  static const _key = 'watchlist_layout';
  bool _chosen = false;

  @override
  WatchlistLayout build() {
    _restore();
    return WatchlistLayout.list;
  }

  Future<void> _restore() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      if (!ref.mounted || _chosen) return;
      state = WatchlistLayout.values.asNameMap()[saved] ?? state;
    } catch (_) {
      // Unreadable storage just means the default layout.
    }
  }

  Future<void> set(WatchlistLayout layout) async {
    _chosen = true;
    state = layout;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        layout.name,
      );
    } catch (_) {
      // Still applied for this session.
    }
  }
}

/// Sort preference only, kept on this device. Layout changes never touch it.
/// Starts at the default order and switches once the saved choice is read; a
/// saved default changes nothing, so the usual case loads the list once.
class WatchlistSortController extends Notifier<WatchlistSort> {
  static const _key = 'watchlist_sort';
  bool _chosen = false;

  @override
  WatchlistSort build() {
    _restore();
    return WatchlistSort.addedDesc;
  }

  Future<void> _restore() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      if (!ref.mounted || _chosen) return;
      state = WatchlistSort.values.firstWhere(
        (s) => s.apiValue == saved,
        orElse: () => state,
      );
    } catch (_) {
      // Unreadable storage just means the default order.
    }
  }

  Future<void> set(WatchlistSort sort) async {
    _chosen = true;
    state = sort;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        sort.apiValue,
      );
    } catch (_) {
      // Still applied for this session.
    }
  }
}

final watchlistSortProvider =
    NotifierProvider<WatchlistSortController, WatchlistSort>(
      WatchlistSortController.new,
    );

final watchlistLayoutProvider =
    NotifierProvider<WatchlistLayoutController, WatchlistLayout>(
      WatchlistLayoutController.new,
    );

final watchlistControllerProvider =
    AsyncNotifierProvider<WatchlistController, PagedState<WatchlistEntry>>(
      WatchlistController.new,
    );
