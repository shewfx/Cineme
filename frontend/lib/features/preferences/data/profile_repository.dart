import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/profile.dart';

abstract interface class ProfileRepository {
  /// GET /me (read-only) plus GET /me/blocks.
  Future<Profile> profile();

  /// DELETE /me/blocks/{tmdb_id}: reverses Never recommend. Does not re-add
  /// the film to the watchlist.
  Future<void> unblock(int tmdbId);
}

/// Null until auth and profiles exist (P2); preview overrides it.
final profileRepositoryProvider = Provider<ProfileRepository?>((ref) => null);
