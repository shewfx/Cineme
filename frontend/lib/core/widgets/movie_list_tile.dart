import 'package:flutter/material.dart';

import '../../shared/models/movie.dart';
import '../theme/app_theme.dart';
import 'movie_poster.dart';

const _posterHeight = 72.0;

/// Stable inventory/history row: small poster, title, muted detail lines and
/// an optional trailing action. Not a recommendation card.
class MovieListTile extends StatelessWidget {
  const MovieListTile({
    super.key,
    required this.movie,
    required this.lines,
    this.trailing,
    this.footer,
  });

  final Movie movie;
  final List<String> lines;
  final Widget? trailing;

  /// Optional actions under the text (Search's separate Add/Watched).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: _posterHeight,
              child: MoviePoster(movie: movie),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
            SizedBox(
              height: _posterHeight,
              child: Center(child: trailing),
            ),
          ],
        ],
      ),
    );
  }
}

/// "1998 · 81 min" with honest gaps: unknown runtime is never zero.
String yearAndRuntime(Movie m, {String unknownRuntime = 'Runtime unknown'}) => [
  if (m.year != null) '${m.year}',
  m.runtimeMinutes != null ? '${m.runtimeMinutes} min' : unknownRuntime,
].join('  ·  ');
