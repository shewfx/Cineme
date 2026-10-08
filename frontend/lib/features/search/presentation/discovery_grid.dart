import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/choice_pill.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../shared/models/inventory.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../application/search_controller.dart';
import 'search_feedback.dart';

/// Discovery shown while the search box is empty: one bounded page of films
/// (the same for everyone, never a recommendation) with no further scrolling.
/// Onboarding offers weekly trending only; the add screen offers [choices]
/// with a selector. Adds go through the same controller as search rows, so
/// one selection spans discovery and search.
class DiscoveryGrid extends ConsumerWidget {
  const DiscoveryGrid({super.key, required this.choices});

  final List<DiscoveryList> choices;

  static const _minCell = 160.0;
  static const _gap = 16.0;
  static const _inset = 24.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final selected = choices.length == 1
        ? choices.first
        : ref.watch(discoveryChoiceProvider);
    final list = ref.watch(discoveryProvider(selected));
    final page = list.value;

    final Widget content;
    if (page != null) {
      content = page.results.isEmpty
          ? _Note(
              selected == DiscoveryList.trending
                  ? 'Nothing is trending right now. Search for a film above.'
                  : 'No popular releases yet for this period. Search for a '
                        'film above.',
              style: text,
            )
          : LayoutBuilder(
              builder: (context, box) {
                final inner = box.maxWidth - 2 * _inset;
                // Two columns on narrow phones, more as the width allows.
                final columns = (inner / (_minCell + _gap)).floor().clamp(2, 6);
                final width = (inner - _gap * (columns - 1)) / columns;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _inset),
                  child: Wrap(
                    spacing: _gap,
                    runSpacing: 20,
                    children: [
                      for (final r in page.results)
                        SizedBox(
                          key: ValueKey('discover-${r.movie.tmdbId}'),
                          width: width,
                          child: _TrendingCell(
                            result: r,
                            onServer: page.inWatchlist.contains(r.movie.tmdbId),
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
    } else if (list.hasError) {
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                "Couldn't load this list. You can still search above.",
                style: text.bodyMedium?.copyWith(color: AppColors.textSoft),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => ref.invalidate(discoveryProvider(selected)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.border),
                minimumSize: const Size(0, 48),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    } else {
      content = const _Skeleton();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (choices.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(_inset, 4, _inset, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in choices)
                    ChoicePill(
                      label: c.title,
                      selected: c == selected,
                      onTap: () =>
                          ref.read(discoveryChoiceProvider.notifier).select(c),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(_inset, 8, _inset, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // With a selector the pills carry the titles.
                if (choices.length == 1) ...[
                  Semantics(
                    header: true,
                    child: Text(selected.title, style: text.titleMedium),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  selected.subtitle,
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          content,
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.message, {required this.style});

  final String message;
  final TextTheme style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: DiscoveryGrid._inset),
    child: Text(
      message,
      style: style.bodyMedium?.copyWith(color: AppColors.textMuted),
    ),
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading trending films',
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DiscoveryGrid._inset),
        child: Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) const SizedBox(width: DiscoveryGrid._gap),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _TrendingCell extends ConsumerWidget {
  const _TrendingCell({required this.result, required this.onServer});

  final SearchResult result;

  /// The server already lists this film on the caller's watchlist.
  final bool onServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movie = result.movie;
    final text = Theme.of(context).textTheme;
    final state = ref.watch(searchControllerProvider);
    final mark = state.marks[movie.tmdbId];
    final busy = state.busy.contains(movie.tmdbId);
    final listed =
        ref
            .watch(watchlistControllerProvider)
            .value
            ?.items
            .any((e) => e.movie.tmdbId == movie.tmdbId) ??
        false;
    final added = mark == ResultMark.saved || onServer || listed;

    Future<void> add() async {
      // A second tap while the first is in flight is ignored, not reported.
      if (ref.read(searchControllerProvider).busy.contains(movie.tmdbId)) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      final outcome = await ref
          .read(searchControllerProvider.notifier)
          .add(result);
      showSearchOutcome(messenger, outcome, movie.title);
    }

    final Widget action;
    if (busy) {
      action = const SizedBox(
        height: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    } else if (added) {
      action = _Status(Icons.check, 'Added', '${movie.title} added');
    } else if (mark == ResultMark.watched) {
      action = _Status(Icons.check, 'Watched', '${movie.title} watched');
    } else if (!result.canAdd || mark == ResultMark.ineligible) {
      action = _Status(
        Icons.block,
        "Can't add",
        "${movie.title} can't be added",
      );
    } else {
      action = SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: add,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.accent,
            side: const BorderSide(color: AppColors.accent),
            minimumSize: const Size(0, 48),
          ),
          child: Text('Add', semanticsLabel: 'Add ${movie.title} to watchlist'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: MoviePoster(movie: movie),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          movie.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.titleSmall,
        ),
        if (movie.year != null)
          Text(
            '${movie.year}',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        const SizedBox(height: 6),
        action,
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.icon, this.label, this.semanticsLabel);

  final IconData icon;
  final String label;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticsLabel,
    child: ExcludeSemantics(
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
