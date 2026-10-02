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

  @override
  Future<PagedState<WatchlistEntry>> build() {
    ref.watch(inventoryRevisionProvider);
    // Per signed-in user: sign-out or an account switch reloads, never leaks.
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<Paged<WatchlistEntry>> fetch(String? cursor) =>
      _repo.list(cursor: cursor);

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
      state = AsyncData(PagedState([result.entry, ...s.items], s.nextCursor));
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

final watchlistLayoutProvider =
    NotifierProvider<WatchlistLayoutController, WatchlistLayout>(
      WatchlistLayoutController.new,
    );

final watchlistControllerProvider =
    AsyncNotifierProvider<WatchlistController, PagedState<WatchlistEntry>>(
      WatchlistController.new,
    );
