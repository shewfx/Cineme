import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/movie_dto.dart';
import '../../../shared/models/movie.dart';
import '../../auth/application/auth_controller.dart';

class MovieDetails {
  const MovieDetails({
    required this.movie,
    this.releaseDate,
    this.overview,
    this.originalTitle,
    this.originalLanguage,
    required this.stale,
  });

  final Movie movie;
  final DateTime? releaseDate;
  final String? overview;
  final String? originalTitle;
  final String? originalLanguage;
  final bool stale;
}

abstract interface class MovieDetailsRepository {
  Future<MovieDetails> details(int tmdbId);
}

final movieDetailsRepositoryProvider = Provider<MovieDetailsRepository?>(
  (ref) => null,
);

/// Per user so a sign-out or account switch never reuses private API state.
final movieDetailsProvider = FutureProvider.autoDispose
    .family<MovieDetails, int>((ref, tmdbId) {
      ref.watch(currentUserIdProvider);
      final repository = ref.watch(movieDetailsRepositoryProvider);
      if (repository == null) {
        throw const ApiError(
          status: null,
          code: 'NOT_CONFIGURED',
          message: 'Movie details are unavailable in this build.',
        );
      }
      return repository.details(tmdbId);
    });

/// Full metadata is fetched only when the detail route opens. Watchlist pages
/// keep using their compact summary payload, and all movie facts stay behind
/// the authenticated Cinemé API.
class ApiMovieDetailsRepository implements MovieDetailsRepository {
  ApiMovieDetailsRepository(this._api);

  final ApiClient _api;

  @override
  Future<MovieDetails> details(int tmdbId) async {
    final json = await _api.get('/api/v1/movies/$tmdbId');
    final (movie, _) = movieSummaryFromJson(json);
    if (movie.tmdbId != tmdbId) throw malformedResponse;
    final releaseRaw = json['release_date'];
    final releaseDate = releaseRaw == null
        ? null
        : releaseRaw is String
        ? DateTime.tryParse(releaseRaw)
        : null;
    if (releaseRaw != null && releaseDate == null) throw malformedResponse;
    final overview = _optionalString(json, 'overview');
    final originalTitle = _optionalString(json, 'original_title');
    final originalLanguage = _optionalString(json, 'original_language');
    final stale = json['stale'];
    if (stale is! bool) throw malformedResponse;
    return MovieDetails(
      movie: movie,
      releaseDate: releaseDate,
      overview: overview,
      originalTitle: originalTitle,
      originalLanguage: originalLanguage,
      stale: stale,
    );
  }
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  throw malformedResponse;
}

/// Preview-only fallback built from its existing catalogue facts.
MovieDetails previewMovieDetails(Movie movie) =>
    MovieDetails(movie: movie, stale: false);
