import 'dart:convert';
import 'dart:typed_data';

import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/features/movies/data/movie_details_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api implements HttpClientAdapter {
  RequestOptions? request;
  Object response = {
    'tmdb_id': 329865,
    'title': 'Arrival',
    'year': 2016,
    'runtime_minutes': 116,
    'vote_average': 7.6,
    'genre_ids': [18],
    'genres': [
      {'id': 18, 'name': 'Drama'},
    ],
    'poster_url': 'https://image.tmdb.org/t/p/w500/arrival.jpg',
    'can_add': true,
    'released': true,
    'release_date': '2016-11-11',
    'overview': 'A linguist is asked to communicate with visitors.',
    'original_title': null,
    'original_language': 'en',
    'stale': false,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'loads full details through the Cinemé API and preserves unknowns',
    () async {
      final server = _Api();
      final api = ApiClient(
        Dio(BaseOptions(baseUrl: 'https://cineme.test'))
          ..httpClientAdapter = server,
        () async => 'test-token',
      );

      final details = await ApiMovieDetailsRepository(api).details(329865);

      expect(server.request?.path, '/api/v1/movies/329865');
      expect(server.request?.headers['Authorization'], 'Bearer test-token');
      expect(details.movie.title, 'Arrival');
      expect(details.movie.runtimeMinutes, 116);
      expect(details.releaseDate, DateTime(2016, 11, 11));
      expect(details.overview, contains('linguist'));
      expect(details.originalTitle, isNull);
      expect(details.stale, isFalse);

      server.response = {
        ...(server.response as Map<String, Object?>),
        'runtime_minutes': null,
        'vote_average': null,
        'overview': null,
        'release_date': null,
        'genres': <Object?>[],
      };
      final sparse = await ApiMovieDetailsRepository(api).details(329865);
      expect(sparse.movie.runtimeMinutes, isNull);
      expect(sparse.movie.voteAverage, isNull);
      expect(sparse.movie.genres, isEmpty);
      expect(sparse.overview, isNull);
      expect(sparse.releaseDate, isNull);
    },
  );
}
