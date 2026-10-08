import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/movie_dto.dart';
import '../../../shared/models/series.dart' show MediaType;
import '../../auth/application/auth_controller.dart';

/// A streaming/rental service from TMDB's JustWatch data. Never invented.
class ProviderOffer {
  const ProviderOffer({required this.name, this.logoUrl});

  final String name;
  final String? logoUrl;
}

/// Where a film can be watched in the user's region (ADR 007).
class Availability {
  const Availability({
    required this.region,
    this.streaming = const [],
    this.free = const [],
    this.rent = const [],
    this.buy = const [],
  });

  /// Null when the region can't be determined; nothing is shown then.
  final String? region;
  final List<ProviderOffer> streaming;
  final List<ProviderOffer> free;
  final List<ProviderOffer> rent;
  final List<ProviderOffer> buy;

  bool get isEmpty =>
      streaming.isEmpty && free.isEmpty && rent.isEmpty && buy.isEmpty;
}

abstract interface class AvailabilityRepository {
  /// GET /movies/{id}/availability through Cinemé; TMDB stays server-side.
  Future<Availability> forMovie(int tmdbId);

  /// GET /tv/{id}/availability: the show as a whole, never a promise about a
  /// particular season or episode.
  Future<Availability> forSeries(int tmdbId);
}

/// Media type plus TMDB id: movie and TV ids overlap, so both always travel.
class AvailabilityKey {
  const AvailabilityKey(this.type, this.tmdbId);

  final MediaType type;
  final int tmdbId;

  @override
  bool operator ==(Object other) =>
      other is AvailabilityKey && other.type == type && other.tmdbId == tmdbId;

  @override
  int get hashCode => Object.hash(type, tmdbId);
}

/// Null in the preview build: no availability is shown there.
final availabilityRepositoryProvider = Provider<AvailabilityRepository?>(
  (ref) => null,
);

/// Per title and signed-in user; refreshed when the region changes.
final availabilityProvider = FutureProvider.autoDispose
    .family<Availability?, AvailabilityKey>((ref, key) {
      ref.watch(currentUserIdProvider);
      final repo = ref.watch(availabilityRepositoryProvider);
      return switch (key.type) {
        MediaType.movie => repo?.forMovie(key.tmdbId),
        MediaType.series => repo?.forSeries(key.tmdbId),
      };
    });

/// A film's availability (kept as the name existing callers use).
FutureProvider<Availability?> movieAvailabilityProvider(int tmdbId) =>
    availabilityProvider(AvailabilityKey(MediaType.movie, tmdbId));

/// A show's availability.
FutureProvider<Availability?> seriesAvailabilityProvider(int tmdbId) =>
    availabilityProvider(AvailabilityKey(MediaType.series, tmdbId));

class ApiAvailabilityRepository implements AvailabilityRepository {
  ApiAvailabilityRepository(this._api);

  final ApiClient _api;

  @override
  Future<Availability> forMovie(int tmdbId) =>
      _fetch('/api/v1/movies/$tmdbId/availability');

  @override
  Future<Availability> forSeries(int tmdbId) =>
      _fetch('/api/v1/tv/$tmdbId/availability');

  Future<Availability> _fetch(String path) async {
    final body = await _api.get(path);
    List<ProviderOffer> offers(Object? raw) => [
      for (final o in asList(raw))
        ProviderOffer(
          name: asMap(o)['name'] as String,
          logoUrl: asMap(o)['logo_url'] as String?,
        ),
    ];
    final region = body['region'];
    if (region != null && region is! String) throw malformedResponse;
    return Availability(
      region: region as String?,
      streaming: offers(body['streaming']),
      free: offers(body['free']),
      rent: offers(body['rent']),
      buy: offers(body['buy']),
    );
  }
}
