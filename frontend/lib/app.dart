import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'core/widgets/app_canvas.dart';
import 'routing/app_router.dart';

/// Riverpod 3 retries failed providers automatically by default. Cinemé
/// shows the failure and lets the user retry explicitly (FRONTEND_SPEC).
Duration? noAutomaticRetry(int retryCount, Object error) => null;

class CinemeApp extends ConsumerWidget {
  /// [centredCanvas] limits a wide browser window to the phone layout; it is
  /// on for web builds only, so Android is unchanged.
  const CinemeApp({super.key, this.centredCanvas = kIsWeb});

  final bool centredCanvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Cinemé',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      builder: centredCanvas
          ? (context, child) => AppCanvas(child: child!)
          : null,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
