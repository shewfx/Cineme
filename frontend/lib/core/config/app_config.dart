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

  final String apiBaseUrl;
  final String supabaseUrl;
  final String supabasePublishableKey;

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
