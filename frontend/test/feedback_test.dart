import 'package:cineme/app.dart';
import 'package:cineme/core/widgets/movie_poster.dart';
import 'package:cineme/preview/preview_catalog.dart';
import 'package:cineme/preview/preview_store.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:cineme/shared/models/viewing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nav_finders.dart';

PreviewStore store({List<Movie> watchlist = previewWatchlist}) =>
    PreviewStore(watchlist: watchlist, latency: Duration.zero);

const hooked = SessionContext(
  desiredExperience: DesiredExperience.keepMeHooked,
);

/// Store plus its fakes, sharing state like the preview build.
class Rig {
  Rig([List<Movie> watchlist = previewWatchlist])
    : s = store(watchlist: watchlist);

  final PreviewStore s;
  late final today = FakeTodayRepository(s);
  late final watchlist = FakeWatchlistRepository(s);
  late final history = FakeHistoryRepository(s);
  late final profile = FakeProfileRepository(s);

  Future<Recommendation> current() async =>
      (await today.today()).recommendation!;

  Future<RejectResult> skip({bool another = true}) async => today.reject(
    (await current()).id,
    RejectReason.notTonight,
    chooseAnother: another,
  );

  Future<List<int>> watchlistIds() async => [
    for (final e in (await watchlist.list()).items) e.movie.tmdbId,
  ];
}

Matcher conflict(String code) =>
    throwsA(isA<TodayConflict>().having((c) => c.code, 'code', code));

Widget app(PreviewStore s) => ProviderScope(
  retry: noAutomaticRetry,
  overrides: previewOverrides(s),
  child: const CinemeApp(),
);

Future<void> tapText(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Opens the Reason dropdown in the "Not this one?" sheet and picks [label].
/// Choosing never submits; the caller taps Show another.
Future<void> chooseReason(WidgetTester tester, String label) async {
  await tapText(tester, 'Select a reason');
  await tapText(tester, label);
}

String shownTitle(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('tonight-title'))).data!;

Future<void> pickHooked(WidgetTester tester) async {
  await tapText(tester, 'Choose one');
  await tapText(tester, 'Keep me hooked');
  await tapText(tester, 'Pick my movie');
}

/// Opens the selector currently showing [current] and picks [option].
Future<void> select(WidgetTester tester, String current, String option) async {
  await tapText(tester, current);
  await tapText(tester, option);
}

void main() {
  group('Lifecycle (preview store)', () {
    test('Watch Tonight is intention: no viewing, film stays saved', () async {
      final r = Rig();
      final pick = await r.today.choose(hooked);
      final before = (await r.history.viewings()).items.length;

      final accepted = await r.today.accept(pick.recommendation!.id);

      expect(accepted.state, TodayStatus.accepted);
      expect(
        accepted.recommendation!.movie.tmdbId,
        pick.recommendation!.movie.tmdbId,
      );
      expect((await r.history.viewings()).items, hasLength(before));
      expect(
        await r.watchlistIds(),
        contains(pick.recommendation!.movie.tmdbId),
      );
    });

    test(
      'Mark watched completes tonight once; the day then stays complete',
      () async {
        final r = Rig();
        final pick = (await r.today.choose(hooked)).recommendation!;
        await r.today.accept(pick.id);

        final done = await r.today.markWatched(pick.id, rating: Rating.four);

        expect(done.state, TodayStatus.completed);
        expect(done.recommendation!.movie.tmdbId, pick.movie.tmdbId);
        expect(done.viewing!.watchedAt, isNotNull);
        expect(done.viewing!.rating, Rating.four);
        expect(await r.watchlistIds(), isNot(contains(pick.movie.tmdbId)));
        await expectLater(r.today.choose(hooked), conflict('TODAY_COMPLETED'));
        await expectLater(
          r.today.saveContext(hooked),
          conflict('TODAY_COMPLETED'),
        );
        expect((await r.today.today()).state, TodayStatus.completed);
      },
    );

    test('rating edits replace the single observation', () async {
      final r = Rig();
      final pick = (await r.today.choose(hooked)).recommendation!;
      final done = await r.today.markWatched(pick.id);
      final count = (await r.history.viewings()).items.length;

      await r.history.rateViewing(done.viewing!.id, Rating.five);
      await r.history.rateViewing(done.viewing!.id, Rating.one);

      final viewings = (await r.history.viewings()).items;
      expect(viewings, hasLength(count));
      expect(
        viewings
            .where((v) => v.movie.tmdbId == pick.movie.tmdbId)
            .single
            .rating,
        Rating.one,
      );
      expect((await r.today.today()).viewing!.rating, Rating.one);
    });

    test(
      'each replacement is ONE new film, never re-offered tonight',
      () async {
        final r = Rig();
        final seen = [
          (await r.today.choose(hooked)).recommendation!.movie.tmdbId,
        ];
        for (var i = 0; i < 2; i++) {
          final result = await r.skip();
          expect(result.outcome, ReplacementOutcome.selected);
          seen.add(result.today.recommendation!.movie.tmdbId);
        }
        expect(
          seen.toSet(),
          hasLength(3),
          reason: 'no film offered twice: $seen',
        );
      },
    );

    test(
      'third rejection pauses; only Continue once or a real change picks',
      () async {
        final r = Rig();
        await r.today.choose(hooked);
        await r.skip();
        await r.skip();
        final third = await r.skip();

        expect(third.outcome, ReplacementOutcome.paused);
        expect(third.today.state, TodayStatus.paused);
        expect(third.today.recommendation, isNull);
        expect(third.today.rejectionCount, 3);

        // Unchanged or mood-only context cannot bypass the pause.
        await expectLater(
          r.today.choose(hooked),
          conflict('CONTEXT_REVIEW_REQUIRED'),
        );
        await expectLater(
          r.today.choose(hooked.copyWith(currentMood: () => CurrentMood.down)),
          conflict('CONTEXT_REVIEW_REQUIRED'),
        );

        // Continue once: exactly one film; the count is not reset.
        final once = await r.today.choose(hooked, continueAfterPause: true);
        expect(once.state, TodayStatus.offered);
        expect(once.rejectionCount, 3);
        final fourth = await r.skip();
        expect(fourth.outcome, ReplacementOutcome.paused);
        expect(fourth.today.rejectionCount, 4);

        // A genuine scoring change allows one attempt without resetting.
        final changed = await r.today.choose(
          const SessionContext(desiredExperience: DesiredExperience.comfort),
        );
        expect(changed.state, TodayStatus.offered);
        expect(changed.rejectionCount, 4);
      },
    );

    test('Stop for tonight records feedback and chooses nothing', () async {
      final r = Rig();
      await r.today.choose(hooked);
      final stop = await r.skip(another: false);
      expect(stop.outcome, ReplacementOutcome.notRequested);
      expect(stop.today.state, TodayStatus.ready);
      expect(stop.today.recommendation, isNull);
      expect(
        stop.today.context!.desiredExperience,
        DesiredExperience.keepMeHooked,
      );
    });

    test(
      'Already seen logs a past viewing, never tonight\'s completion',
      () async {
        final r = Rig();
        final first = (await r.today.choose(hooked)).recommendation!;
        final result = await r.today.reject(
          first.id,
          RejectReason.alreadyWatched,
          chooseAnother: true,
        );

        expect(result.today.state, TodayStatus.offered);
        expect(
          result.today.recommendation!.movie.tmdbId,
          isNot(first.movie.tmdbId),
        );
        final viewing = (await r.history.viewings()).items.firstWhere(
          (v) => v.movie.tmdbId == first.movie.tmdbId,
        );
        expect(viewing.watchedAt, isNull);
        expect(viewing.rating, isNull);
        expect(await r.watchlistIds(), isNot(contains(first.movie.tmdbId)));
      },
    );

    test(
      'Never recommend is reversible and leaves watchlist inventory unchanged',
      () async {
        final r = Rig();
        final first = (await r.today.choose(hooked)).recommendation!;
        await r.today.reject(
          first.id,
          RejectReason.neverRecommend,
          chooseAnother: false,
        );

        expect(
          (await r.profile.profile()).blockedMovies!.map((m) => m.tmdbId),
          [first.movie.tmdbId],
        );
        expect(
          await r.watchlistIds(),
          contains(first.movie.tmdbId),
          reason: 'blocking changes eligibility, not inventory membership',
        );
        expect(
          (await r.history.viewings()).items.any(
            (v) => v.movie.tmdbId == first.movie.tmdbId,
          ),
          isFalse,
        );
        await expectLater(
          r.watchlist.add(first.movie.tmdbId),
          throwsA(
            isA<InventoryConflict>().having(
              (c) => c.code,
              'code',
              'MOVIE_BLOCKED',
            ),
          ),
        );

        await r.profile.unblock(first.movie.tmdbId);
        expect(
          await r.watchlistIds(),
          contains(first.movie.tmdbId),
          reason: 'unblock also leaves inventory unchanged',
        );
        expect(
          (await r.watchlist.add(first.movie.tmdbId)).alreadyPresent,
          isTrue,
        );
      },
    );

    test(
      'Too long: optional lower cap applies; a higher cap is rejected',
      () async {
        final r = Rig();
        final first = (await r.today.choose(hooked))
            .recommendation!; // Knives Out, 131
        final result = await r.today.reject(
          first.id,
          RejectReason.tooLong,
          maxRuntimeMinutes: 90,
          chooseAnother: true,
        );
        expect(result.today.context!.maxRuntimeMinutes, 90);
        expect(
          result.today.recommendation!.movie.runtimeMinutes,
          lessThanOrEqualTo(90),
        );

        final next = result.today.recommendation!;
        await expectLater(
          r.today.reject(
            next.id,
            RejectReason.tooLong,
            maxRuntimeMinutes: 119,
            chooseAnother: true,
          ),
          conflict('VALIDATION_ERROR'),
        );
        // The invalid request changed nothing.
        expect((await r.current()).id, next.id);
      },
    );

    test(
      'Different genre needs film genres and excludes them tonight',
      () async {
        final r = Rig();
        final first = (await r.today.choose(hooked)).recommendation!;
        await expectLater(
          r.today.reject(
            first.id,
            RejectReason.wrongGenre,
            chooseAnother: true,
          ),
          conflict('VALIDATION_ERROR'),
        );
        final comedy = first.movie.genres.firstWhere((g) => g.id == 35).id;
        final result = await r.today.reject(
          first.id,
          RejectReason.wrongGenre,
          avoidGenreIds: {comedy},
          chooseAnother: true,
        );
        expect(result.today.context!.avoidGenreIds, {comedy});
        expect(
          result.today.recommendation!.movie.genres.map((g) => g.id),
          isNot(contains(comedy)),
        );
      },
    );

    test('Something lighter switches tonight to Relaxing', () async {
      final r = Rig();
      final first = (await r.today.choose(hooked)).recommendation!;
      final result = await r.today.reject(
        first.id,
        RejectReason.wantLighter,
        chooseAnother: true,
      );
      expect(result.today.context!.desiredExperience, DesiredExperience.relax);
      expect(result.today.context!.heavinessMax, 0.35);
    });

    test(
      'Edit tonight: mood-only keeps the pick; scoring change clears it',
      () async {
        final r = Rig();
        final pick = (await r.today.choose(hooked)).recommendation!;

        final moodOnly = await r.today.saveContext(
          hooked.copyWith(currentMood: () => CurrentMood.tired),
        );
        expect(moodOnly.recommendation!.id, pick.id);
        expect(moodOnly.context!.currentMood, CurrentMood.tired);

        // Pick with an unchanged scoring context returns the same film.
        final same = await r.today.choose(
          hooked.copyWith(currentMood: () => CurrentMood.upbeat),
        );
        expect(same.recommendation!.id, pick.id);

        final changed = await r.today.saveContext(
          hooked.copyWith(maxRuntimeMinutes: () => 90),
        );
        expect(changed.state, TodayStatus.ready);
        final record = (await r.history.recommendations()).items.firstWhere(
          (x) => x.id == pick.id,
        );
        expect(record.status, RecommendationStatus.superseded);
      },
    );

    test('no match is an honest result; limits are not relaxed', () async {
      final two = previewWatchlist
          .where((m) => m.tmdbId == 104 || m.tmdbId == 546554)
          .toList();
      final r = Rig(two);
      await r.today.choose(hooked);
      await r.skip();
      final result = await r.skip(); // second rejection: nothing left

      expect(result.outcome, ReplacementOutcome.noMatch);
      expect(result.today.state, TodayStatus.noMatch);
      expect(result.today.recommendation, isNull);
      expect(result.today.noMatch!.candidateCount, 2);
      expect(result.today.noMatch!.counts, {
        ExclusionCode.offeredThisSession: 2,
      });

      // A tight cap with nothing short enough is also no match, not a longer film.
      final capped = await Rig(two).today
          .choose(hooked.copyWith(maxRuntimeMinutes: () => 60));
      expect(capped.state, TodayStatus.noMatch);
      expect(capped.noMatch!.counts, {ExclusionCode.runtimeExceeded: 2});
    });

    test('current mood never changes the sequence of picks', () async {
      Future<List<int>> sequence(CurrentMood? mood) async {
        final r = Rig();
        final ctx = hooked.copyWith(currentMood: () => mood);
        final ids = [(await r.today.choose(ctx)).recommendation!.movie.tmdbId];
        for (var i = 0; i < 2; i++) {
          ids.add((await r.skip()).today.recommendation!.movie.tmdbId);
        }
        return ids;
      }

      final baseline = await sequence(null);
      for (final mood in CurrentMood.values) {
        expect(await sequence(mood), baseline, reason: '$mood');
      }
    });
  });

  group('Lifecycle screens', () {
    testWidgets('Pick another shows exactly one different film', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      final first = shownTitle(tester);

      await tapText(tester, 'Not feeling it');
      await chooseReason(tester, 'Just give me another');
      await tapText(tester, 'Show another');

      expect(shownTitle(tester), isNot(first));
      expect(find.byType(MoviePoster), findsOneWidget);
      expect(find.text(first), findsNothing);
    });

    testWidgets('three passes pause; Continue once brings one film', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      for (var i = 0; i < 3; i++) {
        await tapText(tester, 'Not feeling it');
        await chooseReason(tester, 'Not feeling this one');
        if (i == 2) expect(find.textContaining('third pass'), findsOneWidget);
        await tapText(tester, 'Show another');
      }
      expect(find.text("That's 3 passes tonight"), findsOneWidget);
      expect(find.byType(MoviePoster), findsNothing);
      expect(find.text("Adjust tonight's context"), findsOneWidget);

      await tapText(tester, 'Continue once');
      expect(find.byType(MoviePoster), findsOneWidget);
    });

    testWidgets('Watch Tonight, then Mark watched with a rating', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      final title = shownTitle(tester);

      await tapText(tester, 'Watch Tonight');
      expect(find.text("Tonight's plan"), findsOneWidget);
      await tapText(tester, 'Mark watched');
      await tester.tap(find.byTooltip('5 out of 5'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Mark watched');

      expect(find.text('Watched tonight'), findsOneWidget);
      expect(shownTitle(tester), title, reason: 'completed keeps its one card');
      expect(find.text('5 out of 5'), findsOneWidget);
      expect(find.text('Not feeling it'), findsNothing);

      await tapText(tester, 'See history');
      expect(find.text(title), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsWidgets);
    });

    testWidgets('no match explains itself and offers no other films', (
      tester,
    ) async {
      final one = previewWatchlist.where((m) => m.tmdbId == 546554).toList();
      await tester.pumpWidget(app(store(watchlist: one)));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      await tapText(tester, 'Not feeling it');
      await chooseReason(tester, 'Just give me another');
      await tapText(tester, 'Show another');

      expect(
        find.text('Nothing in your watchlist fits tonight'),
        findsOneWidget,
      );
      expect(find.textContaining('1 already offered tonight'), findsOneWidget);
      expect(
        find.text(
          "Couldn't reach Cinemé. Check your connection and try again.",
        ),
        findsNothing,
      );
      expect(find.byType(MoviePoster), findsNothing);
      expect(find.text('Add movies'), findsOneWidget);
    });

    testWidgets('feeling down offers follow-ups and selects nothing', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await tapText(tester, 'Not set');
      await tapText(tester, 'Down');
      // Feeling down chooses no intent, and certainly not comedy.
      expect(find.text('Choose one'), findsOneWidget);
      for (final intent in DesiredExperience.values) {
        expect(find.text(intent.label), findsNothing, reason: intent.label);
      }
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Pick my movie'),
            )
            .onPressed,
        isNull,
      );

      // The intent sheet then offers exactly the four documented follow-ups.
      await tapText(tester, 'Choose one');
      expect(find.text('What would help tonight?'), findsOneWidget);
      for (final (label, _) in downFollowUps) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Make me laugh'), findsNothing);
      expect(find.text('Deep'), findsNothing);
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.selected, isFalse, reason: 'nothing is preselected');
      }
      await tapText(tester, 'Cheer me up');
      expect(find.text('Make me laugh'), findsOneWidget);
      expect(find.text('Cheer me up'), findsNothing);
      expect(find.text('Down'), findsOneWidget);
    });

    testWidgets('Edit tonight keeps the film for a mood-only change', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      final title = shownTitle(tester);

      await tapText(tester, 'Edit tonight');
      await select(tester, 'Not set', 'Tired');
      await tapText(tester, 'Save');
      expect(shownTitle(tester), title);
      expect(find.textContaining('feeling tired'), findsOneWidget);

      await tapText(tester, 'Edit tonight');
      await select(tester, 'Keep me hooked', 'Exciting');
      await tapText(tester, 'Save');
      expect(find.text('Ready for another pick?'), findsOneWidget);
    });

    testWidgets('Edit tonight uses three selectors that restore and clear', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      await tapText(tester, 'Edit tonight');
      // No chip wall: only the current values are shown.
      expect(find.text('Keep me hooked'), findsOneWidget);
      expect(find.text('Make me laugh'), findsNothing);
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text('Any length'), findsOneWidget);

      // The sheet lists every intent and checks the current one.
      await tapText(tester, 'Keep me hooked');
      expect(find.text('Make me laugh'), findsOneWidget);
      final current = find.ancestor(
        of: find.text('Keep me hooked').last,
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: current, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      await tapText(tester, 'Deep');
      expect(find.text('Make me laugh'), findsNothing, reason: 'sheet closed');
      expect(find.text('Deep'), findsOneWidget);

      await select(tester, 'Not set', 'Tired');
      await select(tester, 'Any length', 'Up to 90 min');
      expect(find.text('Tired'), findsOneWidget);
      expect(find.text('Up to 90 min'), findsOneWidget);
      // Optional values clear back to unset.
      await select(tester, 'Tired', 'Not set');
      await select(tester, 'Up to 90 min', 'Any length');
      expect(find.text('Not set'), findsOneWidget);
      expect(find.text('Any length'), findsOneWidget);

      // Dismissing a sheet changes nothing.
      await tapText(tester, 'Deep');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Deep'), findsOneWidget);
    });

    testWidgets('Edit tonight selectors fit 360x640 at 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      await tapText(tester, 'Edit tonight');
      expect(tester.takeException(), isNull);
      await select(tester, 'Any length', 'Under 2 hours');
      expect(tester.takeException(), isNull);
      expect(find.text('Under 2 hours'), findsOneWidget);
      await tapText(tester, 'Keep me hooked');
      expect(find.text('Make me laugh'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Edit tonight back button changes nothing', (tester) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      final title = shownTitle(tester);
      await tapText(tester, 'Edit tonight');
      await select(tester, 'Keep me hooked', 'Exciting');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(shownTitle(tester), title);
      expect(find.text('Keep me hooked'), findsOneWidget); // context line
    });

    testWidgets('Profile labels unbuilt features as coming later', (
      tester,
    ) async {
      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await tester.tap(navTab('Profile'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Editing is coming later'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Coming later'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Coming later'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
    });

    testWidgets('lifecycle screens fit 360x640 at 200% text', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(app(store()));
      await tester.pumpAndSettle();
      await pickHooked(tester);
      expect(tester.takeException(), isNull, reason: 'offered');
      await tapText(tester, 'Not feeling it');
      await chooseReason(tester, 'Different genre');
      expect(tester.takeException(), isNull, reason: 'reject sheet');
      await tapText(tester, 'Comedy');
      await tapText(tester, 'Show another');
      await tapText(tester, 'Watch Tonight');
      expect(tester.takeException(), isNull, reason: 'accepted');
      await tapText(tester, 'Mark watched');
      await tester.tap(find.byTooltip('3 out of 5'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Mark watched');
      expect(tester.takeException(), isNull, reason: 'completed');
    });
  });
}
