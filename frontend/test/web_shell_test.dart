import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/widgets/app_canvas.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nav_finders.dart';

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

Finder get floatingNav => find.byKey(const ValueKey('floating-nav'));

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

      final nav = floatingNav;
      expect(
        tester.getSize(nav).width,
        316,
        reason: 'compact: not the full 480 px canvas',
      );
      expect(tester.getCenter(nav).dx, 720);
      // Width-based decisions inside the app see the canvas, not the window.
      final inner = tester.element(navTab('Tonight'));
      expect(MediaQuery.sizeOf(inner).width, 480);
    });

    testWidgets('other tabs stay inside the canvas too', (tester) async {
      sizeWindow(tester, const Size(1440, 900));
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      await tester.tap(navTab('Profile'));
      await tester.pumpAndSettle();
      expect(tester.getSize(floatingNav).width, 316);
      expect(tester.getSize(find.byType(Scaffold).first).width, 480);
    });

    testWidgets('a phone-sized window is not wrapped or narrowed', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844));
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      expect(tester.getSize(floatingNav).width, 316);
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
      expect(tester.getSize(floatingNav).width, 316);
    });
  });

  testWidgets('root-tab horizontal swipes follow order and stop at edges', (
    tester,
  ) async {
    sizeWindow(tester, const Size(390, 844));
    await tester.pumpWidget(webApp());
    await tester.pumpAndSettle();

    Future<void> swipe(double dx) async {
      await tester.dragFrom(const Offset(195, 80), Offset(dx, 0));
      await tester.pumpAndSettle();
    }

    // Right at the first tab cannot wrap to Profile.
    await swipe(140);
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      0,
    );
    await tester.dragFrom(const Offset(195, 80), const Offset(-130, 180));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      0,
      reason: 'diagonal motion is treated as vertical scrolling',
    );
    for (final tab in ['Watchlist', 'History', 'Profile']) {
      await swipe(-140);
      expect(
        tester
            .widget<FloatingNavBar>(find.byType(FloatingNavBar))
            .selectedIndex,
        ['Watchlist', 'History', 'Profile'].indexOf(tab) + 1,
      );
    }
    await swipe(-140);
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      3,
    );

    await swipe(140);
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      2,
    );
    await tester.tap(navTab('Watchlist'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      1,
    );

    final movieTitle = previewWatchlist.first.title;
    await tester.tap(find.text(movieTitle).first);
    await tester.pumpAndSettle();
    expect(find.text('Movie details'), findsOneWidget);
    await tester.dragFrom(const Offset(195, 300), const Offset(-140, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      1,
      reason: 'nested details screens do not respond to tab swipes',
    );

    // Retap the selected branch to return to its root, then use the row's
    // existing remove gesture; it must beat the shell swipe detector.
    await tester.tap(navTab('Watchlist'));
    await tester.pumpAndSettle();
    final showList = find.byTooltip('Show as list');
    if (showList.evaluate().isNotEmpty) {
      await tester.tap(showList);
      await tester.pumpAndSettle();
    }
    await tester.drag(find.text(movieTitle).first, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FloatingNavBar>(find.byType(FloatingNavBar)).selectedIndex,
      1,
      reason: 'watchlist row swipe remains a remove action',
    );
  });

  group('iPhone safe areas', () {
    testWidgets('the navigation floats clear of the sides and home indicator', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844), bottomInset: 34, topInset: 47);
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      final nav = tester.getRect(floatingNav);
      expect(nav.width, 316);
      expect(nav.center.dx, 195, reason: 'centred');
      expect(nav.left, greaterThanOrEqualTo(28));
      // 20 px of air above the 34 px home-indicator region, not touching it.
      expect(nav.bottom, 844 - 34 - 20);
      expect(844 - 34 - nav.bottom, inInclusiveRange(18, 28));
      final label = tester.getCenter(navTab('Tonight')).dy;
      expect(label, inExclusiveRange(nav.top, nav.bottom));
      // Four destinations on one row, each a comfortable target.
      final items = find.descendant(of: floatingNav, matching: navItems);
      expect(items, findsNWidgets(4));
      final rects = [for (var i = 0; i < 4; i++) tester.getRect(items.at(i))];
      expect({for (final r in rects) r.top.round()}, hasLength(1));
      for (final r in rects) {
        expect(r.height, greaterThanOrEqualTo(48));
        expect(r.width, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('the floating nav is real layout, not a paint-only shift', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844), bottomInset: 34, topInset: 47);
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      // No transform anywhere above it, so what is drawn is what is touched.
      expect(
        find.ancestor(of: floatingNav, matching: find.byType(Transform)),
        findsNothing,
      );
      // Tapping the middle of each visible label reaches that destination.
      for (final label in ['Watchlist', 'History', 'Profile', 'Tonight']) {
        final target = tester.getCenter(navTab(label));
        await tester.tapAt(target);
        await tester.pumpAndSettle();
        final nav = tester.widget<FloatingNavBar>(find.byType(FloatingNavBar));
        const order = ['Tonight', 'Watchlist', 'History', 'Profile'];
        expect(nav.selectedIndex, order.indexOf(label), reason: label);
      }
      // The page above ends where the nav begins; nothing hides beneath it.
      final body = tester.getRect(find.byType(Scaffold).first);
      expect(body.bottom, 844);
    });

    testWidgets('small phone and 200% text keep one row and clear the edge', (
      tester,
    ) async {
      sizeWindow(tester, const Size(320, 568), bottomInset: 0);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final nav = tester.getRect(floatingNav);
      expect(nav.left, 28);
      expect(nav.right, 320 - 28);
      expect(nav.bottom, 568 - 20);
      final items = find.descendant(of: floatingNav, matching: navItems);
      final tops = {
        for (var i = 0; i < 4; i++) tester.getRect(items.at(i)).top.round(),
      };
      expect(tops, hasLength(1), reason: 'still one row');
    });

    testWidgets('page headers start below the status bar / notch', (
      tester,
    ) async {
      sizeWindow(tester, const Size(390, 844), bottomInset: 34, topInset: 47);
      await tester.pumpWidget(webApp());
      await tester.pumpAndSettle();
      await tester.tap(navTab('Watchlist'));
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
      await tester.tap(navTab('Watchlist'));
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
