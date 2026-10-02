import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/preview.dart';
import 'preview/preview_store.dart';

void main() {
  runApp(
    ProviderScope(
      retry: noAutomaticRetry,
      overrides: isUiPreview ? previewOverrides(PreviewStore()) : const [],
      child: const CinemeApp(),
    ),
  );
}
