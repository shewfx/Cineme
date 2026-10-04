import 'nav_finders.dart';

import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/choice_pill.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/core/widgets/selector_field.dart';
import 'package:cineme/features/today/presentation/today_intro.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const intro = 'Tonight’s the night.';
const skip = 'Skip, just pick something';

PreviewStore store({List<Movie> inventory = previewWatchlist}) =>
    PreviewStore(watchlist: inventory, latency: Duration.zero);

Widget app({PreviewStore? s, Duration? introDuration}) => ProviderScope(
  retry: noAutomaticRetry,
  overrides: [
    ...previewOverrides(s ?? store()),
    if (introDuration != null)
      tonightIntroDurationProvider.overrideWithValue(introDuration),
  ],
  child: const CinemeApp(),
);

Finder field(String label) =>
    find.byWidgetPredicate((w) => w is SelectorField && w.label == label);

const intentLabel = 'What do you want from tonight?';

Future<void> openSheet(WidgetTester tester, String label) async {
  // Tap the value box (not the label above it, which wraps at large text).
  final box = find.descendant(of: field(label), matching: find.byType(InkWell));
  await tester.ensureVisible(box);
  await tester.pumpAndSettle();
  await tester.tap(box);
  await tester.pumpAndSettle();
}

Future<void> pickOption(WidgetTester tester, String option) async {
  final target = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(option),
  );
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      80,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void smallPhoneLargeText(WidgetTester tester) {
  tester.view.physicalSize = const Size(720, 1280); // 360x640 dp
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Tonight startup', () {
    testWidgets('opens on “Tonight’s the night.”, then the setup fades in', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(intro), findsOneWidget);
      expect(find.byType(SelectorField), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text(intro), findsNothing);
      expect(find.byType(SelectorField), findsNWidgets(3));
    });

    testWidgets('it is short: the setup is up within about 1.5 seconds', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 1)); // first tick
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SelectorField), findsNWidgets(3));
      expect(find.text(intro), findsNothing);
    });

    testWidgets('it plays once per launch, not on every visit to the tab', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(navTab('Watchlist'));
      await tester.pumpAndSettle();
      await tester.tap(navTab('Tonight'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(intro), findsNothing);
      expect(find.byType(SelectorField), findsNWidgets(3));
    });

    testWidgets('a zero duration skips it entirely', (tester) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text(intro), findsNothing);
      expect(find.byType(SelectorField), findsNWidgets(3));
    });

    testWidgets('an existing pick is not held behind the opening', (
      tester,
    ) async {
      final s = store();
      await tester.pumpWidget(app(s: s, introDuration: Duration.zero));
      await tester.pumpAndSettle();
      await openSheet(tester, intentLabel);
      await pickOption(tester, 'Exciting');
      await tester.tap(find.text('Pick my movie'));
      await tester.pumpAndSettle();
      expect(find.byType(MoviePoster), findsOneWidget);

      // A fresh launch (intro not yet seen) goes straight to the pick.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(s: s));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(intro), findsNothing);
      expect(find.byType(MoviePoster), findsOneWidget);
    });

    testWidgets('fits a small phone at 200% text', (tester) async {
      smallPhoneLargeText(tester);
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(intro), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Tonight setup uses compact selectors', () {
    testWidgets('three selector fields, no chip wall', (tester) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();

      expect(find.byType(ChoicePill), findsNothing);
      expect(find.byType(SelectorField), findsNWidgets(3));
      expect(field(intentLabel), findsOneWidget);
      expect(field('How are you feeling?'), findsOneWidget);
      expect(field('How much time?'), findsOneWidget);
      // Current values only: no option is listed until a field is opened.
      for (final intent in DesiredExperience.values) {
        expect(find.text(intent.label), findsNothing, reason: intent.label);
      }
      expect(find.text('Choose one'), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text('Any length'), findsOneWidget);
      // Feeling and time are optional, and feeling never decides the pick.
      expect(find.text('Optional · never decides the pick'), findsOneWidget);
      expect(find.text('Optional'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNWidgets(3));
    });

    testWidgets('a field opens a bottom sheet that checks the current value', (
      tester,
    ) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();

      await openSheet(tester, intentLabel);
      expect(find.byType(BottomSheet), findsOneWidget);
      for (final intent in DesiredExperience.values) {
        final option = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(intent.label),
        );
        if (option.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            option,
            80,
            scrollable: find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            ),
          );
        }
        expect(option, findsOneWidget, reason: intent.label);
      }
      expect(
        find.byIcon(Icons.check),
        findsNothing,
        reason: 'nothing chosen yet',
      );

      await pickOption(tester, 'Deep');
      expect(
        find.byType(BottomSheet),
        findsNothing,
        reason: 'choosing closes it',
      );
      expect(find.text('Deep'), findsOneWidget);

      // Reopening restores the selection with a check beside it.
      await openSheet(tester, intentLabel);
      final deep = find.ancestor(
        of: find.text('Deep').last,
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: deep, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(10, 10)); // dismiss: nothing changes
      await tester.pumpAndSettle();
      expect(find.text('Deep'), findsOneWidget);
    });

    testWidgets('optional fields choose and clear; feeling never picks', (
      tester,
    ) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      FilledButton pickButton() =>
          tester.widget(find.widgetWithText(FilledButton, 'Pick my movie'));

      await openSheet(tester, 'How are you feeling?');
      await pickOption(tester, 'Tired');
      await openSheet(tester, 'How much time?');
      await pickOption(tester, 'Up to 90 min');
      expect(find.text('Tired'), findsOneWidget);
      expect(find.text('Up to 90 min'), findsOneWidget);
      // Feeling and time alone do not unlock a pick.
      expect(pickButton().onPressed, isNull);
      expect(find.text('Choose one'), findsOneWidget);

      await openSheet(tester, intentLabel);
      await pickOption(tester, 'Relaxing');
      expect(pickButton().onPressed, isNotNull);

      await openSheet(tester, 'How are you feeling?');
      await pickOption(tester, 'Not set');
      await openSheet(tester, 'How much time?');
      await pickOption(tester, 'Any length');
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text('Any length'), findsOneWidget);
    });

    testWidgets('the picked context is exactly what the selectors show', (
      tester,
    ) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      await openSheet(tester, intentLabel);
      await pickOption(tester, 'Keep me hooked');
      await openSheet(tester, 'How are you feeling?');
      await pickOption(tester, 'Tired');
      await openSheet(tester, 'How much time?');
      await pickOption(tester, 'Up to 90 min');
      await tester.tap(find.text('Pick my movie'));
      await tester.pumpAndSettle();

      expect(
        find.text('Keep me hooked  ·  up to 90 min  ·  feeling tired'),
        findsOneWidget,
      );
      expect(find.byType(MoviePoster), findsOneWidget);
    });

    testWidgets('Edit tonight is the same three fields, prefilled', (
      tester,
    ) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      await openSheet(tester, intentLabel);
      await pickOption(tester, 'Exciting');
      await tester.tap(find.text('Pick my movie'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit tonight'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectorField), findsNWidgets(3));
      expect(field(intentLabel), findsOneWidget);
      expect(find.text('Exciting'), findsOneWidget);
      expect(find.byType(ChoicePill), findsNothing);
      expect(
        find.text(skip),
        findsNothing,
        reason: 'skip is for a fresh start',
      );
    });

    testWidgets('fits 360x640 at 200% text with every action reachable', (
      tester,
    ) async {
      smallPhoneLargeText(tester);
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await openSheet(tester, intentLabel);
      expect(tester.takeException(), isNull);
      await pickOption(tester, 'Let me feel it');
      await tester.ensureVisible(find.text('Pick my movie'));
      await tester.pumpAndSettle();
      expect(find.text('Pick my movie').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text(skip));
      await tester.pumpAndSettle();
      expect(find.text(skip).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Skip', () {
    testWidgets('picks one watchlist film immediately, no selections needed', (
      tester,
    ) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      expect(
        find.text('Pick my movie'),
        findsOneWidget,
        reason: 'main action stays',
      );
      expect(find.text(skip), findsOneWidget);

      await tester.tap(find.text(skip));
      await tester.pumpAndSettle();

      expect(find.byType(MoviePoster), findsOneWidget);
      expect(find.byType(SelectorField), findsNothing);
      final title = tester
          .widget<Text>(find.byKey(const ValueKey('tonight-title')))
          .data!;
      expect(previewWatchlist.map((m) => m.title), contains(title));
      // It is the explicit Surprise me intent: no mood, no time.
      expect(find.text('Surprise me'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r"feeling (down|tired|okay|upbeat)")),
        findsNothing,
      );
      expect(find.textContaining('·  up to'), findsNothing);
    });

    testWidgets('ignores anything half-selected', (tester) async {
      await tester.pumpWidget(app(introDuration: Duration.zero));
      await tester.pumpAndSettle();
      await openSheet(tester, 'How much time?');
      await pickOption(tester, 'Up to 90 min');
      await openSheet(tester, 'How are you feeling?');
      await pickOption(tester, 'Down');

      await tester.tap(find.text(skip));
      await tester.pumpAndSettle();

      expect(find.text('Surprise me'), findsOneWidget);
      expect(find.textContaining('up to 90 min'), findsNothing);
      expect(find.textContaining('feeling down'), findsNothing);
    });

    testWidgets('still respects eligibility: no film outside the watchlist', (
      tester,
    ) async {
      // The only saved film is unreleased, so nothing is eligible tonight.
      await tester.pumpWidget(
        app(
          s: store(inventory: [previewUnreleased]),
          introDuration: Duration.zero,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(skip));
      await tester.pumpAndSettle();

      expect(
        find.text('Nothing in your watchlist fits tonight'),
        findsOneWidget,
      );
      expect(find.byType(MoviePoster), findsNothing);
      expect(find.text('Watch Tonight'), findsNothing);
    });

    testWidgets('is one pick: reopening shows the same film', (tester) async {
      final s = store();
      await tester.pumpWidget(app(s: s, introDuration: Duration.zero));
      await tester.pumpAndSettle();
      await tester.tap(find.text(skip));
      await tester.pumpAndSettle();
      final first = tester
          .widget<Text>(find.byKey(const ValueKey('tonight-title')))
          .data;

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(s: s, introDuration: Duration.zero));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tonight-title'))).data,
        first,
      );
    });
  });
}
