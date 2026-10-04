import 'movie.dart';
import 'session_context.dart';

/// Whole-star post-watch rating. The wire value is an integer from 1 to 5.
enum Rating {
  one(1),
  two(2),
  three(3),
  four(4),
  five(5);

  const Rating(this.value);

  final int value;

  static Rating? fromValue(Object? value) {
    if (value == null) return null;
    if (value is! int) throw const FormatException('Invalid rating');
    return Rating.values.firstWhere(
      (rating) => rating.value == value,
      orElse: () => throw const FormatException('Invalid rating'),
    );
  }
}

/// ViewingSummary. Null watchedAt means the date is unknown.
class Viewing {
  const Viewing({
    required this.id,
    required this.movie,
    required this.watchedAt,
    required this.recordedAt,
    required this.rating,
    this.version = 1,
  });

  final String id;
  final Movie movie;
  final DateTime? watchedAt;
  final DateTime recordedAt;
  final Rating? rating;
  final int version;
}

class FollowUpPrompt {
  const FollowUpPrompt({
    required this.recommendationId,
    required this.movie,
    required this.acceptedLocalDate,
  });
  final String recommendationId;
  final Movie movie;
  final DateTime acceptedLocalDate;
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
