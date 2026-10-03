import 'package:cineme/core/network/movie_dto.dart';
import 'package:cineme/core/theme/app_theme.dart';
import 'package:cineme/features/today/presentation/tonight_meta.dart';
import 'package:cineme/shared/models/movie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Movie film({double? rating, int? runtime = 119}) => Movie(
  tmdbId: 1,
  title: 'Film',
  year: 2025,
  runtimeMinutes: runtime,
  genres: const [Genre(878, 'Science Fiction'), Genre(53, 'Thriller')],
  voteAverage: rating,
);

Widget host(Movie m, {double width = 390}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: TonightMeta(movie: m),
      ),
    ),
  ),
);

Finder get star => find.byIcon(Icons.star_rounded);

String plainMeta(WidgetTester tester) => tester
    .widget<RichText>(
      find
          .descendant(
            of: find.byType(TonightMeta),
            matching: find.byType(RichText),
          )
          .first,
    )
    .text
    .toPlainText(includePlaceholders: false, includeSemanticsLabels: false);

void main() {
  group('formatTmdbRating', () {
    test('always one decimal', () {
      expect(formatTmdbRating(7.4), '7.4');
      expect(formatTmdbRating(8), '8.0');
      expect(formatTmdbRating(7.449), '7.4');
      expect(formatTmdbRating(6.96), '7.0');
      expect(formatTmdbRating(10), '10.0');
    });

    test('unknown, zero and invalid ratings are omitted', () {
      expect(formatTmdbRating(null), isNull);
      expect(formatTmdbRating(0), isNull);
      expect(formatTmdbRating(0.04), isNull);
      expect(formatTmdbRating(double.nan), isNull);
    });
  });

  group('API model', () {
    Map<String, dynamic> json({Object? vote}) => {
      'tmdb_id': 1,
      'title': 'Film',
      'year': 2025,
      'runtime_minutes': 119,
      'genres': <Object?>[],
      'poster_url': null,
      'can_add': true,
      'released': true,
      'vote_average': ?vote,
    };

    test('reads the TMDB value, integers included', () {
      expect(movieSummaryFromJson(json(vote: 7.4)).$1.voteAverage, 7.4);
      expect(movieSummaryFromJson(json(vote: 8)).$1.voteAverage, 8.0);
    });

    test('absent or null stays unknown', () {
      expect(movieSummaryFromJson(json()).$1.voteAverage, isNull);
      expect(movieSummaryFromJson(json(vote: null)).$1.voteAverage, isNull);
    });
  });

  group('TonightMeta', () {
    testWidgets('year, runtime, gold star + rating, then genres', (
      tester,
    ) async {
      await tester.pumpWidget(host(film(rating: 7.4)));
      expect(star, findsOneWidget);
      expect(tester.widget<Icon>(star).color, AppColors.rating);
      final plain = plainMeta(tester);
      expect(plain, startsWith('2025  ·  119 min  ·   7.4  ·  Science'));
      expect(plain, endsWith('Science Fiction, Thriller'));
    });

    testWidgets('formats to one decimal', (tester) async {
      await tester.pumpWidget(host(film(rating: 8)));
      expect(plainMeta(tester), contains(' 8.0'));
    });

    testWidgets('unknown rating leaves no star, 0.0 or placeholder', (
      tester,
    ) async {
      for (final r in [null, 0.0]) {
        await tester.pumpWidget(host(film(rating: r)));
        expect(star, findsNothing);
        final plain = plainMeta(tester);
        expect(plain, '2025  ·  119 min  ·  Science Fiction, Thriller');
        expect(plain, isNot(contains('0.0')));
        expect(plain, isNot(contains('N/A')));
      }
    });

    testWidgets('rating is announced as the TMDB rating', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(film(rating: 7.4)));
      expect(find.bySemanticsLabel(RegExp('TMDB rating 7.4')), findsOneWidget);
      handle.dispose();
    });

    for (final (name, width, scale) in [
      ('narrow screen', 280.0, 1.0),
      ('200% text', 320.0, 2.0),
    ]) {
      testWidgets('$name: wraps without overflow', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(host(film(rating: 7.4), width: width));
        expect(tester.takeException(), isNull);
        expect(star, findsOneWidget);
        final box = tester.getRect(find.byType(TonightMeta));
        expect(box.width, lessThanOrEqualTo(width));
        final s = tester.getRect(star);
        expect(s.left, greaterThanOrEqualTo(box.left));
        expect(s.right, lessThanOrEqualTo(box.right));
      });
    }
  });
}
