import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/preview.dart';
import 'features/today/data/fake_today_repository.dart';
import 'features/today/data/today_repository.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: [
        if (isUiPreview)
          todayRepositoryProvider.overrideWithValue(FakeTodayRepository()),
      ],
      child: const CinemeApp(),
    ),
  );
}
