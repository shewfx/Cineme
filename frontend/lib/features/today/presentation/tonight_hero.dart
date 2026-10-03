import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/config/preview.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../shared/models/movie.dart';
import 'poster_tilt.dart';

/// The Tonight hero: the film's artwork blurred and dimmed into an
/// atmosphere, with the full poster as a sharp card in front, fading into the
/// charcoal page below. Presentation only; it shows the same one film.
class TonightHero extends StatelessWidget {
  const TonightHero({
    super.key,
    required this.movie,
    required this.height,
    this.trailing,
  });

  final Movie movie;
  final double height;

  /// Top-right control (More actions), kept inside the safe area.
  final Widget? trailing;

  /// Room kept under the card so it overlaps the fade, not the details.
  static const _bottomGap = 28.0;
  static const _topGap = 16.0;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final width = MediaQuery.sizeOf(context).width;
    final cardMaxHeight = height - topInset - _topGap - _bottomGap;
    final cardWidth = math.max(
      96.0,
      math.min(width * 0.6, cardMaxHeight * 2 / 3),
    );
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Atmosphere: the same artwork, enlarged, blurred and dimmed. It
          // carries no information of its own.
          ExcludeSemantics(
            child: ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 28,
                  sigmaY: 28,
                  tileMode: TileMode.clamp,
                ),
                child: Transform.scale(
                  scale: 1.3,
                  child: _PosterBackdrop(movie: movie),
                ),
              ),
            ),
          ),
          const DecoratedBox(
            key: ValueKey('tonight-hero-dim'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.35, 0.78, 1],
                colors: [
                  Color(0xB3141414),
                  Color(0x99141414),
                  Color(0xCC1C1C1C),
                  AppColors.background,
                ],
              ),
            ),
          ),
          // A solid last pixel row: the fade ends exactly in the page colour,
          // so no seam shows where the hero meets the details.
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 2,
            child: ColoredBox(color: AppColors.background),
          ),
          // The poster, sharp and uncropped (2:3), a little below centre.
          Positioned(
            left: 0,
            right: 0,
            bottom: _bottomGap,
            child: Center(
              child: PosterTilt(
                key: const ValueKey('tonight-poster-tilt'),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 32,
                        offset: Offset(0, 16),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      key: const ValueKey('tonight-poster-card'),
                      width: cardWidth,
                      height: cardWidth * 1.5,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MoviePoster(
                            key: const ValueKey('tonight-poster'),
                            movie: movie,
                          ),
                          // A hairline keeps dark artwork from melting away.
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppColors.border),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (trailing != null)
            SafeArea(
              child: Align(alignment: Alignment.topRight, child: trailing),
            ),
        ],
      ),
    );
  }
}

/// The artwork as mood only: the same image (or the placeholder's tone) with
/// no semantics. A separate widget from [MoviePoster] so the screen still has
/// exactly one poster card for the one film.
class _PosterBackdrop extends StatelessWidget {
  const _PosterBackdrop({required this.movie});

  final Movie movie;

  @override
  Widget build(BuildContext context) {
    final hue = (movie.tmdbId * 47) % 360.0;
    final tone = DecoratedBox(
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
    );
    final url = movie.posterUrl;
    if (url != null) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        frameBuilder: (context, child, frame, _) =>
            frame == null ? tone : child,
        errorBuilder: (_, _, _) => tone,
      );
    }
    if (isUiPreview) {
      return Image.asset(
        'preview_posters/${movie.tmdbId}.jpg',
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (_, _, _) => tone,
      );
    }
    return tone;
  }
}
