import 'dart:async';

import 'package:cineme/app.dart';
import 'package:cineme/core/config/app_config.dart';
import 'package:cineme/core/network/api_client.dart';
import 'package:cineme/core/network/series_dto.dart';
import 'package:cineme/core/widgets/selector_field.dart';
import 'package:cineme/features/auth/data/account_repository.dart';
import 'package:cineme/features/auth/data/auth_repository.dart';
import 'package:cineme/features/preferences/data/profile_repository.dart';
import 'package:cineme/features/history/data/history_repository.dart';
import 'package:cineme/features/search/data/search_repository.dart';
import 'package:cineme/features/series/data/series_repository.dart';
import 'package:cineme/features/today/data/today_dto.dart';
import 'package:cineme/features/today/data/today_repository.dart';
import 'package:cineme/features/watchlist/data/watchlist_repository.dart';
import 'package:cineme/shared/models/inventory.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:cineme/shared/models/profile.dart';
import 'package:cineme/shared/models/series.dart';
import 'package:cineme/shared/models/session_context.dart';
import 'package:cineme/shared/models/today_state.dart';
import 'package:cineme/shared/models/viewing.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_test.dart' show FakeAuth, alice, config;
import 'nav_finders.dart';

// --- a tiny world the fakes share ------------------------------------------------------

Movie film(int id, String title) => Movie(
  tmdbId: id,
  title: title,
  year: 2000 + id,
  runtimeMinutes: 100,
  genres: const [Genre(18, 'Drama')],
);

final aired = DateTime.utc(2020);

Series show(int id, String name) => Series(
  tmdbId: id,
  name: name,
  year: 2015,
  genres: const [Genre(18, 'Drama')],
  status: 'Returning Series',
);

class World {
  final movies = <WatchlistEntry>[];
  final shows = <ShowEntry>[];
  final catalog = <int, Series>{};
  final episodes = <int, List<Episode>>{};
  TonightMedia? tonightMedia = TonightMedia.movies;
  var tonightMediaCalls = <TonightMedia>[];
  int addShowCalls = 0;
  int markCalls = 0;
  int progressCalls = 0;
  final progressRequests = <(int, int)?>[];
  TodayEnvelope today = const TodayEnvelope.notStarted();
  ApiError? failSetProgress;
  final episodeViews = <EpisodeViewingRecord>[];
  final records = <RecommendationRecord>[];

  World() {
    for (final (id, name) in [(1399, 'Alpha'), (1400, 'Beta')]) {
      catalog[id] = show(id, name);
      episodes[id] = [
        for (var s = 1; s <= 2; s++)
          for (var e = 1; e <= 5; e++)
            Episode(
              seasonNumber: s,
              episodeNumber: e,
              name: 'Ep $s.$e',
              airDate: aired,
              runtimeMinutes: 45,
            ),
      ];
    }
  }

  NextEpisode nextFor(int id, SeriesProgress? p) {
    final all = episodes[id]!;
    final after = all.where(
      (e) =>
          p == null ||
          e.seasonNumber > p.season ||
          (e.seasonNumber == p.season && e.episodeNumber > p.episode),
    );
    return after.isEmpty
        ? const NextEpisode(state: NextState.caughtUp)
        : NextEpisode(state: NextState.upNext, episode: after.first);
  }

  ShowEntry addShow(int id, {(int, int)? progress, int version = 1}) {
    final p = progress == null
        ? null
        : SeriesProgress(
            season: progress.$1,
            episode: progress.$2,
            version: version,
          );
    final entry = ShowEntry(
      id: 'show-$id',
      series: catalog[id]!,
      addedAt: DateTime.utc(2026, 10, 8),
      progress: p,
      progressVersion: version,
      next: nextFor(id, p),
    );
    shows.removeWhere((s) => s.series.tmdbId == id);
    shows.insert(0, entry);
    return entry;
  }

  void addMovie(int id, String title) => movies.insert(
    0,
    WatchlistEntry(
      id: 'movie-$id',
      movie: film(id, title),
      addedAt: DateTime.utc(2026, 10, 7),
    ),
  );
}

class FakeSeries implements SeriesRepository {
  FakeSeries(this.w);
  final World w;

  @override
  Future<SeriesSearchPage> search(String query, {int page = 1}) async =>
      SeriesSearchPage(
        page: 1,
        totalPages: 1,
        results: [
          for (final s in w.catalog.values)
            if (s.name.toLowerCase().contains(query.toLowerCase())) s,
        ],
      );

  @override
  Future<SeriesDetails> details(int tmdbId) async {
    final entry = w.shows.where((s) => s.series.tmdbId == tmdbId).firstOrNull;
    return SeriesDetails(
      series: w.catalog[tmdbId]!,
      overview: 'A show about things.',
      seasonCount: 2,
      stale: false,
      limitations:
          "Specials aren't included yet. Cinemé follows TMDB's standard order.",
      entry: entry,
    );
  }

  @override
  Future<List<SeasonInfo>> seasons(int tmdbId) async => [
    for (var s = 1; s <= 2; s++)
      SeasonInfo(
        number: s,
        episodes: [
          for (final e in w.episodes[tmdbId]!)
            if (e.seasonNumber == s) e,
        ],
      ),
  ];

  @override
  Future<SeriesAddResult> add(int tmdbId) async {
    w.addShowCalls++;
    final existing = w.shows.where((s) => s.series.tmdbId == tmdbId);
    if (existing.isNotEmpty) {
      return SeriesAddResult(entry: existing.first, alreadyPresent: true);
    }
    return SeriesAddResult(entry: w.addShow(tmdbId), alreadyPresent: false);
  }

  @override
  Future<ShowEntry> setProgress(
    int tmdbId, {
    required int expectedVersion,
    required (int, int)? last,
  }) async {
    w.progressCalls++;
    w.progressRequests.add(last);
    if (w.failSetProgress != null) throw w.failSetProgress!;
    final entry = w.shows.firstWhere((s) => s.series.tmdbId == tmdbId);
    if (entry.progressVersion != expectedVersion) {
      throw const ApiError(
        status: 409,
        code: 'VERSION_CONFLICT',
        message: 'Your progress changed elsewhere.',
      );
    }
    return w.addShow(tmdbId, progress: last, version: expectedVersion + 1);
  }

  final blockedIds = <int>{};

  @override
  Future<List<Series>> blocked() async => [
    for (final id in blockedIds) w.catalog[id]!,
  ];

  @override
  Future<void> unblock(int tmdbId) async => blockedIds.remove(tmdbId);

  @override
  Future<Paged<EpisodeViewingRecord>> viewings({String? cursor}) async =>
      Paged(List.of(w.episodeViews), null);

  @override
  Future<EpisodeWatchedResult> markNextWatched(
    int tmdbId, {
    required int season,
    required int episode,
    Rating? rating,
  }) async {
    w.markCalls++;
    final entry = w.shows.firstWhere((s) => s.series.tmdbId == tmdbId);
    final next = entry.next.episode;
    if (next == null ||
        next.seasonNumber != season ||
        next.episodeNumber != episode) {
      throw const ApiError(
        status: 409,
        code: 'NOT_NEXT_EPISODE',
        message: 'Not the next episode.',
      );
    }
    final updated = w.addShow(
      tmdbId,
      progress: (season, episode),
      version: entry.progressVersion + 1,
    );
    w.episodeViews.insert(
      0,
      EpisodeViewingRecord(
        id: 'v${w.markCalls}',
        series: entry.series,
        seasonNumber: season,
        episodeNumber: episode,
        episodeName: next.name,
        recordedAt: DateTime.utc(2026, 10, 8),
      ),
    );
    return EpisodeWatchedResult(
      entry: updated,
      viewingId: 'v1',
      alreadyRecorded: false,
    );
  }
}

class FakeWatchlist implements WatchlistRepository {
  FakeWatchlist(this.w);
  final World w;

  @override
  Future<Paged<WatchlistEntry>> list({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
  }) async => Paged(List.of(w.movies), null);

  @override
  Future<Paged<WatchlistItem>> items({
    String? cursor,
    WatchlistSort sort = WatchlistSort.addedDesc,
    WatchlistMedia media = WatchlistMedia.all,
  }) async => Paged([
    if (media != WatchlistMedia.shows)
      for (final m in w.movies) MovieItem(m),
    if (media != WatchlistMedia.movies)
      for (final s in w.shows) ShowItem(s),
  ], null);

  @override
  Future<WatchlistAddResult> add(int tmdbId) async =>
      throw UnimplementedError();

  @override
  Future<void> remove(String entryId) async {
    w.movies.removeWhere((m) => m.id == entryId);
    w.shows.removeWhere((s) => s.id == entryId);
  }
}

class FakeHistory implements HistoryRepository {
  FakeHistory(this.w);
  final World w;

  @override
  Future<Paged<Viewing>> viewings({String? cursor}) async =>
      const Paged([], null);

  @override
  Future<Paged<RecommendationRecord>> recommendations({String? cursor}) async =>
      Paged(List.of(w.records), null);

  @override
  Future<RecordWatchedResult> recordAlreadyWatched(int tmdbId) =>
      throw UnimplementedError();

  @override
  Future<RecordWatchedResult> recordManual(int tmdbId) =>
      throw UnimplementedError();

  @override
  Future<Viewing> rateViewing(
    String viewingId,
    Rating? rating, {
    int expectedVersion = 1,
  }) => throw UnimplementedError();
}

class FakeSearch implements MovieSearchRepository {
  @override
  Future<SearchPage> search(String query, {int page = 1}) async =>
      const SearchPage(page: 1, totalPages: 0, results: []);

  @override
  Future<DiscoveryPage> discover(DiscoveryList list) async =>
      const DiscoveryPage(results: [], inWatchlist: {});
}

class FakeAccount implements AccountRepository {
  FakeAccount(this.auth, this.w);
  final FakeAuth auth;
  final World w;

  @override
  Future<void> bootstrap() async {}

  @override
  Future<Profile> me() async => Profile(
    displayName: null,
    timezone: 'UTC',
    preferredGenres: const [],
    blockedGenres: const [],
    defaultMaxRuntimeMinutes: null,
    aiContextEnabled: false,
    blockedMovies: null,
    tonightMedia: w.tonightMedia,
  );

  @override
  Future<void> setTonightMedia(TonightMedia media) async {
    w.tonightMediaCalls.add(media);
    w.tonightMedia = media;
  }

  @override
  Future<void> completeOnboarding() async {}
  @override
  Future<void> setRegion(String? countryCode) async {}
  @override
  Future<List<(String, String)>> regions() async => const [];
  @override
  Future<void> unblock(int tmdbId) async {}
  @override
  Future<void> block(int tmdbId) async {}
}

class FakeToday implements TodayRepository {
  FakeToday(this.w);
  final World w;
  final accepted = <String>[];
  final watched = <String>[];

  @override
  Future<TodayEnvelope> today() async => w.today;

  @override
  Future<TodayEnvelope> accept(String recommendationId) async {
    accepted.add(recommendationId);
    final r = w.today.recommendation!;
    return w.today = TodayEnvelope(
      state: TodayStatus.accepted,
      context: w.today.context,
      recommendation: r.withStatus(RecommendationStatus.accepted),
      media: w.today.media,
    );
  }

  @override
  Future<TodayEnvelope> markWatched(
    String recommendationId, {
    Rating? rating,
  }) async {
    watched.add(recommendationId);
    return w.today;
  }

  @override
  Future<TodayEnvelope> choose(
    SessionContext context, {
    bool continueAfterPause = false,
  }) async => w.today;

  @override
  Future<TodayEnvelope> saveContext(SessionContext context) async => w.today;

  @override
  Future<RejectResult> reject(
    String recommendationId,
    RejectReason reason, {
    int? maxRuntimeMinutes,
    Set<int> avoidGenreIds = const {},
    required bool chooseAnother,
  }) async =>
      RejectResult(outcome: ReplacementOutcome.notRequested, today: w.today);

  @override
  Future<TodayEnvelope> followUp(
    String recommendationId,
    String action,
  ) async => w.today;

  @override
  Future<WhyBreakdown?> why(String recommendationId) async => null;
}

class Rig {
  Rig({World? world, bool signedIn = true})
    : w = world ?? World(),
      auth = FakeAuth(signedIn ? alice : null) {
    account = FakeAccount(auth, w);
    series = FakeSeries(w);
    todayRepo = FakeToday(w);
  }

  final World w;
  final FakeAuth auth;
  late final FakeAccount account;
  late final FakeSeries series;
  late final FakeToday todayRepo;

  Widget app() => ProviderScope(
    retry: noAutomaticRetry,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(auth),
      accountRepositoryProvider.overrideWithValue(account),
      profileRepositoryProvider.overrideWithValue(
        AccountProfileRepository(account),
      ),
      watchlistRepositoryProvider.overrideWithValue(FakeWatchlist(w)),
      searchRepositoryProvider.overrideWithValue(FakeSearch()),
      historyRepositoryProvider.overrideWithValue(FakeHistory(w)),
      seriesRepositoryProvider.overrideWithValue(series),
      todayRepositoryProvider.overrideWithValue(todayRepo),
    ],
    child: const CinemeApp(),
  );
}

Future<void> boot(WidgetTester tester, Rig rig) async {
  SharedPreferences.setMockInitialValues({});
  tester.view
    ..physicalSize = const Size(400, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(rig.app());
  await tester.pumpAndSettle();
}

Future<void> openWatchlist(WidgetTester tester) async {
  await tester.tap(navTab('Watchlist'));
  await tester.pumpAndSettle();
}

/// Opens the dropdown field with [label] and picks [option].
Future<void> choose(WidgetTester tester, String label, String option) async {
  await tester.tap(
    find.byWidgetPredicate((w) => w is SelectorField && w.label == label),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(ListTile), matching: find.text(option)),
  );
  await tester.pumpAndSettle();
}

Rig stocked() {
  final rig = Rig();
  rig.w
    ..addMovie(1, 'Film A')
    ..addMovie(2, 'Film B')
    ..addShow(1399, progress: (1, 4))
    ..addShow(1400);
  return rig;
}

Episode ep(int s, int e, {String? name = 'The Wedding'}) => Episode(
  seasonNumber: s,
  episodeNumber: e,
  name: name,
  airDate: aired,
  runtimeMinutes: 45,
);

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

void main() {
  group('Watchlist media filter', () {
    testWidgets('defaults to All and filters films and shows server-side', (
      tester,
    ) async {
      final rig = stocked();
      await boot(tester, rig);
      await openWatchlist(tester);
      expect(find.text('All'), findsOneWidget);
      for (final t in ['Film A', 'Film B', 'Alpha', 'Beta']) {
        expect(find.text(t), findsOneWidget);
      }

      await choose(tester, 'Show', 'Shows only');
      expect(find.text('Film A'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Shows only'), findsOneWidget);

      await choose(tester, 'Show', 'Movies only');
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Film A'), findsOneWidget);
    });

    testWidgets('the filter survives opening a show and coming back', (
      tester,
    ) async {
      final rig = stocked();
      await boot(tester, rig);
      await openWatchlist(tester);
      await choose(tester, 'Show', 'Shows only');
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Show details'), findsOneWidget);
      expect(find.text('Last watched: Season 1, Episode 4'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Shows only'), findsOneWidget);
      expect(find.text('Film A'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('filtering never deletes anything', (tester) async {
      final rig = stocked();
      await boot(tester, rig);
      await openWatchlist(tester);
      await choose(tester, 'Show', 'Shows only');
      await choose(tester, 'Show', 'Movies only');
      await choose(tester, 'Show', 'All');
      expect(rig.w.movies.length, 2);
      expect(rig.w.shows.length, 2);
      expect(rig.w.shows.first.progress, isNull);
      expect(find.text('Film A'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('an empty category says so and offers the matching add', (
      tester,
    ) async {
      final rig = Rig();
      rig.w.addMovie(1, 'Film A');
      await boot(tester, rig);
      await openWatchlist(tester);
      await choose(tester, 'Show', 'Shows only');
      expect(find.text('No shows in your watchlist yet'), findsOneWidget);
      await tester.tap(find.text('Add shows'));
      await tester.pumpAndSettle();
      expect(
        find.text('Search by title for a show or anime series.'),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();

      rig.w.movies.clear();
      rig.w.addShow(1399);
      await choose(tester, 'Show', 'Movies only');
      expect(find.text('No movies in your watchlist'), findsOneWidget);
      expect(find.text('Add movies'), findsWidgets);
    });

    testWidgets('an older backend (no preference field) hides all of it', (
      tester,
    ) async {
      final rig = Rig();
      rig.w
        ..tonightMedia = null
        ..addMovie(1, 'Film A');
      await boot(tester, rig);
      await openWatchlist(tester);
      expect(find.byType(SelectorField), findsNothing);
      expect(find.textContaining('Films you might watch'), findsOneWidget);
      expect(find.text('Film A'), findsOneWidget);
    });
  });

  group('Add screen', () {
    Future<void> openAdd(WidgetTester tester) async {
      await openWatchlist(tester);
      await tester.tap(find.byTooltip('Add movies or shows'));
      await tester.pumpAndSettle();
    }

    testWidgets('Movies | Shows keeps media explicit; shows are added once', (
      tester,
    ) async {
      final rig = Rig();
      await boot(tester, rig);
      await openAdd(tester);
      expect(find.byKey(const ValueKey('media-toggle')), findsOneWidget);

      await tester.tap(find.text('Shows'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'alp');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Show  ·  2015'), findsOneWidget);

      final add = find.widgetWithText(OutlinedButton, 'Add');
      await tester.tap(add);
      await tester.tap(add); // same frame: ignored
      await tester.pumpAndSettle();
      expect(rig.w.addShowCalls, 1);
      expect(find.text('In watchlist'), findsOneWidget);
      expect(rig.w.shows.single.series.name, 'Alpha');
      expect(rig.w.movies, isEmpty, reason: 'a show never lands in films');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget, reason: 'the list reloaded');
    });

    testWidgets('the Movies side keeps its discovery and search', (
      tester,
    ) async {
      final rig = Rig();
      await boot(tester, rig);
      await openAdd(tester);
      expect(find.text('Browse'), findsOneWidget);
      expect(find.text('Trending this week'), findsWidgets);
    });

    testWidgets('no toggle on an older backend', (tester) async {
      final rig = Rig();
      rig.w.tonightMedia = null;
      await boot(tester, rig);
      await openWatchlist(tester);
      await tester.tap(find.byTooltip('Add movies'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-toggle')), findsNothing);
    });
  });

  group('Show details', () {
    Future<void> open(WidgetTester tester, Rig rig, String name) async {
      await boot(tester, rig);
      await openWatchlist(tester);
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    testWidgets('shows progress, the next episode and the limitation', (
      tester,
    ) async {
      final rig = stocked();
      await open(tester, rig, 'Alpha');
      expect(find.text('Last watched: Season 1, Episode 4'), findsOneWidget);
      expect(find.text('Up next: S1 E5'), findsOneWidget);
      expect(find.textContaining("Specials aren't included"), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(find.text('Not started'), findsOneWidget);
      expect(find.text('Up next: S1 E1'), findsOneWidget);
    });

    testWidgets('Mark watched confirms, then advances to the next episode', (
      tester,
    ) async {
      final rig = stocked();
      await open(tester, rig, 'Alpha');
      await tester.tap(find.text('Mark S1 E5 watched'));
      await tester.pumpAndSettle();
      expect(find.textContaining('S1 E5 of “Alpha”'), findsOneWidget);
      expect(find.textContaining('completes tonight'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Mark watched'));
      await tester.pumpAndSettle();
      expect(rig.w.markCalls, 1);
      expect(find.text('Last watched: Season 1, Episode 5'), findsOneWidget);
      expect(find.text('Up next: S2 E1'), findsOneWidget);
    });

    testWidgets('Set my progress picks a season and episode', (tester) async {
      final rig = stocked();
      await open(tester, rig, 'Alpha');
      await tester.tap(find.text('Set my progress'));
      await tester.pumpAndSettle();
      expect(find.text('Save progress'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save progress'),
            )
            .onPressed,
        isNotNull,
        reason: 'starts from the saved S1 E4',
      );
      await choose(tester, 'Season', 'Season 2');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Save progress'),
            )
            .onPressed,
        isNull,
        reason: 'an episode must be chosen after changing season',
      );
      await choose(tester, 'Episode', 'Episode 3 · Ep 2.3');
      await tester.tap(find.widgetWithText(FilledButton, 'Save progress'));
      await tester.pumpAndSettle();
      expect(rig.w.progressRequests.single, (2, 3));
      expect(find.text('Last watched: Season 2, Episode 3'), findsOneWidget);
      expect(rig.w.markCalls, 0, reason: 'a correction records no viewing');
    });

    testWidgets('a stale version is explained and the page refreshes', (
      tester,
    ) async {
      final rig = stocked();
      await open(tester, rig, 'Alpha');
      // Another device moved progress.
      rig.w.addShow(1399, progress: (1, 5), version: 7);
      await tester.tap(find.text('Set my progress'));
      await tester.pumpAndSettle();
      await choose(tester, 'Episode', 'Episode 2 · Ep 1.2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save progress'));
      await tester.pumpAndSettle();
      expect(
        find.text('Your progress changed elsewhere. It has been refreshed.'),
        findsOneWidget,
      );
      expect(find.text('Last watched: Season 1, Episode 5'), findsOneWidget);
    });

    testWidgets('removing keeps the progress and says so', (tester) async {
      final rig = stocked();
      await open(tester, rig, 'Alpha');
      await tester.dragUntilVisible(
        find.text('Remove from watchlist'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Remove from watchlist'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your progress is kept'), findsOneWidget);
      expect(rig.w.shows.where((s) => s.series.tmdbId == 1399), isEmpty);
    });
  });

  group('Tonight with an episode', () {
    TodayEnvelope offeredEpisode({
      TonightMedia media = TonightMedia.shows,
      TodayStatus state = TodayStatus.offered,
    }) {
      final card = EpisodeCard(
        series: show(1399, 'Alpha'),
        episode: ep(1, 5),
        continuesSeries: true,
      );
      final rec = Recommendation(
        id: 'r1',
        movie: card.display,
        episode: card,
        status: state == TodayStatus.accepted
            ? RecommendationStatus.accepted
            : RecommendationStatus.offered,
        reasons: const [
          ServerReason("Continue the series you're watching — S1 E5."),
        ],
      );
      return TodayEnvelope(
        state: state,
        context: const SessionContext(
          desiredExperience: DesiredExperience.keepMeHooked,
        ),
        recommendation: rec,
        media: media,
      );
    }

    testWidgets('one episode card: show, S1 E5, no film-only controls', (
      tester,
    ) async {
      final rig = Rig()..w.today = offeredEpisode();
      await boot(tester, rig);
      expect(find.byKey(const ValueKey('tonight-title')), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('S1 E5  ·  The Wedding'), findsOneWidget);
      expect(find.textContaining('45 min'), findsOneWidget);
      expect(find.text('Watch Tonight'), findsOneWidget);
      expect(find.text('Why this episode?'), findsOneWidget);
      expect(find.text('Already seen'), findsNothing);
      expect(find.text('Set my progress'), findsOneWidget);
      expect(find.text('Where to watch'), findsNothing);
    });

    testWidgets('Watch Tonight records intent only', (tester) async {
      final rig = Rig()..w.today = offeredEpisode();
      await boot(tester, rig);
      await tester.tap(find.text('Watch Tonight'));
      await tester.pumpAndSettle();
      expect(rig.todayRepo.accepted, ['r1']);
      expect(rig.todayRepo.watched, isEmpty);
      expect(rig.w.progressCalls, 0);
      expect(find.text("Tonight's plan"), findsOneWidget);
      // Mark watched is a separate, deliberate step with the episode named.
      await tester.tap(find.text('Mark watched'));
      await tester.pumpAndSettle();
      expect(find.textContaining('S1 E5 of “Alpha”'), findsOneWidget);
    });

    testWidgets('Set my progress opens the show, not film history', (
      tester,
    ) async {
      final rig = Rig()..w.today = offeredEpisode();
      rig.w.addShow(1399, progress: (1, 4));
      await boot(tester, rig);
      await tester.tap(find.text('Set my progress'));
      await tester.pumpAndSettle();
      expect(find.text('Show details'), findsOneWidget);
    });

    testWidgets('What to watch is a saved setting, shown on Edit tonight', (
      tester,
    ) async {
      final rig = Rig()..w.today = const TodayEnvelope.notStarted();
      await boot(tester, rig);
      expect(find.text('What to watch'), findsOneWidget);
      expect(find.text('Saved for every night'), findsOneWidget);
      expect(find.text('Movies only'), findsOneWidget, reason: 'the default');

      await choose(tester, 'What to watch', 'Movies & shows');
      expect(rig.w.tonightMediaCalls, [TonightMedia.moviesAndShows]);
      expect(find.text('Movies & shows'), findsOneWidget);
      expect(rig.w.movies, isEmpty);
      expect(rig.w.shows, isEmpty);
    });

    testWidgets('changing it with an accepted plan asks first', (tester) async {
      final rig = Rig()
        ..w.today = offeredEpisode(state: TodayStatus.accepted)
        ..w.tonightMedia = TonightMedia.shows;
      await boot(tester, rig);
      await tester.tap(find.text('Edit tonight'));
      await tester.pumpAndSettle();
      await choose(tester, 'What to watch', 'Movies only');
      expect(find.text("Replace tonight's plan?"), findsOneWidget);
      await tester.tap(find.text('Keep plan'));
      await tester.pumpAndSettle();
      expect(rig.w.tonightMediaCalls, isEmpty);
    });

    testWidgets('Shows only with no shows explains and offers two ways out', (
      tester,
    ) async {
      final rig = Rig()
        ..w.tonightMedia = TonightMedia.shows
        ..w.today = const TodayEnvelope(
          state: TodayStatus.emptyWatchlist,
          media: TonightMedia.shows,
          emptyReason: 'no_shows',
        );
      await boot(tester, rig);
      expect(find.text('No shows in your watchlist yet'), findsOneWidget);
      expect(find.text('Add shows'), findsOneWidget);
      expect(find.text('Change preference'), findsOneWidget);
      expect(find.text('Add movies'), findsNothing, reason: 'no silent movie');

      await tester.tap(find.text('Change preference'));
      await tester.pumpAndSettle();
      expect(find.text('Movies & shows'), findsOneWidget);
    });

    testWidgets('a no-match says what was hidden and never offers a film', (
      tester,
    ) async {
      final rig = Rig()
        ..w.tonightMedia = TonightMedia.shows
        ..w.today = const TodayEnvelope(
          state: TodayStatus.noMatch,
          media: TonightMedia.shows,
          context: SessionContext(
            desiredExperience: DesiredExperience.keepMeHooked,
          ),
          noMatch: NoMatchSummary(
            candidateCount: 2,
            counts: {ExclusionCode.seriesCaughtUp: 2},
            hiddenByPreference: 3,
          ),
        );
      await boot(tester, rig);
      expect(
        find.textContaining('2 shows you are caught up on'),
        findsOneWidget,
      );
      expect(find.textContaining('3 more titles are hidden'), findsOneWidget);
      expect(find.text('Add shows'), findsOneWidget);
      expect(find.text('Change preference'), findsOneWidget);
      expect(find.text('Add movies'), findsNothing);
    });
  });

  group('Profile', () {
    testWidgets('a blocked show can be unblocked in the app', (tester) async {
      final rig = stocked();
      rig.series.blockedIds.add(1400);
      await boot(tester, rig);
      await tester.tap(navTab('Profile'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('Beta'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Beta'), findsOneWidget);
      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();
      expect(rig.series.blockedIds, isEmpty);
      expect(find.text('Blocked shows'), findsOneWidget);
      expect(rig.w.shows.length, 2, reason: 'the watchlist is untouched');
    });
  });

  group('History', () {
    testWidgets('episodes are their own segment, separate from films', (
      tester,
    ) async {
      final rig = stocked();
      rig.w.records.add(
        RecommendationRecord(
          id: 'r1',
          movie: show(1399, 'Alpha').let((s) => film(1399, s.name)),
          status: RecommendationStatus.watched,
          createdAt: DateTime.utc(2026, 10, 7),
          desiredExperience: DesiredExperience.surprise,
          episodeLabel: 'S1 E5  ·  The Wedding',
        ),
      );
      await boot(tester, rig);
      // Mark the next episode through the show page.
      await openWatchlist(tester);
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark S1 E1 watched'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Mark watched'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(navTab('History'));
      await tester.pumpAndSettle();
      expect(find.text('Episodes'), findsOneWidget);
      expect(find.text('Nothing watched yet'), findsOneWidget, reason: 'films');
      await tester.tap(find.text('Episodes'));
      await tester.pumpAndSettle();
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('S1 E1  ·  Ep 1.1'), findsOneWidget);

      await tester.tap(find.text('Recommendations'));
      await tester.pumpAndSettle();
      expect(find.text('S1 E5  ·  The Wedding'), findsOneWidget);
    });

    testWidgets('no Episodes segment on an older backend', (tester) async {
      final rig = Rig()..w.tonightMedia = null;
      await boot(tester, rig);
      await tester.tap(navTab('History'));
      await tester.pumpAndSettle();
      expect(find.text('Episodes'), findsNothing);
    });
  });

  group('Wire format', () {
    Map<String, dynamic> episodeJson() => {
      'kind': 'episode',
      'series': {
        'tmdb_id': 1399,
        'name': 'Alpha',
        'year': 2015,
        'status': 'Returning Series',
        'genre_ids': [18],
        'genres': [
          {'id': 18, 'name': 'Drama'},
        ],
        'poster_url': null,
        'vote_average': 8.1,
        'can_add': true,
      },
      'season_number': 1,
      'episode_number': 5,
      'name': 'The Wedding',
      'air_date': '2020-01-01',
      'runtime_minutes': 45,
      'continues_series': true,
    };

    Map<String, dynamic> envelope(Map<String, dynamic> extra) => {
      'state': 'offered',
      'local_date': '2026-10-08',
      'session': {
        'id': 's',
        'version': 2,
        'timezone': 'UTC',
        'context': {
          'desired_experience': 'surprise',
          'current_mood': null,
          'max_runtime_minutes': null,
          'heaviness_max': null,
          'avoid_genre_ids': <int>[],
        },
        'rejection_count': 0,
      },
      'recommendation': {
        'id': 'r1',
        'status': 'offered',
        'media_kind': 'episode',
        'movie': null,
        'episode': episodeJson(),
        'reasons': [
          {'text': "Continue the series you're watching — S1 E5."},
        ],
        'uncertainties': <Object>[],
      },
      'viewing': null,
      'follow_up': null,
      'media': 'shows',
      'empty_reason': null,
      ...extra,
    };

    test('an episode recommendation parses with the show as its display', () {
      final env = todayEnvelopeFromJson(envelope({}));
      final rec = env.recommendation!;
      expect(rec.isEpisode, isTrue);
      expect(rec.episode!.episode.code, 'S1 E5');
      expect(rec.episode!.continuesSeries, isTrue);
      expect(rec.movie.title, 'Alpha');
      expect(rec.movie.runtimeMinutes, 45, reason: 'the episode runtime');
      expect(env.media, TonightMedia.shows);
    });

    test('a movie-only response (no new fields) still parses', () {
      final json = envelope({})..remove('media');
      json['recommendation'] = {
        'id': 'r2',
        'status': 'offered',
        'movie': {
          'tmdb_id': 104,
          'title': 'Run Lola Run',
          'year': 1998,
          'runtime_minutes': 81,
          'genre_ids': [18],
          'genres': [
            {'id': 18, 'name': 'Drama'},
          ],
          'poster_url': null,
          'can_add': true,
          'released': true,
        },
        'reasons': <Object>[],
        'uncertainties': <Object>[],
      };
      final env = todayEnvelopeFromJson(json);
      expect(env.recommendation!.isEpisode, isFalse);
      expect(env.media, isNull);
    });

    test('an episode follow-up, empty reason and hidden count parse', () {
      final json = envelope({
        'state': 'empty_watchlist',
        'recommendation': null,
        'empty_reason': 'no_shows',
        'follow_up': {
          'recommendation_id': 'r9',
          'accepted_local_date': '2026-10-07',
          'media_kind': 'episode',
          'movie': null,
          'episode': episodeJson(),
        },
      });
      final env = todayEnvelopeFromJson(json);
      expect(env.emptyReason, 'no_shows');
      expect(env.followUp!.episode!.episode.code, 'S1 E5');
      expect(env.followUp!.movie.title, 'Alpha');

      final noMatch = envelope({
        'state': 'no_match',
        'recommendation': {
          'id': 'r3',
          'status': 'no_match',
          'no_match_summary': {
            'candidate_count': 2,
            'primary_exclusion_counts': {'series_caught_up': 2},
            'hidden_by_preference': 4,
          },
        },
      });
      final n = todayEnvelopeFromJson(noMatch).noMatch!;
      expect(n.counts[ExclusionCode.seriesCaughtUp], 2);
      expect(n.hiddenByPreference, 4);
    });

    test('watchlist items name their media type; a missing one is a film', () {
      // Imported lazily to keep the file's imports focused on widgets.
      final show = {
        'media_type': 'series',
        'id': 'e1',
        'series': episodeJson()['series'],
        'added_at': '2026-10-08T00:00:00Z',
        'progress': {'season': 1, 'episode': 4, 'version': 3},
        'progress_version': 3,
        'next': {
          'state': 'up_next',
          'episode': {
            'season_number': 1,
            'episode_number': 5,
            'name': null,
            'air_date': null,
            'runtime_minutes': null,
          },
        },
        'series_rating': null,
      };
      final item = watchlistItemFromJson(show);
      expect(item, isA<ShowItem>());
      final entry = (item as ShowItem).show;
      expect(entry.progress!.label, 'S1 E4');
      expect(entry.next.episode!.runtimeMinutes, isNull);
      expect(item.mediaType, MediaType.series);
    });

    test('every request declares series support', () async {
      final adapter = _Capture();
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
        ..httpClientAdapter = adapter;
      await ApiClient(dio, () async => 't').get('/api/v1/watchlist');
      expect(adapter.last!.headers['X-Cineme-Features'], 'series-v1');
      await ApiClient(
        dio,
        () async => 't',
      ).put('/api/v1/series/1/progress', body: {}, idempotencyKey: 'k');
      expect(adapter.last!.method, 'PUT');
      expect(adapter.last!.headers['X-Cineme-Features'], 'series-v1');
    });
  });
}

class _Capture implements HttpClientAdapter {
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
