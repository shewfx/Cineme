import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/profile.dart';
import '../../auth/data/account_repository.dart';

abstract interface class ProfileRepository {
  /// GET /me (read-only) plus GET /me/blocks.
  Future<Profile> profile();

  /// DELETE /me/blocks/{tmdb_id}: reverses Never recommend. Does not re-add
  /// the film to the watchlist.
  Future<void> unblock(int tmdbId);
}

/// Null until auth and profiles exist (P2); preview overrides it.
final profileRepositoryProvider = Provider<ProfileRepository?>((ref) => null);

/// Real build: the profile is GET /me. Blocks arrive with P5, so unblocking
/// is not offered (the profile reports blocked films as not available).
class AccountProfileRepository implements ProfileRepository {
  AccountProfileRepository(this._account);

  final AccountRepository _account;

  @override
  Future<Profile> profile() => _account.me();

  @override
  Future<void> unblock(int tmdbId) => _account.unblock(tmdbId);
}
