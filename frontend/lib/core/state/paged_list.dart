import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/inventory.dart';

class PagedState<T> {
  const PagedState(
    this.items,
    this.nextCursor, {
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<T> items;
  final String? nextCursor;
  final bool loadingMore;

  /// A failed "load more" keeps the items already shown (FRONTEND_SPEC).
  final Object? loadMoreError;

  bool get hasMore => nextCursor != null;
}

/// Cursor pagination shared by Watchlist and the two History lists.
abstract class PagedListNotifier<T> extends AsyncNotifier<PagedState<T>> {
  Future<Paged<T>> fetch(String? cursor);

  @override
  Future<PagedState<T>> build() async {
    final page = await fetch(null);
    return PagedState(page.items, page.nextCursor);
  }

  Future<void> loadMore() async {
    final s = state.value;
    if (s == null || !s.hasMore || s.loadingMore) return;
    state = AsyncData(PagedState(s.items, s.nextCursor, loadingMore: true));
    try {
      final page = await fetch(s.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        PagedState([...s.items, ...page.items], page.nextCursor),
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = AsyncData(PagedState(s.items, s.nextCursor, loadMoreError: e));
    }
  }
}
