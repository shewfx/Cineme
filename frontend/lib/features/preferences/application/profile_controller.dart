import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/profile.dart';
import '../data/profile_repository.dart';

/// Read-only in P1b; editing preferences arrives in P3.
final profileProvider = FutureProvider<Profile>(
  (ref) => ref.read(profileRepositoryProvider)!.profile(),
);
