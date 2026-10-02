import 'package:cineme/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('launches on the Today placeholder with Cinemé branding', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: CinemeApp()));
    await tester.pumpAndSettle();

    expect(find.text('Cinemé'), findsOneWidget);
    expect(find.text('One movie. No scrolling.'), findsOneWidget);
    expect(
      find.text("Tonight's pick is not available in this build yet."),
      findsOneWidget,
    );
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Cinemé');
  });
}
