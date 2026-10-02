import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/movie_dto.dart';
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
}

/// Null in the preview build: no availability is shown there.
final availabilityRepositoryProvider = Provider<AvailabilityRepository?>(
  (ref) => null,
);

/// Per film and signed-in user; refreshed when the region changes.
final movieAvailabilityProvider = FutureProvider.autoDispose
    .family<Availability?, int>((ref, tmdbId) {
      ref.watch(currentUserIdProvider);
      final repo = ref.watch(availabilityRepositoryProvider);
      return repo?.forMovie(tmdbId);
    });

class ApiAvailabilityRepository implements AvailabilityRepository {
  ApiAvailabilityRepository(this._api);

  final ApiClient _api;

  @override
  Future<Availability> forMovie(int tmdbId) async {
    final body = await _api.get('/api/v1/movies/$tmdbId/availability');
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
