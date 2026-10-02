import 'movie.dart';
import 'session_context.dart';

/// Post-watch rating; labelled text, never colour or stars alone.
enum Rating {
  loved('Loved'),
  liked('Liked'),
  okay('Okay'),
  disliked('Disliked');

  const Rating(this.label);

  final String label;
}

/// ViewingSummary. Null watchedAt means the date is unknown.
class Viewing {
  const Viewing({
    required this.id,
    required this.movie,
    required this.watchedAt,
    required this.recordedAt,
    required this.rating,
  });

  final String id;
  final Movie movie;
  final DateTime? watchedAt;
  final DateTime recordedAt;
  final Rating? rating;
}

class RecordWatchedResult {
  const RecordWatchedResult({
    required this.viewing,
    required this.alreadyRecorded,
  });

  final Viewing viewing;
  final bool alreadyRecorded;
}

enum RecommendationStatus {
  offered('Offered'),
  accepted('Planned for tonight'),
  rejected('Passed'),
  watched('Watched'),
  superseded('Cleared'),
  noMatch('No match');

  const RecommendationStatus(this.label);

  final String label;
}

/// Recommendation history row: what was offered (or no match), when, for
/// which intent, and the rejection reason if any.
class RecommendationRecord {
  const RecommendationRecord({
    required this.id,
    required this.movie,
    required this.status,
    required this.createdAt,
    required this.desiredExperience,
    this.reasonLabel,
  });

  /// Null only for a no-match attempt.
  final Movie? movie;
  final String id;
  final RecommendationStatus status;
  final DateTime createdAt;
  final DesiredExperience desiredExperience;
  final String? reasonLabel;

  RecommendationRecord withStatus(
    RecommendationStatus status, {
    String? reasonLabel,
  }) => RecommendationRecord(
    id: id,
    movie: movie,
    status: status,
    createdAt: createdAt,
    desiredExperience: desiredExperience,
    reasonLabel: reasonLabel ?? this.reasonLabel,
  );
}
