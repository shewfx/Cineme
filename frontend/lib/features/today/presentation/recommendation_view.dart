import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../history/data/history_repository.dart';
import '../application/today_controller.dart';
import 'availability_section.dart';
import 'feedback_sheets.dart';
import 'tonight_hero.dart';
import 'today_widgets.dart';
import 'why_sheet.dart';

/// Exactly ONE film, offered, accepted (Watch Tonight) or completed (Mark
/// watched): a hero of blurred artwork with the sharp poster card in front,
/// then the details. No alternatives, carousel or runners-up are rendered.
class RecommendationView extends ConsumerWidget {
  const RecommendationView({super.key, required this.envelope});

  final TodayEnvelope envelope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recommendation = envelope.recommendation!;
    final movie = recommendation.movie;
    final tonight = envelope.context!;
    final state = envelope.state;
    final viewing = envelope.viewing;
    final busy = ref.watch(todayControllerProvider.select((s) => s.busy));
    final controller = ref.read(todayControllerProvider.notifier);
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    // The card's direct Already seen, Never recommend and Mark watched need
    // P5 (history UI, blocks, completion); the normal build hides them.
    // "Already watched" inside Not feeling it works everywhere (ADR 006).
    final historyAvailable = ref.watch(historyRepositoryProvider) != null;

    /// Failures keep the current card and say so; nothing is optimistic.
    Future<void> guard(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(todayFailureMessage(e))));
        }
      }
    }

    Future<void> pickAnother() async {
      final request = await showRejectSheet(
        context,
        movie: movie,
        tonight: tonight,
        rejectionCount: envelope.rejectionCount,
      );
      if (request == null) return;
      await guard(
        () => controller.reject(
          recommendation,
          request.reason,
          maxRuntimeMinutes: request.maxRuntimeMinutes,
          avoidGenreIds: request.avoidGenreIds,
          chooseAnother: request.chooseAnother,
        ),
      );
    }

    Future<void> alreadySeen() async {
      final ok = await _confirm(
        context,
        title: 'Seen “${movie.title}” before?',
        body:
            "We'll record it as watched earlier, date unknown, and show one "
            "other film. It won't count as tonight's movie.",
        confirm: 'Record and show another',
      );
      if (ok) {
        await guard(
          () => controller.reject(
            recommendation,
            RejectReason.alreadyWatched,
            chooseAnother: true,
          ),
        );
      }
    }

    Future<void> neverRecommend() async {
      final ok = await _confirm(
        context,
        title: 'Never recommend “${movie.title}”?',
        body:
            "It leaves your watchlist and Cinemé won't pick it again. "
            "This isn't a rating. You can undo it in Profile.",
        confirm: 'Never recommend',
      );
      if (ok) {
        await guard(
          () => controller.reject(
            recommendation,
            RejectReason.neverRecommend,
            chooseAnother: false,
          ),
        );
      }
    }

    Future<void> markWatched() async {
      final result = await showMarkWatchedSheet(context, movie);
      if (result == null || !result.$1) return;
      await guard(
        () => controller.markWatched(recommendation, rating: result.$2),
      );
    }

    final statusLabel = switch (state) {
      TodayStatus.accepted => "Tonight's plan",
      TodayStatus.completed => 'Watched tonight',
      _ => null,
    };

    Widget secondary(
      String label,
      VoidCallback onPressed,
      TodayAction action,
    ) => OutlinedButton(
      onPressed: busy == null ? onPressed : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.border),
        minimumSize: const Size.fromHeight(50),
        textStyle: const TextStyle(
          fontFamily: 'Jost',
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      child: busy == action
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Text(label, textAlign: TextAlign.center),
    );

    // Side by side normally; stacked on narrow screens and at large text.
    final stackActions =
        MediaQuery.textScalerOf(context).scale(1) > 1.15 || width < 340;
    final watchTonight = PrimaryAction(
      compact: true,
      label: 'Watch Tonight',
      loading: busy == TodayAction.accept,
      onPressed: busy == null
          ? () => guard(() => controller.accept(recommendation))
          : null,
    );

    final actions = switch (state) {
      TodayStatus.offered => <Widget>[
        if (historyAvailable) ...[
          Row(
            children: [
              Expanded(
                child: secondary(
                  'Already seen',
                  alreadySeen,
                  TodayAction.reject,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: secondary(
                  'Not feeling it',
                  pickAnother,
                  TodayAction.reject,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          watchTonight,
        ] else if (stackActions) ...[
          watchTonight,
          const SizedBox(height: 10),
          secondary('Not feeling it', pickAnother, TodayAction.reject),
        ] else
          // One compact bar keeps the hero tall: Not feeling it | Watch Tonight.
          Row(
            children: [
              Expanded(
                flex: 5,
                child: secondary(
                  'Not feeling it',
                  pickAnother,
                  TodayAction.reject,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(flex: 6, child: watchTonight),
            ],
          ),
      ],
      TodayStatus.accepted => <Widget>[
        SizedBox(
          width: double.infinity,
          child: secondary('Change my mind', pickAnother, TodayAction.reject),
        ),
        if (historyAvailable) ...[
          const SizedBox(height: 10),
          PrimaryAction(
            label: 'Mark watched',
            loading: busy == TodayAction.watched,
            onPressed: busy == null ? markWatched : null,
          ),
        ],
      ],
      _ => <Widget>[
        SizedBox(
          width: double.infinity,
          child: secondary(
            'See history',
            () => context.go('/history'),
            TodayAction.rate,
          ),
        ),
      ],
    };

    final moreActions = state == TodayStatus.offered && historyAvailable
        ? IconButton(
            tooltip: 'More actions',
            icon: const Icon(Icons.more_horiz),
            onPressed: busy == null
                ? () => _moreActions(context, neverRecommend)
                : null,
          )
        : null;

    final centred = text.bodyMedium?.copyWith(color: AppColors.textMuted);
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            // Hero (about 60% of the screen) then the details. The whole page
            // scrolls if the details do not fit; the actions stay pinned.
            child: LayoutBuilder(
              builder: (context, box) {
                final screenHeight = MediaQuery.sizeOf(context).height;
                final heroHeight = math.max(
                  220.0,
                  math.min(
                    screenHeight * (largeText ? 0.4 : 0.6),
                    box.maxHeight - (largeText ? 110 : 130),
                  ),
                );
                return SingleChildScrollView(
                  child: Column(
                    children: [
                      TonightHero(
                        movie: movie,
                        height: heroHeight,
                        trailing: moreActions,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                        child: Column(
                          children: [
                            if (statusLabel != null) ...[
                              Text(
                                statusLabel,
                                style: text.labelMedium?.copyWith(
                                  color: AppColors.accent,
                                ),
                              ),
                              const SizedBox(height: 4),
                            ],
                            Semantics(
                              header: true,
                              child: Text(
                                movie.title,
                                key: const ValueKey('tonight-title'),
                                textAlign: TextAlign.center,
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
                              textAlign: TextAlign.center,
                              style: centred,
                            ),
                            const SizedBox(height: 14),
                            if (state != TodayStatus.completed)
                              AvailabilitySection(
                                tmdbId: movie.tmdbId,
                                centered: true,
                              ),
                            // The context line and the two secondary links.
                            Wrap(
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 4,
                              children: [
                                Text(
                                  contextLine(tonight),
                                  style: text.labelMedium?.copyWith(
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                if (state != TodayStatus.completed)
                                  TextButton(
                                    onPressed: busy == null
                                        ? () => context.push('/today/context')
                                        : null,
                                    child: const Text('Edit tonight'),
                                  ),
                                // Winner-only explanation; no other films.
                                if (state != TodayStatus.completed)
                                  TextButton(
                                    onPressed: () =>
                                        showWhySheet(context, recommendation),
                                    child: const Text('Why this film?'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (state == TodayStatus.completed &&
                                viewing != null) ...[
                              Text('How was it?', style: text.titleMedium),
                              const SizedBox(height: 10),
                              RatingSelector(
                                value: viewing.rating,
                                onChanged: busy == null
                                    ? (r) => guard(
                                        () => controller.rate(viewing, r),
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Ratings shape future picks. You can change yours any time.',
                                textAlign: TextAlign.center,
                                style: text.labelMedium?.copyWith(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ] else ...[
                              // Up to two reasons plus one uncertainty; the
                              // rest lives behind "Why this film?".
                              for (final reason in [
                                ...recommendation.reasons
                                    .where((r) => !isUncertain(r))
                                    .take(2),
                                ...recommendation.reasons
                                    .where(isUncertain)
                                    .take(1),
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    reasonText(reason),
                                    textAlign: TextAlign.center,
                                    style: text.bodyLarge?.copyWith(
                                      color: isUncertain(reason)
                                          ? AppColors.textMuted
                                          : AppColors.textSoft,
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          // The navigation bar below already clears the home indicator.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;

/// "More actions": the permanent block lives here, apart from everyday skips.
Future<void> _moreActions(BuildContext context, VoidCallback neverRecommend) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 8,
          ),
          leading: const Icon(Icons.block, color: AppColors.textMuted),
          title: const Text('Never recommend this film'),
          subtitle: const Text(
            'A lasting, reversible block. Not a rating.',
            style: TextStyle(color: AppColors.textMuted),
          ),
          onTap: () {
            Navigator.pop(sheet);
            neverRecommend();
          },
        ),
      ),
    );

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
bool isUncertain(Reason r) => r is ServerReason && r.uncertain;

String reasonText(Reason reason) => switch (reason) {
  ServerReason(:final text) => text,
  FitsRuntime(:final runtimeMinutes, :final capMinutes) =>
    'At $runtimeMinutes minutes, it fits your $capMinutes-minute limit.',
  GenreMatchesIntent(:final genre, :final intent) =>
    'Its ${genre.name.toLowerCase()} genre fits “${intent.label}”.',
  SurpriseChosen() =>
    "You chose Surprise me, so it wasn't matched to an intent.",
  WeakIntentMatch(:final intent) =>
    "Its genres don't clearly match “${intent.label}”.",
};
