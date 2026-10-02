import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'routing/app_router.dart';

/// Riverpod 3 retries failed providers automatically by default. Cinemé
/// shows the failure and lets the user retry explicitly (FRONTEND_SPEC).
Duration? noAutomaticRetry(int retryCount, Object error) => null;

class CinemeApp extends ConsumerWidget {
  const CinemeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Cinemé',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
