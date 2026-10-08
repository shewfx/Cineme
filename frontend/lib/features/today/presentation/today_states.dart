import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/today_state.dart';
import '../../series/application/series_support.dart';
import '../application/today_controller.dart';
import 'media_preference.dart';
import 'recommendation_view.dart';
import 'today_widgets.dart';

/// Third rejection: no automatic fourth film. Adjust context, deliberately
/// continue once, or stop. No re-roll loop.
class PausedView extends ConsumerStatefulWidget {
  const PausedView({super.key, required this.envelope});

  final TodayEnvelope envelope;

  @override
  ConsumerState<PausedView> createState() => _PausedViewState();
}

class _PausedViewState extends ConsumerState<PausedView> {
  bool _stopped = false;

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(todayControllerProvider.select((s) => s.busy));
    final text = Theme.of(context).textTheme;
    final saved = widget.envelope.context!;

    Future<void> continueOnce() async {
      try {
        await ref.read(todayControllerProvider.notifier).continueOnce(saved);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text(connectionErrorMessage)));
        }
      }
    }

    return _StateScaffold(
      title: _stopped
          ? 'Done for tonight'
          : "That's ${widget.envelope.rejectionCount} passes tonight",
      body: _stopped
          ? 'Enjoy your evening. Your watchlist will be here tomorrow.'
          : 'Rather than keep picking, tell Cinemé what you want from tonight. '
                'Or pick once more with the same choices.',
      contextLine: contextLine(saved),
      actions: [
        PrimaryAction(
          label: "Adjust tonight's context",
          onPressed: busy == null ? () => context.push('/today/context') : null,
        ),
        if (!_stopped) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: busy == null ? continueOnce : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.border),
                minimumSize: const Size.fromHeight(50),
              ),
              child: busy == TodayAction.pick
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Text('Continue once'),
            ),
          ),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _stopped = true),
              child: const Text('Stop for tonight'),
            ),
          ),
        ],
      ],
      textStyle: text,
    );
  }
}

/// Honest no-match: aggregate reasons, never another catalogue, never an
/// error, and no limit relaxed behind the user's back.
class NoMatchView extends ConsumerWidget {
  const NoMatchView({super.key, required this.envelope});

  final TodayEnvelope envelope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = envelope.noMatch!;
    final text = Theme.of(context).textTheme;
    final seriesOn = ref.watch(seriesEnabledProvider);
    final outlined = OutlinedButton.styleFrom(
      foregroundColor: AppColors.text,
      side: const BorderSide(color: AppColors.border),
      minimumSize: const Size.fromHeight(50),
    );
    final n = summary.candidateCount;
    final media = envelope.media ?? TonightMedia.movies;
    final noun = media == TonightMedia.movies
        ? (n == 1 ? 'film' : 'films')
        : (n == 1 ? 'title' : 'titles');
    final lines = [
      for (final code in ExclusionCode.values)
        if ((summary.counts[code] ?? 0) > 0)
          '${summary.counts[code]} ${code.label}',
    ];
    return _StateScaffold(
      title: 'Nothing in your watchlist fits tonight',
      body:
          'Of the $n $noun in your watchlist: ${lines.join(', ')}. '
          'Cinemé only picks from your watchlist and keeps your limits as set.'
          '${summary.hiddenByPreference > 0 ? ' ${summary.hiddenByPreference} more ${summary.hiddenByPreference == 1 ? 'title is' : 'titles are'} hidden by “${media.label}”.' : ''}',
      contextLine: contextLine(envelope.context!),
      actions: [
        PrimaryAction(
          label: "Adjust tonight's context",
          onPressed: () => context.push('/today/context'),
        ),
        const SizedBox(height: 10),
        if (media != TonightMedia.shows)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => context.push('/search'),
              style: outlined,
              child: const Text('Add movies'),
            ),
          ),
        if (media != TonightMedia.movies) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => context.push('/search?media=shows'),
              style: outlined,
              child: const Text('Add shows'),
            ),
          ),
        ],
        if (media != TonightMedia.moviesAndShows && seriesOn) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => pickTonightMedia(context, ref, envelope),
              style: outlined,
              child: const Text('Change preference'),
            ),
          ),
        ],
      ],
      textStyle: text,
    );
  }
}

class _StateScaffold extends StatelessWidget {
  const _StateScaffold({
    required this.title,
    required this.body,
    required this.contextLine,
    required this.actions,
    required this.textStyle,
  });

  final String title;
  final String body;
  final String contextLine;
  final List<Widget> actions;
  final TextTheme textStyle;

  @override
  Widget build(BuildContext context) {
    final text = textStyle;
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Wordmark(),
                    const Spacer(),
                    Text(
                      contextLine,
                      style: text.labelMedium?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Semantics(
                      header: true,
                      child: Text(title, style: text.headlineMedium),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      body,
                      style: text.bodyLarge?.copyWith(
                        color: AppColors.textSoft,
                      ),
                    ),
                    const SizedBox(height: 28),
                    ...actions,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
