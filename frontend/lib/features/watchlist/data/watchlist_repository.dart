import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/inventory.dart';

abstract interface class WatchlistRepository {
  /// GET /watchlist: active entries, newest first, [pageSize] per page.
  Future<Paged<WatchlistEntry>> list({String? cursor});

  /// POST /watchlist. A duplicate succeeds with `alreadyPresent`; conflicts
  /// throw [InventoryConflict].
  Future<WatchlistAddResult> add(int tmdbId);

  /// DELETE /watchlist/{id}: archives the entry; already removed succeeds.
  Future<void> remove(String entryId);
}

const pageSize = 20;

/// Null until the real API repository exists (P3); preview overrides it.
final watchlistRepositoryProvider = Provider<WatchlistRepository?>(
  (ref) => null,
);
