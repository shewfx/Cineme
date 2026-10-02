import 'movie.dart';

/// One page of a cursor-paginated list (API_CONTRACT `{items,next_cursor}`).
class Paged<T> {
  const Paged(this.items, this.nextCursor);

  final List<T> items;
  final String? nextCursor;
}

/// Active watchlist entry. Inventory, never a ranked feed.
class WatchlistEntry {
  const WatchlistEntry({
    required this.id,
    required this.movie,
    required this.addedAt,
  });

  final String id;
  final Movie movie;
  final DateTime addedAt;
}

/// Search result: MovieSummary plus whether it may be added (`can_add`).
class SearchResult {
  const SearchResult({required this.movie, required this.canAdd});

  final Movie movie;
  final bool canAdd;
}

class SearchPage {
  const SearchPage({
    required this.page,
    required this.totalPages,
    required this.results,
  });

  final int page;
  final int totalPages;
  final List<SearchResult> results;
}

/// POST /watchlist result; a duplicate is a success with alreadyPresent.
class WatchlistAddResult {
  const WatchlistAddResult({required this.entry, required this.alreadyPresent});

  final WatchlistEntry entry;
  final bool alreadyPresent;
}

/// Documented conflict codes the UI must explain rather than hide.
class InventoryConflict implements Exception {
  const InventoryConflict(this.code);

  /// `MOVIE_ALREADY_WATCHED`, `MOVIE_INELIGIBLE`, ...
  final String code;
}
