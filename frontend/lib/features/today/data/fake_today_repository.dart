import '../../../shared/models/movie.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import 'today_repository.dart';

/// Scripted UI-preview data, selected only by `--dart-define=CINEME_PREVIEW=true`.
///
/// Not a ranking engine: each intent has a fixed, ordered list of watchlist
/// films and the first one inside the hard runtime cap is returned. Current
/// mood is ignored, as it is by the real scorer. Real scoring arrives in P4.
class FakeTodayRepository implements TodayRepository {
  FakeTodayRepository({
    List<Movie> inventory = previewWatchlist,
    this.latency = const Duration(milliseconds: 450),
  }) : _byId = {for (final m in inventory) m.tmdbId: m};

  final Map<int, Movie> _byId;
  final Duration latency;

  @override
  Future<TodayEnvelope> choose(SessionContext context) async {
    await Future<void>.delayed(latency);
    final cap = context.maxRuntimeMinutes;
    for (final (tmdbId, genreId) in _script[context.desiredExperience]!) {
      final movie = _byId[tmdbId];
      final runtime = movie?.runtimeMinutes;
      // Unknown runtime is excluded under a cap, never treated as zero.
      if (movie == null ||
          (cap != null && (runtime == null || runtime > cap))) {
        continue;
      }
      return TodayEnvelope(
        state: TodayStatus.offered,
        context: context,
        recommendation: Recommendation(
          id: 'preview-$tmdbId',
          movie: movie,
          reasons: [
            if (context.desiredExperience == DesiredExperience.surprise)
              const SurpriseChosen()
            else
              GenreMatchesIntent(
                genre: movie.genres.firstWhere((g) => g.id == genreId),
                intent: context.desiredExperience,
              ),
            if (cap != null)
              FitsRuntime(runtimeMinutes: runtime!, capMinutes: cap),
          ],
        ),
      );
    }
    // ponytail: no_match state is out of P1a scope; fixtures always fit 90 min.
    throw StateError('No scripted preview film fits this context.');
  }
}

const _action = Genre(28, 'Action');
const _adventure = Genre(12, 'Adventure');
const _animation = Genre(16, 'Animation');
const _comedy = Genre(35, 'Comedy');
const _crime = Genre(80, 'Crime');
const _drama = Genre(18, 'Drama');
const _family = Genre(10751, 'Family');
const _fantasy = Genre(14, 'Fantasy');
const _mystery = Genre(9648, 'Mystery');
const _romance = Genre(10749, 'Romance');
const _sciFi = Genre(878, 'Science Fiction');
const _thriller = Genre(53, 'Thriller');
const _war = Genre(10752, 'War');

/// Public film facts used as fixture data; ids are fixture keys. No posters
/// are bundled: the UI draws a designed placeholder.
const previewWatchlist = <Movie>[
  Movie(
    tmdbId: 104,
    title: 'Run Lola Run',
    year: 1998,
    runtimeMinutes: 81,
    genres: [_action, _drama, _thriller],
  ),
  Movie(
    tmdbId: 813,
    title: 'Airplane!',
    year: 1980,
    runtimeMinutes: 88,
    genres: [_comedy],
  ),
  Movie(
    tmdbId: 8392,
    title: 'My Neighbor Totoro',
    year: 1988,
    runtimeMinutes: 86,
    genres: [_fantasy, _animation, _family],
  ),
  Movie(
    tmdbId: 12477,
    title: 'Grave of the Fireflies',
    year: 1988,
    runtimeMinutes: 89,
    genres: [_animation, _drama, _war],
  ),
  Movie(
    tmdbId: 14337,
    title: 'Primer',
    year: 2004,
    runtimeMinutes: 77,
    genres: [_sciFi, _drama, _thriller],
  ),
  Movie(
    tmdbId: 346648,
    title: 'Paddington 2',
    year: 2017,
    runtimeMinutes: 104,
    genres: [_adventure, _comedy, _family],
  ),
  Movie(
    tmdbId: 137,
    title: 'Groundhog Day',
    year: 1993,
    runtimeMinutes: 101,
    genres: [_romance, _fantasy, _drama, _comedy],
  ),
  Movie(
    tmdbId: 329865,
    title: 'Arrival',
    year: 2016,
    runtimeMinutes: 116,
    genres: [_drama, _sciFi, _mystery],
  ),
  Movie(
    tmdbId: 546554,
    title: 'Knives Out',
    year: 2019,
    runtimeMinutes: 131,
    genres: [_comedy, _crime, _mystery],
  ),
  Movie(
    tmdbId: 666277,
    title: 'Past Lives',
    year: 2023,
    runtimeMinutes: 106,
    genres: [_drama, _romance],
  ),
  Movie(
    tmdbId: 371645,
    title: 'Hunt for the Wilderpeople',
    year: 2016,
    runtimeMinutes: 101,
    genres: [_adventure, _comedy, _drama],
  ),
];

/// Ordered (tmdbId, matched genre id) per intent. Every list ends with a film
/// of 90 minutes or less so each offered time option has a pick.
const _script = <DesiredExperience, List<(int, int)>>{
  DesiredExperience.makeMeLaugh: [(137, 35), (813, 35)],
  DesiredExperience.keepMeHooked: [(546554, 9648), (104, 53)],
  DesiredExperience.relax: [(8392, 10751)],
  DesiredExperience.deep: [(329865, 18), (14337, 878)],
  DesiredExperience.exciting: [(104, 28)],
  DesiredExperience.comfort: [(346648, 10751), (8392, 10751)],
  DesiredExperience.feelIt: [(666277, 18), (12477, 18)],
  DesiredExperience.surprise: [(371645, 0), (14337, 0)],
};
