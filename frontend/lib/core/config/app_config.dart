import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Build-time configuration (`--dart-define` / `--dart-define-from-file`).
/// The publishable key is public by design; no secret ever goes here.
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  static const fromEnvironment = AppConfig(
    apiBaseUrl: String.fromEnvironment('API_BASE_URL'),
    supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  /// `API_BASE_URL=same-origin` makes the hosted web build call the API on the
  /// origin that served it (one Vercel project), so the same build works on
  /// the Vercel domain and any custom domain attached later.
  static const sameOrigin = 'same-origin';

  final String apiBaseUrl;
  final String supabaseUrl;
  final String supabasePublishableKey;

  /// The URL the API client uses; [origin] is `Uri.base` of the running page.
  String resolveApiBaseUrl(Uri origin) =>
      apiBaseUrl == sameOrigin ? origin.origin : apiBaseUrl;

  /// Names of required values that are missing, for an honest error screen.
  List<String> get missing => [
    if (apiBaseUrl.isEmpty) 'API_BASE_URL',
    if (supabaseUrl.isEmpty) 'SUPABASE_URL',
    if (supabasePublishableKey.isEmpty) 'SUPABASE_PUBLISHABLE_KEY',
  ];

  bool get isComplete => missing.isEmpty;
}

final appConfigProvider = Provider<AppConfig>(
  (ref) => AppConfig.fromEnvironment,
);
