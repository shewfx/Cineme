import 'package:flutter/material.dart';

import '../../shared/models/movie.dart';
import '../theme/app_theme.dart';
import 'movie_poster.dart';

const _posterWidth = 48.0;

/// Stable inventory/history row: small poster, title, muted detail lines and
/// an optional trailing action. Not a recommendation card.
///
/// [large] is Search's composition: a 2:3 poster that anchors the row, the
/// details centred beside it and the action centred on its right edge.
class MovieListTile extends StatelessWidget {
  const MovieListTile({
    super.key,
    required this.movie,
    required this.lines,
    this.trailing,
    this.footer,
    this.large = false,
  });

  final Movie movie;
  final List<String> lines;
  final Widget? trailing;
  final bool large;

  /// Optional actions under the text (Search's separate Add/Watched).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final posterWidth = large ? 76.0 : _posterWidth;
    final posterHeight = posterWidth * 1.5;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24, vertical: large ? 12 : 10),
      child: Row(
        // Centred on the poster beside a trailing action; top-aligned when
        // the action is stacked under the details (large text).
        crossAxisAlignment: large && trailing != null
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(large ? 10 : 8),
            child: SizedBox(
              width: posterWidth,
              height: posterHeight,
              child: MoviePoster(movie: movie),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: large && trailing != null
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Text(movie.title, style: text.titleMedium),
                for (final line in lines) ...[
                  const SizedBox(height: 2),
                  Text(
                    line,
                    style: text.bodyMedium?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                if (footer != null) ...[const SizedBox(height: 8), footer!],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            // Centred on the poster, whatever the text column's height.
            if (large)
              trailing!
            else
              SizedBox(
                height: posterHeight,
                child: Center(child: trailing),
              ),
          ],
        ],
      ),
    );
  }
}

/// "1998 · 81 min" with honest gaps: unknown runtime is never zero.
/// Pass a null [unknownRuntime] to leave the runtime out entirely.
String yearAndRuntime(Movie m, {String? unknownRuntime = 'Runtime unknown'}) =>
    [
      if (m.year != null) '${m.year}',
      if (m.runtimeMinutes != null)
        '${m.runtimeMinutes} min'
      else
        ?unknownRuntime,
    ].join('  ·  ');
