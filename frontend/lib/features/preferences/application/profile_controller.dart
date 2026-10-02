import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/revision.dart';
import '../../../shared/models/profile.dart';
import '../../auth/application/auth_controller.dart';
import '../data/profile_repository.dart';

/// Read-only in P1b; editing preferences arrives in P3.
final profileProvider = FutureProvider<Profile>((ref) {
  ref.watch(inventoryRevisionProvider); // blocks change from Tonight
  // Per signed-in user: sign-out or an account switch reloads, never leaks.
  ref.watch(currentUserIdProvider);
  return ref.read(profileRepositoryProvider)!.profile();
});
