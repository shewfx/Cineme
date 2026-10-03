import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/movie_list_tile.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/features/search/application/search_controller.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nav_finders.dart';

Future<void> openSearch(WidgetTester tester, String q) async {
  await tester.pumpWidget(
    ProviderScope(
      retry: noAutomaticRetry,
      overrides: previewOverrides(PreviewStore(latency: Duration.zero)),
      child: const CinemeApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(navTab('Watchlist'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Add movies'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), q);
  await tester.pump(searchDebounce);
  await tester.pumpAndSettle();
}

void phone(WidgetTester tester, {double width = 360, double scale = 1}) {
  tester.view.physicalSize = Size(width * 2, 1280);
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

const _film = Movie(
  tmdbId: 1,
  title: 'Arrival',
  year: 2016,
  runtimeMinutes: null,
  genres: [],
);

Widget tile({required bool stacked}) => MaterialApp(
  home: Scaffold(
    body: MovieListTile(
      movie: _film,
      large: true,
      lines: const ['2016', 'Drama', 'Soon'],
      trailing: stacked
          ? null
          : OutlinedButton(onPressed: () {}, child: const Text('Add')),
      footer: stacked
          ? OutlinedButton(onPressed: () {}, child: const Text('Add'))
          : null,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Large result tile geometry', () {
    testWidgets('the poster anchors the row: taller than the details block', (
      tester,
    ) async {
      phone(tester, width: 390);
      await tester.pumpWidget(tile(stacked: false));
      final poster = tester.getRect(find.byType(MoviePoster));
      final title = tester.getRect(find.text('Arrival'));
      final lastLine = tester.getRect(find.text('Soon'));

      expect(poster.width, 76);
      expect(poster.height, 114, reason: '2:3, taller than the old 72 px');
      // It spans the whole details block, not just the title line.
      expect(poster.top, lessThan(title.top));
      expect(poster.bottom, greaterThan(lastLine.bottom));
      // Details sit beside it, vertically centred on it.
      final details = Rect.fromLTRB(
        title.left,
        title.top,
        title.right,
        lastLine.bottom,
      );
      expect(details.left, greaterThan(poster.right));
      expect(details.center.dy, closeTo(poster.center.dy, 2));
    });

    testWidgets('the action is centred on the poster at the right edge', (
      tester,
    ) async {
      phone(tester, width: 390);
      await tester.pumpWidget(tile(stacked: false));
      final poster = tester.getRect(find.byType(MoviePoster));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      expect(add.center.dy, closeTo(poster.center.dy, 1));
      expect(add.right, closeTo(390 - 24, 1));
    });

    testWidgets(
      'a stacked action keeps the poster top-aligned with the title',
      (tester) async {
        phone(tester, scale: 2);
        await tester.pumpWidget(tile(stacked: true));
        final poster = tester.getRect(find.byType(MoviePoster));
        final title = tester.getRect(find.text('Arrival'));
        final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
        expect(poster.width, 76);
        expect(poster.top, lessThanOrEqualTo(title.top));
        expect(add.top, greaterThan(title.bottom));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Search/Add result rows', () {
    testWidgets('never explain a missing runtime', (tester) async {
      phone(tester);
      await openSearch(tester, 'princess');
      expect(find.text('The Princess Bride'), findsOneWidget);
      expect(find.textContaining('Runtime unknown'), findsNothing);
      expect(find.textContaining('until added'), findsNothing);
      expect(find.textContaining(' min'), findsNothing);
      // The year alone stands in for the line when that is all that is known.
      expect(find.text('1987'), findsOneWidget);
    });

    testWidgets('a known runtime is still shown with the year', (tester) async {
      // Films already in the watchlist have cached details.
      phone(tester);
      await openSearch(tester, 'run lola');
      expect(find.text('1998  ·  81 min'), findsOneWidget);
      expect(find.textContaining('Runtime unknown'), findsNothing);
    });

    testWidgets('no year and no runtime leaves no empty line behind', (
      tester,
    ) async {
      phone(tester);
      await openSearch(tester, 'untitled');
      expect(find.textContaining('Untitled Future'), findsOneWidget);
      expect(find.text('Not released yet'), findsOneWidget);
      expect(find.textContaining('Runtime'), findsNothing);
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(t.data?.trim().isEmpty ?? false, isFalse, reason: 'empty Text');
      }
      // Title directly above "Not released yet": no blank line between.
      final title = tester.getRect(find.textContaining('Untitled Future'));
      final note = tester.getRect(find.text('Not released yet'));
      expect(note.top - title.bottom, lessThan(8));
    });

    testWidgets('Add is on the right, centred on the poster, with its label', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      await openSearch(tester, 'princess');
      final poster = tester.getRect(find.byType(MoviePoster));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      expect(add.center.dy, closeTo(poster.center.dy, 1));
      expect(add.left, greaterThan(poster.right));
      expect(add.right, lessThanOrEqualTo(360));
      expect(find.text('Add to watchlist'), findsNothing);
      expect(
        find.bySemanticsLabel('Add The Princess Bride to watchlist'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('a missing poster shows the designed placeholder, same size', (
      tester,
    ) async {
      phone(tester);
      await openSearch(tester, 'princess');
      // Preview search results carry no poster URL.
      expect(find.byType(Image), findsNothing);
      expect(find.text('T'), findsOneWidget, reason: 'initial on the tile');
      expect(tester.getSize(find.byType(MoviePoster)), const Size(76, 114));
    });

    testWidgets('a narrow 320 px phone keeps the poster and one row', (
      tester,
    ) async {
      phone(tester, width: 320);
      await openSearch(tester, 'princess');
      expect(tester.takeException(), isNull);
      final poster = tester.getRect(find.byType(MoviePoster));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      final title = tester.getRect(find.text('The Princess Bride'));
      expect(poster.width, 76);
      expect(add.right, lessThanOrEqualTo(320));
      expect(add.center.dy, closeTo(poster.center.dy, 1));
      expect(title.right, lessThanOrEqualTo(add.left));
    });

    testWidgets('at 200% text the action stacks under the details', (
      tester,
    ) async {
      phone(tester, scale: 2);
      await openSearch(tester, 'princess');
      expect(tester.takeException(), isNull);
      final poster = tester.getRect(find.byType(MoviePoster));
      final title = tester.getRect(find.text('The Princess Bride'));
      final add = tester.getRect(find.widgetWithText(OutlinedButton, 'Add'));
      expect(poster.width, 76);
      expect(add.top, greaterThan(title.bottom));
      expect(add.left, closeTo(title.left, 1));
      expect(add.right, lessThanOrEqualTo(360));
      // Top-aligned with the details rather than floating mid-way.
      expect(poster.top, lessThanOrEqualTo(title.top));
    });
  });
}
