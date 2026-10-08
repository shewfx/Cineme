import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/selector_field.dart';
import '../../../shared/models/inventory.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../application/search_controller.dart';
import 'discovery_widgets.dart';
import 'search_feedback.dart';

/// Discovery shown while the search box is empty: one bounded page of films
/// (the same for everyone, never a recommendation) with no further scrolling.
/// Onboarding offers weekly trending only; the add screen offers [choices]
/// with a selector. Adds go through the same controller as search rows, so
/// one selection spans discovery and search. Shows have the same grid in
/// `ShowDiscoveryGrid`, built from the same pieces.
class DiscoveryGrid extends ConsumerWidget {
  const DiscoveryGrid({super.key, required this.choices});

  final List<DiscoveryList> choices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = choices.length == 1
        ? choices.first
        : ref.watch(discoveryChoiceProvider);
    final list = ref.watch(discoveryProvider(selected));
    final page = list.value;

    final Widget content;
    if (page != null) {
      content = page.results.isEmpty
          ? DiscoveryNote(
              selected == DiscoveryList.trending
                  ? 'Nothing is trending right now. Search for a film above.'
                  : 'No popular releases yet for this period. Search for a '
                        'film above.',
            )
          : DiscoveryWrap(
              cells: [
                for (final r in page.results)
                  _TrendingCell(
                    key: ValueKey('discover-${r.movie.tmdbId}'),
                    result: r,
                    onServer: page.inWatchlist.contains(r.movie.tmdbId),
                  ),
              ],
            );
    } else if (list.hasError) {
      content = DiscoveryRetry(
        onRetry: () => ref.invalidate(discoveryProvider(selected)),
      );
    } else {
      content = const DiscoverySkeleton(label: 'Loading trending films');
    }

    return DiscoveryFrame(
      // One compact dropdown (the app's option sheet) instead of a row of
      // pills: it wraps at large text and never overflows.
      selector: choices.length > 1
          ? SelectorField(
              label: 'Browse',
              value: selected.title,
              onTap: () async {
                final picked = await showOptionSheet<DiscoveryList>(
                  context,
                  title: 'Browse films',
                  options: [for (final c in choices) (c, c.title)],
                  selected: selected,
                );
                final choice = picked?.$1;
                if (choice != null) {
                  ref.read(discoveryChoiceProvider.notifier).select(choice);
                }
              },
            )
          : null,
      // With a dropdown the selected title is already shown in it.
      title: choices.length == 1 ? selected.title : null,
      subtitle: selected.subtitle,
      content: content,
    );
  }
}

class _TrendingCell extends ConsumerWidget {
  const _TrendingCell({
    super.key,
    required this.result,
    required this.onServer,
  });

  final SearchResult result;

  /// The server already lists this film on the caller's watchlist.
  final bool onServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movie = result.movie;
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
      action = const DiscoveryBusy();
    } else if (added) {
      action = DiscoveryStatus(Icons.check, 'Added', '${movie.title} added');
    } else if (mark == ResultMark.watched) {
      action = DiscoveryStatus(
        Icons.check,
        'Watched',
        '${movie.title} watched',
      );
    } else if (!result.canAdd || mark == ResultMark.ineligible) {
      action = DiscoveryStatus(
        Icons.block,
        "Can't add",
        "${movie.title} can't be added",
      );
    } else {
      action = DiscoveryAddButton(title: movie.title, onPressed: add);
    }
    return DiscoveryCell(info: movie, action: action);
  }
}
