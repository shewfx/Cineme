import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';
import '../../search/presentation/discovery_widgets.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../application/series_controllers.dart';
import 'show_search_panel.dart';

/// "Trending shows this week": TMDB's weekly TV trending (anime included),
/// one bounded page, shown while the show search box is empty. Same cards,
/// Add/Added behaviour and states as the film grid; adds go through the same
/// controller as show search rows, so membership is shared with search.
/// Trending is the same for everyone and is not a recommendation.
class ShowDiscoveryGrid extends ConsumerWidget {
  const ShowDiscoveryGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingShowsProvider);
    final page = trending.value;
    final Widget content;
    if (page != null) {
      content = page.results.isEmpty
          ? const DiscoveryNote(
              'Nothing is trending right now. Search for a show above.',
            )
          : DiscoveryWrap(
              cells: [
                for (final s in page.results)
                  _TrendingShowCell(
                    key: ValueKey('discover-show-${s.tmdbId}'),
                    series: s,
                    onServer: page.inWatchlist.contains(s.tmdbId),
                  ),
              ],
            );
    } else if (trending.hasError) {
      content = DiscoveryRetry(
        onRetry: () => ref.invalidate(trendingShowsProvider),
      );
    } else {
      content = const DiscoverySkeleton(label: 'Loading trending shows');
    }
    return DiscoveryFrame(
      title: 'Trending shows this week',
      subtitle: 'What people are watching worldwide this week, anime included.',
      content: content,
    );
  }
}

class _TrendingShowCell extends ConsumerWidget {
  const _TrendingShowCell({
    super.key,
    required this.series,
    required this.onServer,
  });

  final Series series;

  /// The server already lists this show on the caller's watchlist.
  final bool onServer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(showSearchControllerProvider);
    final busy = state.busy.contains(series.tmdbId);
    final listed =
        ref
            .watch(watchlistItemsProvider)
            .value
            ?.items
            .any(
              (i) => i is ShowItem && i.show.series.tmdbId == series.tmdbId,
            ) ??
        false;
    final added = state.added.contains(series.tmdbId) || onServer || listed;

    final Widget action;
    if (busy) {
      action = const DiscoveryBusy();
    } else if (added) {
      action = DiscoveryStatus(Icons.check, 'Added', '${series.name} added');
    } else if (!series.canAdd) {
      action = DiscoveryStatus(
        Icons.block,
        "Can't add",
        "${series.name} can't be added",
      );
    } else {
      action = DiscoveryAddButton(
        title: series.name,
        onPressed: () => addShowWithFeedback(context, ref, series),
      );
    }
    return DiscoveryCell(info: series, action: action);
  }
}
