import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/inventory.dart';

abstract interface class MovieSearchRepository {
  /// GET /movies/search: query length 2..100; runtime may be null.
  Future<SearchPage> search(String query, {int page = 1});
}

/// Null until backend search exists (P3); preview overrides it.
final searchRepositoryProvider = Provider<MovieSearchRepository?>(
  (ref) => null,
);
