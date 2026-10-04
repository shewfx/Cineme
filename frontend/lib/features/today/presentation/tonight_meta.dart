import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/models/movie.dart';

/// "7.4" for a known TMDB rating, null for unknown. A missing, non-finite or
/// zero rating is omitted rather than shown as 0.0 or a placeholder.
String? formatTmdbRating(double? voteAverage) {
  if (voteAverage == null || !voteAverage.isFinite) return null;
  final text = voteAverage.toStringAsFixed(1);
  return text == '0.0' ? null : text;
}

/// year · runtime · ★ rating · genres, centred and wrapping as one line of
/// text. The rating is TMDB's community score, not the user's own.
class TonightMeta extends StatelessWidget {
  const TonightMeta({super.key, required this.movie, this.style});

  final Movie movie;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final rating = formatTmdbRating(movie.voteAverage);
    const sep = '  ·  ';
    final parts = <InlineSpan>[
      if (movie.year != null) TextSpan(text: '${movie.year}'),
      TextSpan(
        text: movie.runtimeMinutes != null
            ? '${movie.runtimeMinutes} min'
            : 'Runtime unavailable',
      ),
      if (rating != null)
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: ExcludeSemantics(
                child: Icon(
                  Icons.star_rounded,
                  size: (base.fontSize ?? 14) + 1,
                  color: AppColors.rating,
                ),
              ),
            ),
            TextSpan(text: ' $rating', semanticsLabel: ' TMDB rating $rating'),
          ],
        ),
      if (movie.genres.isNotEmpty)
        TextSpan(text: movie.genres.map((g) => g.name).join(', ')),
    ];
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const TextSpan(text: sep),
            parts[i],
          ],
        ],
      ),
      textAlign: TextAlign.center,
      style: base,
    );
  }
}
