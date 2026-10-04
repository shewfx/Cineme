import 'package:cineme/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_finders.dart';

void main() {
  testWidgets('unconfigured normal build launches to an honest config screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(retry: noAutomaticRetry, child: CinemeApp()),
    );
    await tester.pumpAndSettle();

    // Without --dart-define configuration the app says so; it never shows
    // preview data or a fake signed-in state.
    expect(find.text('This build is not configured'), findsOneWidget);
    expect(find.byType(FloatingNavBar), findsNothing);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Cinemé');
  });
}
