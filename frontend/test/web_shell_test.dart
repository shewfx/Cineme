import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/widgets/app_canvas.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget webApp({bool centredCanvas = true}) => ProviderScope(
  retry: noAutomaticRetry,
  overrides: previewOverrides(PreviewStore(latency: Duration.zero)),
  child: CinemeApp(centredCanvas: centredCanvas),
);

void sizeWindow(
  WidgetTester tester,
  Size logical, {
  double bottomInset = 0,
  double topInset = 0,
}) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = logical
    ..padding = FakeViewPadding(top: topInset, bottom: bottomInset)
    ..viewPadding = FakeViewPadding(top: topInset, bottom: bottomInset);
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('hosted web configuration', () {
    const base = AppConfig(
      apiBaseUrl: AppConfig.sameOrigin,
      supabaseUrl: 'https://p.supabase.co',
      supabasePublishableKey: 'sb_publishable_x',
    );

    test(
      'same-origin resolves to the page origin, without path or fragment',
      () {
        expect(
          base.resolveApiBaseUrl(
            Uri.parse('https://cineme.vercel.app/#/today'),
          ),
          'https://cineme.vercel.app',
        );
        expect(
          base.resolveApiBaseUrl(Uri.parse('http://localhost:8080/')),
          'http://localhost:8080',
        );
      },
    );

    test('an explicit API URL is used as given', () {
      const explicit = AppConfig(
        apiBaseUrl: 'https://api.example.com',
        supabaseUrl: 'https://p.supabase.co',
        supabasePublishableKey: 'k',
      );
      expect(
        explicit.resolveApiBaseUrl(Uri.parse('https://cineme.vercel.app/')),
        'https://api.example.com',
      );
    });

    test(
      'same-origin counts as configured; a missing URL is still reported',
      () {
        expect(base.isComplete, isTrue);
        const missing = AppConfig(
          apiBaseUrl: '',
          supabaseUrl: 'https://p.supabase.co',
          supabasePublishableKey: 'k',
        );
        expect(missing.missing, ['API_BASE_URL']);
      },
    );
  });

  group('centred app canvas', () {
    testWidgets('a wide browser keeps the phone layout at 480 px, centred', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1440, 900));
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      final nav = find.byType(NavigationBar);
      expect(tester.getSize(nav).width, 480);
      expect(tester.getCenter(nav).dx, 720);
      // Width-based decisions inside the app see the canvas, not the window.
      final inner = tester.element(find.text('Tonight').first);
      expect(MediaQuery.sizeOf(inner).width, 480);
    });

    testWidgets('other tabs stay inside the canvas too', (tester) async {
      sizeWindow(tester, const Size(1440, 900));
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(NavigationBar)).width, 480);
      expect(tester.getSize(find.byType(Scaffold).first).width, 480);
    });

    testWidgets('a phone-sized window is not wrapped or narrowed', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844));
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(NavigationBar)).width, 390);
      final outside = find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == const Color(0xFF111111),
      );
      expect(outside, findsNothing);
    });

    testWidgets('native builds never get the canvas', (tester) async {
      sizeWindow(tester, const Size(1440, 900));
      await tester.pumpWidget(webApp(centredCanvas: false));
      await tester.pumpAndSettle();

      expect(find.byType(AppCanvas), findsNothing);
      expect(tester.getSize(find.byType(NavigationBar)).width, 1440);
    });
  });

  group('iPhone safe areas', () {
    testWidgets('bottom navigation clears the home indicator', (tester) async {
      sizeWindow(tester, const Size(390, 844));
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();
      final plainHeight = tester.getSize(find.byType(NavigationBar)).height;

      sizeWindow(tester, const Size(390, 844), bottomInset: 34, topInset: 47);
      await tester.pumpAndSettle();

      final nav = find.byType(NavigationBar);
      // The bar grows by exactly the inset and still ends at the screen edge.
      expect(tester.getSize(nav).height, plainHeight + 34);
      expect(tester.getBottomLeft(nav).dy, 844);
      final label = tester.getBottomLeft(find.text('Tonight').first).dy;
      expect(label, lessThanOrEqualTo(844 - 34));
    });
    testWidgets('page headers start below the status bar / notch', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844), bottomInset: 34, topInset: 47);
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watchlist'));
      await tester.pumpAndSettle();

      final title = find.descendant(
        of: find.byType(Scaffold).first,
        matching: find.text('Watchlist'),
      );
      expect(tester.getTopLeft(title.first).dy, greaterThanOrEqualTo(47));
    });

    testWidgets('watchlist poster grid keeps three columns at iPhone width', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844), bottomInset: 34, topInset: 47);
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Watchlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show as posters'));
      await tester.pumpAndSettle();

      final posters = find.byType(MoviePoster);
      expect(posters, findsWidgets);
      final columns = <int>{
        for (var i = 0; i < posters.evaluate().length; i++)
          tester.getTopLeft(posters.at(i)).dx.round(),
      };
      expect(columns.length, greaterThanOrEqualTo(2));
      expect(columns.every((x) => x >= 0 && x < 390), isTrue);
    });
  });
}
