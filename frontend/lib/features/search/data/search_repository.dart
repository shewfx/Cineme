import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/movie_dto.dart';
import '../../../shared/models/inventory.dart';

abstract interface class MovieSearchRepository {
  /// GET /movies/search: query length 2..100; runtime may be null.
  Future<SearchPage> search(String query, {int page = 1});
}

/// Null in builds without a backend; the preview overrides it with a fake.
final searchRepositoryProvider = Provider<MovieSearchRepository?>(
  (ref) => null,
);

/// Real build: TMDB search through the Cinemé API. Flutter never calls TMDB
/// and never holds its credential.
class ApiSearchRepository implements MovieSearchRepository {
  ApiSearchRepository(this._api);

  final ApiClient _api;

  @override
  Future<SearchPage> search(String query, {int page = 1}) async {
    final body = await _api.get(
      '/api/v1/movies/search',
      query: {'q': query, 'page': page},
    );
    final pageNo = body['page'];
    final total = body['total_pages'];
    if (pageNo is! int || total is! int) throw malformedResponse;
    return SearchPage(
      page: pageNo,
      totalPages: total,
      results: [
        for (final r in asList(body['results']))
          () {
            final (movie, canAdd) = movieSummaryFromJson(asMap(r));
            return SearchResult(movie: movie, canAdd: canAdd);
          }(),
      ],
    );
  }
}
