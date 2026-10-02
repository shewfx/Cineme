import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../preview/preview_store.dart';
import '../../../shared/models/profile.dart';
import '../data/account_repository.dart';
import '../data/auth_repository.dart';

/// The signed-in user, or null. Preview builds have no identity.
final authUserProvider = StreamProvider<AuthUser?>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  if (auth == null) return Stream.value(null);
  return auth.userChanges().distinct();
});

/// Id of the signed-in user. Private providers watch this so a sign-out or
/// account switch rebuilds them and never shows the previous user's data.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authUserProvider.select((u) => u.value?.id)),
);

/// Explicit bootstrap, then a read-only GET /me, for the signed-in user.
/// Failures stay visible with Retry; the SDK session is kept.
final accountProvider = FutureProvider<Profile>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  final account = ref.watch(accountRepositoryProvider);
  if (userId == null || account == null) {
    throw StateError('No signed-in user to set up.');
  }
  await account.bootstrap();
  return account.me();
});

enum AuthGate {
  /// Explicit UI-preview build: fake data, no sign-in.
  preview,

  /// Normal build without API/Supabase configuration: no fake fallback.
  configMissing,
  checkingSession,
  signedOut,

  /// Signed in, but the provider says the email is not confirmed.
  confirmEmail,

  /// Bootstrap or GET /me in progress or failed (Retry offered).
  settingUp,
  ready,
}

final authGateProvider = Provider<AuthGate>((ref) {
  if (ref.watch(previewStoreProvider) != null) return AuthGate.preview;
  if (!ref.watch(appConfigProvider).isComplete ||
      ref.watch(authRepositoryProvider) == null) {
    return AuthGate.configMissing;
  }
  final user = ref.watch(authUserProvider);
  if (user.isLoading && !user.hasValue) return AuthGate.checkingSession;
  if (user.value == null) return AuthGate.signedOut;
  final account = ref.watch(accountProvider);
  if (account.hasValue && !account.isLoading) return AuthGate.ready;
  final error = account.error;
  if (error is ApiError && error.code == 'EMAIL_NOT_VERIFIED') {
    return AuthGate.confirmEmail;
  }
  return AuthGate.settingUp;
});
