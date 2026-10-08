import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/inventory.dart';
import '../../auth/application/auth_controller.dart';
import '../../history/application/history_controllers.dart';
import '../../history/data/history_repository.dart';
import '../../today/application/today_controller.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../../watchlist/data/watchlist_repository.dart';
import '../data/search_repository.dart';

const searchDebounce = Duration(milliseconds: 300);
const minQueryLength = 2;

/// What the user learned about a result after acting on it.
enum ResultMark { saved, watched, ineligible }

enum SearchOutcome {
  added,
  alreadySaved,
  alreadyWatched,
  ineligible,
  blocked,
  recorded,
  alreadyRecorded,
  failed,
}

class SearchState {
  const SearchState({
    this.query = '',
    this.results,
    this.page = 0,
    this.totalPages = 0,
    this.loadingMore = false,
    this.loadMoreError,
    this.marks = const {},
    this.busy = const {},
  });

  final String query;

  /// Null while the query is shorter than [minQueryLength].
  final AsyncValue<List<SearchResult>>? results;
  final int page;
  final int totalPages;
  final bool loadingMore;
  final Object? loadMoreError;
  final Map<int, ResultMark> marks;
  final Set<int> busy;

  bool get hasMore => page < totalPages;

  SearchState copyWith({
    String? query,
    AsyncValue<List<SearchResult>>? Function()? results,
    int? page,
    int? totalPages,
    bool? loadingMore,
    Object? Function()? loadMoreError,
    Map<int, ResultMark>? marks,
    Set<int>? busy,
  }) => SearchState(
    query: query ?? this.query,
    results: results != null ? results() : this.results,
    page: page ?? this.page,
    totalPages: totalPages ?? this.totalPages,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: loadMoreError != null ? loadMoreError() : this.loadMoreError,
    marks: marks ?? this.marks,
    busy: busy ?? this.busy,
  );
}

class SearchController extends Notifier<SearchState> {
  Timer? _debounce;

  /// Bumped per request; responses for an older query are discarded.
  int _seq = 0;

  @override
  SearchState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const SearchState();
  }

  void onQueryChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.length < minQueryLength) {
      _seq++;
      state = SearchState(query: q, marks: state.marks);
      return;
    }
    state = state.copyWith(query: q);
    _debounce = Timer(searchDebounce, () => _search(q));
  }

  Future<void> retry() => _search(state.query);

  Future<void> _search(String q) async {
    final seq = ++_seq;
    state = state.copyWith(results: () => const AsyncLoading(), page: 0);
    try {
      final res = await ref.read(searchRepositoryProvider)!.search(q);
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
      final res = await ref
          .read(searchRepositoryProvider)!
          .search(state.query, page: state.page + 1);
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

  Future<SearchOutcome> add(SearchResult result) => _act(result, () async {
    try {
      final r = await ref
          .read(watchlistRepositoryProvider)!
          .add(result.movie.tmdbId);
      _mark(result, ResultMark.saved);
      ref
        ..invalidate(watchlistControllerProvider)
        ..invalidate(watchlistItemsProvider)
        ..invalidate(todayEnvelopeProvider);
      return r.alreadyPresent
          ? SearchOutcome.alreadySaved
          : SearchOutcome.added;
    } on InventoryConflict catch (c) {
      return switch (c.code) {
        'MOVIE_ALREADY_WATCHED' => _markAnd(
          result,
          ResultMark.watched,
          SearchOutcome.alreadyWatched,
        ),
        'MOVIE_BLOCKED' => _markAnd(
          result,
          ResultMark.ineligible,
          SearchOutcome.blocked,
        ),
        'MOVIE_INELIGIBLE' => _markAnd(
          result,
          ResultMark.ineligible,
          SearchOutcome.ineligible,
        ),
        _ => SearchOutcome.failed,
      };
    }
  });

  /// Logs a known past viewing (date unknown, no rating). Not tonight's
  /// completion; it also archives the film from the watchlist.
  Future<SearchOutcome> recordWatched(SearchResult result) =>
      _act(result, () async {
        final r = await ref
            .read(historyRepositoryProvider)!
            .recordManual(result.movie.tmdbId);
        _mark(result, ResultMark.watched);
        ref
          ..invalidate(viewingHistoryProvider)
          ..invalidate(recommendationHistoryProvider)
          ..invalidate(watchlistControllerProvider)
          ..invalidate(watchlistItemsProvider)
          ..invalidate(todayEnvelopeProvider);
        return r.alreadyRecorded
            ? SearchOutcome.alreadyRecorded
            : SearchOutcome.recorded;
      });

  Future<SearchOutcome> _act(
    SearchResult result,
    Future<SearchOutcome> Function() action,
  ) async {
    final id = result.movie.tmdbId;
    if (state.busy.contains(id)) return SearchOutcome.failed;
    state = state.copyWith(busy: {...state.busy, id});
    try {
      return await action();
    } catch (_) {
      return SearchOutcome.failed;
    } finally {
      if (ref.mounted) {
        state = state.copyWith(busy: {...state.busy}..remove(id));
      }
    }
  }

  void _mark(SearchResult r, ResultMark mark) {
    if (ref.mounted) {
      state = state.copyWith(marks: {...state.marks, r.movie.tmdbId: mark});
    }
  }

  SearchOutcome _markAnd(SearchResult r, ResultMark mark, SearchOutcome o) {
    _mark(r, mark);
    return o;
  }
}

/// A discovery list for onboarding and the add screen. Kept per signed-in user
/// and not auto-disposed, so clearing the query shows it again without a
/// reload.
final discoveryProvider = FutureProvider.family<DiscoveryPage, DiscoveryList>((
  ref,
  list,
) {
  ref.watch(currentUserIdProvider);
  return ref.watch(searchRepositoryProvider)!.discover(list);
});

/// Which list the add screen shows while the search box is empty; Trending
/// until the user picks another (this session only).
class DiscoveryChoice extends Notifier<DiscoveryList> {
  @override
  DiscoveryList build() => DiscoveryList.trending;

  void select(DiscoveryList list) => state = list;
}

final discoveryChoiceProvider =
    NotifierProvider<DiscoveryChoice, DiscoveryList>(DiscoveryChoice.new);

final searchControllerProvider =
    NotifierProvider.autoDispose<SearchController, SearchState>(
      SearchController.new,
    );
