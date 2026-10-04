import 'package:cineme/core/theme/app_theme.dart';
import 'package:cineme/core/widgets/rating_stars.dart';
import 'package:cineme/features/today/presentation/feedback_sheets.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:cineme/shared/models/viewing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selector starts unrated and selects only whole stars', (
    tester,
  ) async {
    Rating? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => FiveStarSelector(
              value: selected,
              onChanged: (rating) => setState(() => selected = rating),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Not rated'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.byTooltip('3 out of 5'));
    await tester.pump();
    expect(selected, Rating.three);
    expect(find.text('3 out of 5'), findsOneWidget);

    final filled = tester.widgetList<Icon>(find.byIcon(Icons.star_rounded));
    expect(filled, hasLength(3));
    expect(filled.every((star) => star.color == AppColors.accent), isTrue);
    final empty = tester.widgetList<Icon>(
      find.byIcon(Icons.star_outline_rounded),
    );
    expect(empty, hasLength(2));
    expect(empty.every((star) => star.color == AppColors.textMuted), isTrue);
  });

  testWidgets('rating sheet preselects, saves, clears and dismisses safely', (
    tester,
  ) async {
    (bool, Rating?)? result;
    final navigatorKey = GlobalKey<NavigatorState>();
    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Open rating'));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showRatingSheet(
                  context,
                  movie: previewWatchlist.first,
                  current: Rating.four,
                );
              },
              child: const Text('Open rating'),
            ),
          ),
        ),
      ),
    );

    await open(tester);
    expect(find.text(previewWatchlist.first.title), findsOneWidget);
    expect(find.text('4 out of 5'), findsOneWidget);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(result, isNull, reason: 'dismissal does not save');

    await open(tester);
    await tester.tap(find.byTooltip('2 out of 5'));
    await tester.tap(find.text('Save rating'));
    await tester.pumpAndSettle();
    expect(result, (true, Rating.two));

    await open(tester);
    await tester.tap(find.text('Clear rating'));
    await tester.pumpAndSettle();
    expect(result, (true, null));
  });
}
