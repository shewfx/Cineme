import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import 'today_widgets.dart';

/// Exactly ONE film: artwork fading into charcoal, then a compact text block.
/// No alternatives, carousel or runners-up are rendered.
class RecommendationView extends StatelessWidget {
  const RecommendationView({super.key, required this.envelope});

  final TodayEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final recommendation = envelope.recommendation;
    final movie = recommendation.movie;
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    // Poster proportions, capped so the title stays above the fold; large
    // text gets a lower cap so the text block, not the art, is what shrinks last.
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final artHeight = math.min(
      size.width * 1.5,
      size.height * (largeText ? 0.45 : 0.68),
    );

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            // Text sits on the action; spare height falls into the charcoal
            // fade. Overflows (small screens, large text) scroll instead.
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: artHeight,
                        width: double.infinity,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            MoviePoster(
                              key: const ValueKey('tonight-poster'),
                              movie: movie,
                            ),
                            // Light scrim for the status bar; long fade into charcoal.
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: [0, 0.16, 0.72, 1],
                                  colors: [
                                    Color(0x66000000),
                                    Color(0x00000000),
                                    Color(0x001C1C1C),
                                    AppColors.background,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              contextLine(envelope.context),
                              style: text.labelMedium?.copyWith(
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Semantics(
                              header: true,
                              child: Text(
                                movie.title,
                                key: const ValueKey('tonight-title'),
                                style: text.headlineMedium,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              [
                                if (movie.year != null) '${movie.year}',
                                movie.runtimeMinutes != null
                                    ? '${movie.runtimeMinutes} min'
                                    : 'Runtime unavailable',
                                if (movie.genres.isNotEmpty)
                                  movie.genres.map((g) => g.name).join(', '),
                              ].join('  ·  '),
                              key: const ValueKey('tonight-meta'),
                              style: text.bodyMedium?.copyWith(
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 18),
                            for (final reason in recommendation.reasons.take(2))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  reasonText(reason),
                                  style: text.bodyLarge?.copyWith(
                                    color: AppColors.textSoft,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryAction(
                label: 'Watch Tonight',
                onPressed: () => ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Preview: Watch Tonight isn't saved in this build. "
                        "It will record your plan for tonight, never that you watched the film.",
                      ),
                    ),
                  ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Keep me hooked · up to 90 min · feeling tired": intent first, mood last
/// and labelled as a feeling, so the two never read as one thing.
String contextLine(SessionContext ctx) => [
  ctx.desiredExperience.label,
  if (ctx.maxRuntimeMinutes != null)
    runtimeCapLabel(ctx.maxRuntimeMinutes).toLowerCase(),
  if (ctx.currentMood != null)
    'feeling ${ctx.currentMood!.label.toLowerCase()}',
].join('  ·  ');

/// Deterministic explanation templates. Facts only: genre and runtime.
String reasonText(Reason reason) => switch (reason) {
  FitsRuntime(:final runtimeMinutes, :final capMinutes) =>
    'At $runtimeMinutes minutes, it fits your $capMinutes-minute limit.',
  GenreMatchesIntent(:final genre, :final intent) =>
    'Its ${genre.name.toLowerCase()} genre fits “${intent.label}”.',
  SurpriseChosen() =>
    "You chose Surprise me, so it wasn't matched to an intent.",
};
