import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/profile.dart';

abstract interface class ProfileRepository {
  /// GET /me (read-only) plus GET /me/blocks.
  Future<Profile> profile();
}

/// Null until auth and profiles exist (P2); preview overrides it.
final profileRepositoryProvider = Provider<ProfileRepository?>((ref) => null);
