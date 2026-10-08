import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/paged_list.dart';
import '../../../core/state/revision.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/viewing.dart';
import '../../auth/application/auth_controller.dart';
import '../../history/application/history_controllers.dart';
import '../../today/application/today_controller.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../../watchlist/data/watchlist_repository.dart';
import '../data/series_repository.dart';

const showSearchDebounce = Duration(milliseconds: 300);
const showMinQueryLength = 2;

/// Details of one show plus the caller's entry. Reloads when Tonight, the
/// watchlist or progress changes (the inventory revision) and per user.
final seriesDetailsProvider = FutureProvider.autoDispose
    .family<SeriesDetails, int>((ref, tmdbId) {
      ref.watch(inventoryRevisionProvider);
      ref.watch(currentUserIdProvider);
      return ref.watch(seriesRepositoryProvider)!.details(tmdbId);
    });

/// Shows set to Never recommend (Profile). Reloads with the inventory.
final blockedShowsProvider = FutureProvider.autoDispose<List<Series>>((ref) {
  ref.watch(inventoryRevisionProvider);
  ref.watch(currentUserIdProvider);
  return ref.watch(seriesRepositoryProvider)!.blocked();
});

/// This week's trending shows for the add screen. Kept per user and not
/// auto-disposed, so clearing the query shows it again without a reload.
final trendingShowsProvider = FutureProvider<ShowTrendingPage>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(seriesRepositoryProvider)!.trending();
});

/// Regular seasons and episodes for the progress picker.
final seriesSeasonsProvider = FutureProvider.autoDispose
    .family<List<SeasonInfo>, int>(
      (ref, tmdbId) => ref.watch(seriesRepositoryProvider)!.seasons(tmdbId),
    );

/// Everything that depends on a show's progress or membership reloads after
/// a change: the lists, Tonight (its pick may be stale) and history.
void refreshAfterShowChange(Ref ref) {
  ref
    ..read(inventoryRevisionProvider.notifier).bump()
    ..invalidate(watchlistItemsProvider)
    ..invalidate(watchlistControllerProvider)
    ..invalidate(todayEnvelopeProvider)
    ..invalidate(recommendationHistoryProvider);
}

/// Watched episodes for the History tab, newest first.
class EpisodeHistoryController extends PagedListNotifier<EpisodeViewingRecord> {
  @override
  Future<PagedState<EpisodeViewingRecord>> build() {
    ref.watch(inventoryRevisionProvider);
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<Paged<EpisodeViewingRecord>> fetch(String? cursor) =>
      ref.read(seriesRepositoryProvider)!.viewings(cursor: cursor);
}

final episodeHistoryProvider =
    AsyncNotifierProvider<
      EpisodeHistoryController,
      PagedState<EpisodeViewingRecord>
    >(EpisodeHistoryController.new);

class ShowSearchState {
  const ShowSearchState({
    this.query = '',
    this.results,
    this.page = 0,
    this.totalPages = 0,
    this.loadingMore = false,
    this.loadMoreError,
    this.added = const {},
    this.busy = const {},
  });

  final String query;
  final AsyncValue<List<Series>>? results;
  final int page;
  final int totalPages;
  final bool loadingMore;
  final Object? loadMoreError;

  /// Shows added (or found already on the list) during this search.
  final Set<int> added;
  final Set<int> busy;

  bool get hasMore => page < totalPages;

  ShowSearchState copyWith({
    String? query,
    AsyncValue<List<Series>>? Function()? results,
    int? page,
    int? totalPages,
    bool? loadingMore,
    Object? Function()? loadMoreError,
    Set<int>? added,
    Set<int>? busy,
  }) => ShowSearchState(
    query: query ?? this.query,
    results: results != null ? results() : this.results,
    page: page ?? this.page,
    totalPages: totalPages ?? this.totalPages,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: loadMoreError != null ? loadMoreError() : this.loadMoreError,
    added: added ?? this.added,
    busy: busy ?? this.busy,
  );
}

enum ShowAddOutcome { added, alreadySaved, blocked, ineligible, full, failed }

/// Search for shows to add. Mirrors the film search: debounce, a two
/// character minimum, stale responses discarded, add with a busy guard.
class ShowSearchController extends Notifier<ShowSearchState> {
  Timer? _debounce;
  int _seq = 0;

  SeriesRepository get _repo => ref.read(seriesRepositoryProvider)!;

  @override
  ShowSearchState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const ShowSearchState();
  }

  void onQueryChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.length < showMinQueryLength) {
      _seq++;
      state = ShowSearchState(query: q, added: state.added);
      return;
    }
    state = state.copyWith(query: q);
    _debounce = Timer(showSearchDebounce, () => _search(q));
  }

  Future<void> retry() => _search(state.query);

  Future<void> _search(String q) async {
    final seq = ++_seq;
    state = state.copyWith(results: () => const AsyncLoading(), page: 0);
    try {
      final res = await _repo.search(q);
      if (!ref.mounted || seq != _seq) return;
      state = state.copyWith(
        results: () => AsyncData(res.results),
        page: res.page,
        totalPages: res.totalPages,
        loadingMore: false,
        loadMoreError: () => null,
      );
    } catch (e, st) {
      if (!ref.mounted || seq != _seq) return;
      state = state.copyWith(results: () => AsyncError(e, st));
    }
  }

  Future<void> loadMore() async {
    final current = state.results?.value;
    if (current == null || !state.hasMore || state.loadingMore) return;
    final seq = _seq;
    state = state.copyWith(loadingMore: true, loadMoreError: () => null);
    try {
      final res = await _repo.search(state.query, page: state.page + 1);
      if (!ref.mounted || seq != _seq) return;
      state = state.copyWith(
        results: () => AsyncData([...current, ...res.results]),
        page: res.page,
        totalPages: res.totalPages,
        loadingMore: false,
      );
    } catch (e) {
      if (!ref.mounted || seq != _seq) return;
      state = state.copyWith(loadingMore: false, loadMoreError: () => e);
    }
  }

  /// Adds one show. A second tap while in flight, or after it is added, is a
  /// no-op; the outcome says what happened.
  Future<ShowAddOutcome> add(Series series) async {
    final id = series.tmdbId;
    if (state.busy.contains(id) || state.added.contains(id)) {
      return ShowAddOutcome.alreadySaved;
    }
    state = state.copyWith(busy: {...state.busy, id});
    try {
      final r = await _repo.add(id);
      if (ref.mounted) state = state.copyWith(added: {...state.added, id});
      refreshAfterShowChange(ref);
      return r.alreadyPresent
          ? ShowAddOutcome.alreadySaved
          : ShowAddOutcome.added;
    } on InventoryConflict catch (c) {
      return switch (c.code) {
        'SERIES_BLOCKED' => ShowAddOutcome.blocked,
        'SERIES_INELIGIBLE' => ShowAddOutcome.ineligible,
        'WATCHLIST_LIMIT' => ShowAddOutcome.full,
        _ => ShowAddOutcome.failed,
      };
    } catch (_) {
      return ShowAddOutcome.failed;
    } finally {
      if (ref.mounted) {
        state = state.copyWith(busy: {...state.busy}..remove(id));
      }
    }
  }
}

final showSearchControllerProvider =
    NotifierProvider.autoDispose<ShowSearchController, ShowSearchState>(
      ShowSearchController.new,
    );

/// Show actions used by the details page. Each returns normally on success
/// and throws the repository's error, so the page can explain it.
class SeriesActions {
  SeriesActions(this._ref);

  final Ref _ref;

  SeriesRepository get _repo => _ref.read(seriesRepositoryProvider)!;

  Future<void> add(int tmdbId) async {
    await _repo.add(tmdbId);
    refreshAfterShowChange(_ref);
  }

  Future<void> block(int tmdbId) async {
    await _repo.block(tmdbId);
    refreshAfterShowChange(_ref);
    _ref.invalidate(blockedShowsProvider);
  }

  /// Archives the entry; its progress and history are kept.
  Future<void> remove(String entryId) async {
    await _ref.read(watchlistRepositoryProvider)!.remove(entryId);
    refreshAfterShowChange(_ref);
  }

  Future<void> setProgress(
    int tmdbId, {
    required int expectedVersion,
    required (int, int)? last,
  }) async {
    await _repo.setProgress(
      tmdbId,
      expectedVersion: expectedVersion,
      last: last,
    );
    refreshAfterShowChange(_ref);
  }

  Future<EpisodeWatchedResult> markNextWatched(
    int tmdbId, {
    required int season,
    required int episode,
    Rating? rating,
  }) async {
    final r = await _repo.markNextWatched(
      tmdbId,
      season: season,
      episode: episode,
      rating: rating,
    );
    refreshAfterShowChange(_ref);
    return r;
  }
}

final seriesActionsProvider = Provider<SeriesActions>(SeriesActions.new);
