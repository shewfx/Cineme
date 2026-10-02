import '../shared/models/movie.dart';
import '../shared/models/session_context.dart';

// UI-preview fixture data only (`--dart-define=CINEME_PREVIEW=true`).

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

/// Seed watchlist. Public film facts used as fixture data; ids are fixture
/// keys. No posters are bundled: the UI draws a designed placeholder.
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

/// Searchable films that start outside the watchlist. The first two seed
/// History as already watched.
const previewSearchOnly = <Movie>[
  Movie(
    tmdbId: 194,
    title: 'Amélie',
    year: 2001,
    runtimeMinutes: 122,
    genres: [_comedy, _romance],
  ),
  Movie(
    tmdbId: 129,
    title: 'Spirited Away',
    year: 2001,
    runtimeMinutes: 125,
    genres: [_animation, _family, _fantasy],
  ),
  Movie(
    tmdbId: 2493,
    title: 'The Princess Bride',
    year: 1987,
    runtimeMinutes: 98,
    genres: [_adventure, _family, _fantasy, _comedy, _romance],
  ),
  Movie(
    tmdbId: 76,
    title: 'Before Sunrise',
    year: 1995,
    runtimeMinutes: 101,
    genres: [_drama, _romance],
  ),
  Movie(
    tmdbId: 376867,
    title: 'Moonlight',
    year: 2016,
    runtimeMinutes: 111,
    genres: [_drama],
  ),
  Movie(
    tmdbId: 496243,
    title: 'Parasite',
    year: 2019,
    runtimeMinutes: 133,
    genres: [_comedy, _thriller, _drama],
  ),
  Movie(
    tmdbId: 324857,
    title: 'Spider-Man: Into the Spider-Verse',
    year: 2018,
    runtimeMinutes: 117,
    genres: [_animation, _action, _adventure, _sciFi],
  ),
  Movie(
    tmdbId: 391713,
    title: 'Lady Bird',
    year: 2017,
    runtimeMinutes: 94,
    genres: [_drama, _comedy],
  ),
];

/// Fictional, clearly labelled fixture for an unknown release date: it can
/// be saved but is never Tonight-eligible.
const previewUnreleased = Movie(
  tmdbId: 999001,
  title: 'Untitled Future Release (preview fixture)',
  year: null,
  runtimeMinutes: null,
  genres: [],
  released: false,
);

/// Scripted priority per intent (P1a order). After these, the fake offers
/// the remaining eligible films in watchlist order. Not a ranking engine.
const previewScript = <DesiredExperience, List<int>>{
  DesiredExperience.makeMeLaugh: [137, 813],
  DesiredExperience.keepMeHooked: [546554, 104],
  DesiredExperience.relax: [8392],
  DesiredExperience.deep: [329865, 14337],
  DesiredExperience.exciting: [104],
  DesiredExperience.comfort: [346648, 8392],
  DesiredExperience.feelIt: [666277, 12477],
  DesiredExperience.surprise: [371645, 14337],
};

/// Approximate intent-compatible genres (RECOMMENDATION_ENGINE table), used
/// only to word reasons honestly. Surprise has no intent dimension.
const previewIntentGenres = <DesiredExperience, Set<int>>{
  DesiredExperience.makeMeLaugh: {35},
  DesiredExperience.comfort: {10751, 16, 35},
  DesiredExperience.feelIt: {18, 10749},
  DesiredExperience.relax: {35, 10751, 12},
  DesiredExperience.deep: {18, 878, 9648},
  DesiredExperience.exciting: {28, 12, 53},
  DesiredExperience.keepMeHooked: {53, 9648, 80},
  DesiredExperience.surprise: {},
};
