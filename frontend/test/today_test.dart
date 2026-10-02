import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/choice_pill.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/features/today/presentation/today_widgets.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PreviewStore store({List<Movie> inventory = previewWatchlist}) =>
    PreviewStore(watchlist: inventory, latency: Duration.zero);

FakeTodayRepository fake({List<Movie> inventory = previewWatchlist}) =>
    FakeTodayRepository(store(inventory: inventory));

/// The full preview build: every fake repository over one shared store.
Widget previewApp([PreviewStore? s]) => ProviderScope(
  retry: noAutomaticRetry,
  overrides: previewOverrides(s ?? store()),
  child: const CinemeApp(),
);

/// Scrolls the option into view first, as a user would.
Future<void> tapText(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pump();
  await tester.tap(find.text(label));
  await tester.pump();
}

/// True if any pill with this label is selected (labels can repeat, e.g.
/// the feeling-down follow-up "Surprise me").
bool isSelected(WidgetTester tester, String label) => tester
    .widgetList<ChoicePill>(find.widgetWithText(ChoicePill, label))
    .any((p) => p.selected);

void main() {
  group('FakeTodayRepository', () {
    test(
      'every intent and time option yields one film inside the cap',
      () async {
        for (final intent in DesiredExperience.values) {
          for (final (cap, _) in runtimeOptions) {
            final envelope = await fake().choose(
              SessionContext(desiredExperience: intent, maxRuntimeMinutes: cap),
            );
            final runtime = envelope.recommendation!.movie.runtimeMinutes!;
            expect(runtime <= (cap ?? 600), isTrue, reason: '$intent cap $cap');
            expect(envelope.state, TodayStatus.offered);
          }
        }
      },
    );

    test('mood never changes the pick; intent does', () async {
      Future<int> pick(DesiredExperience intent, CurrentMood? mood) async =>
          (await fake().choose(
            SessionContext(desiredExperience: intent, currentMood: mood),
          )).recommendation!.movie.tmdbId;

      for (final intent in DesiredExperience.values) {
        final baseline = await pick(intent, null);
        for (final mood in CurrentMood.values) {
          expect(await pick(intent, mood), baseline, reason: '$intent $mood');
        }
      }
      // Sad + Comfort and Sad + Let me feel it stay distinct intents.
      expect(
        await pick(DesiredExperience.comfort, CurrentMood.down),
        isNot(await pick(DesiredExperience.feelIt, CurrentMood.down)),
      );
    });

    test(
      'unknown runtime is excluded under a cap, never treated as zero',
      () async {
        const unknown = Movie(
          tmdbId: 813,
          title: 'Airplane!',
          year: 1980,
          runtimeMinutes: null,
          genres: [Genre(35, 'Comedy')],
        );
        final groundhog = previewWatchlist.firstWhere((m) => m.tmdbId == 137);
        // Honest no match: one film has unknown runtime, one is too long.
        final r = await fake(inventory: [unknown, groundhog]).choose(
          const SessionContext(
            desiredExperience: DesiredExperience.makeMeLaugh,
            maxRuntimeMinutes: 90,
          ),
        );
        expect(r.state, TodayStatus.noMatch);
        expect(r.recommendation, isNull);
        expect(r.noMatch!.candidateCount, 2);
        expect(r.noMatch!.counts, {
          ExclusionCode.runtimeUnknown: 1,
          ExclusionCode.runtimeExceeded: 1,
        });
      },
    );

    test(
      'reasons are factual: runtime fit only when a cap was chosen',
      () async {
        final capped = await fake().choose(
          const SessionContext(
            desiredExperience: DesiredExperience.exciting,
            maxRuntimeMinutes: 90,
          ),
        );
        expect(capped.recommendation!.reasons, hasLength(2));
        final fit = capped.recommendation!.reasons
            .whereType<FitsRuntime>()
            .single;
        expect((fit.runtimeMinutes, fit.capMinutes), (81, 90));

        final surprise = await fake().choose(
          const SessionContext(desiredExperience: DesiredExperience.surprise),
        );
        expect(surprise.recommendation!.reasons.single, isA<SurpriseChosen>());
      },
    );
  });

  group('Tonight preview', () {
    testWidgets('normal build shows no fake movie or context controls', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(retry: noAutomaticRetry, child: CinemeApp()),
      );
      await tester.pumpAndSettle();
      expect(
        find.text("Tonight's pick is not available in this build yet."),
        findsOneWidget,
      );
      expect(find.text('Pick my movie'), findsNothing);
      expect(find.byType(MoviePoster), findsNothing);
    });

    testWidgets('Pick my movie is disabled until an intent is chosen', (
      tester,
    ) async {
      await tester.pumpWidget(previewApp());
      await tester.pumpAndSettle();

      expect(find.text('What do you want from tonight?'), findsOneWidget);
      expect(find.text('UI preview'), findsNothing); // documented in TOOLING
      FilledButton button() =>
          tester.widget(find.widgetWithText(FilledButton, 'Pick my movie'));
      expect(button().onPressed, isNull);
      // The disabled button tells screen readers what unlocks it.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.hint == 'Choose what you want from tonight first',
        ),
        findsOneWidget,
      );

      // Feeling down selects no intent, and certainly not comedy.
      await tapText(tester, 'Down');
      await tester.pump();
      expect(isSelected(tester, 'Down'), isTrue);
      for (final intent in DesiredExperience.values) {
        expect(isSelected(tester, intent.label), isFalse, reason: intent.label);
      }
      expect(button().onPressed, isNull);

      await tapText(tester, 'Comforting');
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('500-film watchlist still renders exactly ONE movie', (
      tester,
    ) async {
      final inventory = [
        ...previewWatchlist,
        for (var i = 0; i < 500 - previewWatchlist.length; i++)
          Movie(
            tmdbId: 900000 + i,
            title: 'Filler $i',
            year: 2000,
            runtimeMinutes: 95,
            genres: const [],
          ),
      ];
      await tester.pumpWidget(previewApp(store(inventory: inventory)));
      await tester.pumpAndSettle();

      await tapText(tester, 'Keep me hooked');
      await tapText(tester, 'Tired');
      await tapText(tester, 'Up to 90 min');
      await tester.pump();
      await tapText(tester, 'Pick my movie');
      await tester.pumpAndSettle();

      expect(find.byType(MoviePoster), findsOneWidget);
      expect(find.byKey(const ValueKey('tonight-title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('tonight-title'))).data,
        'Run Lola Run',
      );
      expect(find.textContaining('Filler'), findsNothing);
      expect(find.text('Watch Tonight'), findsOneWidget);
      expect(
        find.text('1998  ·  81 min  ·  Action, Drama, Thriller'),
        findsOneWidget,
      );
      expect(
        find.text('Its thriller genre fits “Keep me hooked”.'),
        findsOneWidget,
      );
      expect(
        find.text('At 81 minutes, it fits your 90-minute limit.'),
        findsOneWidget,
      );
      // Intent and mood are shown separately.
      expect(
        find.text('Keep me hooked  ·  up to 90 min  ·  feeling tired'),
        findsOneWidget,
      );
      // Offered: feedback actions, but no completion or feed actions.
      expect(find.text('Pick another'), findsOneWidget);
      expect(find.text('Already seen'), findsOneWidget);
      for (final absent in ['Mark watched', 'More like this', 'Top picks']) {
        expect(find.text(absent), findsNothing, reason: absent);
      }
    });

    testWidgets('Watch Tonight is intent, never watched completion', (
      tester,
    ) async {
      await tester.pumpWidget(previewApp());
      await tester.pumpAndSettle();
      await tapText(tester, 'Exciting');
      await tester.pump();
      await tapText(tester, 'Pick my movie');
      await tester.pumpAndSettle();

      await tapText(tester, 'Watch Tonight');
      await tester.pumpAndSettle();
      // Accepted: still the same single film, now a plan, not a viewing.
      expect(find.text("Tonight's plan"), findsOneWidget);
      expect(find.text('Mark watched'), findsOneWidget);
      expect(find.text('Watch Tonight'), findsNothing);
      expect(find.byType(MoviePoster), findsOneWidget);
    });

    testWidgets('flow fits a small phone at 200% text', (tester) async {
      tester.view.physicalSize = const Size(720, 1280); // 360x640 dp
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(previewApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tapText(tester, 'Let me feel it');
      await tester.pump();
      await tapText(tester, 'Pick my movie');
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(MoviePoster), findsOneWidget);
      expect(find.text('Watch Tonight').hitTestable(), findsOneWidget);
    });
  });
}
