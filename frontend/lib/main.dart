import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/auth/secure_session_storage.dart';
import 'core/config/app_config.dart';
import 'core/config/preview.dart';
import 'core/network/api_client.dart';
import 'features/auth/data/account_repository.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/preferences/data/profile_repository.dart';
import 'features/search/data/search_repository.dart';
import 'features/today/data/today_repository.dart';
import 'features/watchlist/data/watchlist_repository.dart';
import 'preview/preview_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      retry: noAutomaticRetry,
      overrides: isUiPreview
          ? previewOverrides(PreviewStore())
          : await realOverrides(AppConfig.fromEnvironment),
      child: const CinemeApp(),
    ),
  );
}

/// Normal build: Supabase identity plus the real API. Nothing here falls
/// back to preview data; without configuration the app says so instead.
Future<List<Override>> realOverrides(AppConfig config) async {
  if (!config.isComplete) return const [];
  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabasePublishableKey,
    authOptions: const FlutterAuthClientOptions(
      localStorage: SecureSessionStorage(),
      detectSessionInUri: false, // no deep links until recovery is added
    ),
  );
  final auth = SupabaseAuthRepository(Supabase.instance.client.auth);
  final api = ApiClient.create(config.apiBaseUrl, auth.accessToken);
  final account = ApiAccountRepository(api);
  return [
    authRepositoryProvider.overrideWithValue(auth),
    accountRepositoryProvider.overrideWithValue(account),
    profileRepositoryProvider.overrideWithValue(
      AccountProfileRepository(account),
    ),
    watchlistRepositoryProvider.overrideWithValue(ApiWatchlistRepository(api)),
    searchRepositoryProvider.overrideWithValue(ApiSearchRepository(api)),
    todayRepositoryProvider.overrideWithValue(ApiTodayRepository(api)),
    // Today (P4) and History (P5) stay unavailable: no fake fallback.
  ];
}
