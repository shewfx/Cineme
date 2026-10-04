import 'package:flutter/material.dart';

import '../../shared/models/movie.dart';
import '../config/preview.dart';
import '../theme/app_theme.dart';
import 'tab_swipe_exclusion.dart';

/// Fills its box with the film's artwork, cropped from the top.
///
/// Real builds load the TMDB poster URL from the API; preview builds read a
/// git-ignored local poster `preview_posters/<id>.jpg` (ADR 002). Missing or
/// failing images show a designed placeholder of the same size, so the
/// layout never jumps.
class MoviePoster extends StatelessWidget {
  const MoviePoster({super.key, required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context) {
    final placeholder = _Placeholder(movie: movie);
    return ExcludeTabSwipe(
      child: Semantics(
        image: true,
        label: 'Poster for ${movie.title}',
        child: ExcludeSemantics(
          child: movie.posterUrl != null
              // TMDB image CDN (the documented exception to backend-only TMDB
              // access). Loading or failure shows the same-size placeholder.
              ? Image.network(
                  movie.posterUrl!,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  frameBuilder: (context, child, frame, _) =>
                      frame == null ? placeholder : child,
                  errorBuilder: (_, _, _) => placeholder,
                )
              : isUiPreview
              ? Image.asset(
                  'preview_posters/${movie.tmdbId}.jpg',
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, _, _) => placeholder,
                )
              : placeholder,
        ),
      ),
    );
  }
}

/// Muted tonal field with the title set large in Jost Light; the hue comes
/// from the film id so each placeholder is distinct but never loud.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context) {
    final hue = (movie.tmdbId * 47) % 360.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.22, 0.30).toColor(),
            HSLColor.fromAHSL(1, hue, 0.16, 0.16).toColor(),
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Center(
          // Thumbnails show the initial; large artwork shows the title.
          child: box.maxWidth < 120
              ? Text(
                  movie.title.characters.first.toUpperCase(),
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: box.maxWidth * 0.42,
                    fontWeight: FontWeight.w300,
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    movie.title.toUpperCase(),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textScaler: TextScaler.noScaling,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 26,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 6,
                      height: 1.3,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
