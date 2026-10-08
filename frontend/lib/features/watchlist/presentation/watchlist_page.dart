import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/selector_field.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_swipe_exclusion.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';
import '../../history/application/history_controllers.dart';
import '../../history/data/history_repository.dart';
import '../../series/application/series_support.dart';
import '../../today/application/today_controller.dart';
import '../application/watchlist_controller.dart';
import '../data/watchlist_repository.dart';

/// Inventory management: inspect, add and remove films and shows. Not a way
/// to pick tonight.
class WatchlistPage extends ConsumerWidget {
  const WatchlistPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(watchlistRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'Your watchlist'));
    }
    final controller = ref.read(watchlistItemsProvider.notifier);
    final posters =
        ref.watch(watchlistLayoutProvider) == WatchlistLayout.posters;
    final shows = ref.watch(seriesEnabledProvider);
    final media = shows
        ? ref.watch(watchlistMediaProvider)
        : WatchlistMedia.all;
    return TabPage(
      title: 'Watchlist',
      subtitle: shows
          ? 'Films and shows you might watch. Tonight picks from here.'
          : 'Films you might watch. Tonight picks from here.',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Sort watchlist',
            icon: const Icon(Icons.swap_vert_rounded),
            onPressed: () async {
              final current = ref.read(watchlistSortProvider);
              final picked = await showOptionSheet<WatchlistSort>(
                context,
                title: 'Sort by',
                options: [for (final s in WatchlistSort.values) (s, s.label)],
                selected: current,
              );
              final sort = picked?.$1;
              if (sort != null) {
                await ref.read(watchlistSortProvider.notifier).set(sort);
              }
            },
          ),
          IconButton(
            tooltip: posters ? 'Show as list' : 'Show as posters',
            icon: Icon(
              posters ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
            onPressed: () => ref
                .read(watchlistLayoutProvider.notifier)
                .set(posters ? WatchlistLayout.list : WatchlistLayout.posters),
          ),
          IconButton(
            tooltip: shows ? 'Add movies or shows' : 'Add movies',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      child: Column(
        children: [
          if (shows)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              // A display filter only: it never deletes anything or touches
              // history, progress or what Tonight considers.
              child: SelectorField(
                label: 'Show',
                value: media.label,
                onTap: () async {
                  final picked = await showOptionSheet<WatchlistMedia>(
                    context,
                    title: 'Show in watchlist',
                    options: [
                      for (final m in WatchlistMedia.values) (m, m.label),
                    ],
                    selected: media,
                  );
                  final choice = picked?.$1;
                  if (choice != null) {
                    await ref.read(watchlistMediaProvider.notifier).set(choice);
                  }
                },
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => PagedListView<WatchlistItem>(
                value: ref.watch(watchlistItemsProvider),
                empty: _empty(context, media),
                gridDelegate: posters
                    ? _posterGrid(context, box.maxWidth)
                    : null,
                gridPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                itemBuilder: (context, item) => posters
                    ? _PosterTile(key: ValueKey(item.id), item: item)
                    : _WatchlistRow(key: ValueKey(item.id), item: item),
                onRetry: () => ref.invalidate(watchlistItemsProvider),
                onRefresh: () => ref.refresh(watchlistItemsProvider.future),
                onLoadMore: controller.loadMore,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// An empty category says what is missing and offers the matching add.
  Widget _empty(BuildContext context, WatchlistMedia media) => switch (media) {
    WatchlistMedia.all => EmptyState(
      title: 'Your watchlist is empty',
      message:
          'Add films you might like to watch. Tonight picks one from here.',
      actionLabel: 'Add movies',
      onAction: () => context.push('/search'),
    ),
    WatchlistMedia.movies => EmptyState(
      title: 'No movies in your watchlist',
      message: 'Add films you might like to watch.',
      actionLabel: 'Add movies',
      onAction: () => context.push('/search'),
    ),
    WatchlistMedia.shows => EmptyState(
      title: 'No shows in your watchlist yet',
      message: 'Add a show or anime series and Cinemé tracks where you are.',
      actionLabel: 'Add shows',
      onAction: () => context.push('/search?media=shows'),
    ),
  };
}

const _gridGap = 12.0;
const _titleGap = 8.0;

/// Three columns on normal phones, two when very narrow. Each tile is a
/// 2:3 poster plus room for a two-line title at the current text scale.
SliverGridDelegate _posterGrid(BuildContext context, double width) {
  final inner = width - 48;
  final columns = inner >= 280 ? 3 : 2;
  final tileWidth = (inner - _gridGap * (columns - 1)) / columns;
  final style = _titleStyle(context);
  final line =
      MediaQuery.textScalerOf(context).scale(style.fontSize!) * style.height!;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: _gridGap,
    mainAxisSpacing: 20,
    mainAxisExtent: tileWidth * 1.5 + _titleGap + line * 2 + 2,
  );
}

TextStyle _titleStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!
        .copyWith(color: AppColors.text, height: 1.3);

/// The one removal path for both layouts: no dialog, Undo instead. Returns
/// whether the entry was removed; failures are explained and keep it.
Future<bool> _removeWithUndo(
  BuildContext context,
  WidgetRef ref,
  WatchlistItem item,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final controller = ref.read(watchlistItemsProvider.notifier);
  final title = item.info.title;
  try {
    if (!await controller.remove(item)) return false;
  } catch (_) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't remove “$title”. It's still in your watchlist.",
          ),
        ),
      );
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Removed “$title”.'),
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await controller.restore(item);
            } catch (_) {
              messenger.showSnackBar(
                SnackBar(content: Text("Couldn't put back “$title”.")),
              );
            }
          },
        ),
      ),
    );
  return true;
}

/// Where a show stands, in words.
String showStateLine(ShowEntry show) {
  final next = show.next;
  final episode = next.episode;
  return switch (next.state) {
    NextState.upNext => 'Up next: ${episode!.code}',
    NextState.notAired =>
      episode?.airDate == null
          ? '${episode?.code ?? 'The next episode'} hasn’t aired yet'
          : '${episode!.code} airs ${shortDate(episode.airDate!)}',
    NextState.caughtUp => 'Caught up',
    NextState.completed => 'Finished',
    NextState.unavailable => 'Episodes unavailable right now',
  };
}

List<String> _details(WatchlistItem item) => switch (item) {
  MovieItem(:final entry) => [
    yearAndRuntime(entry.movie),
    if (!entry.movie.released) 'Not released yet',
    'Added ${shortDate(entry.addedAt)}',
  ],
  ShowItem(:final show) => [
    ['Show', if (show.series.year != null) '${show.series.year}'].join('  ·  '),
    showStateLine(show),
    'Added ${shortDate(show.addedAt)}',
  ],
};

/// Opens the details page for the item's own media type.
void _open(BuildContext context, WatchlistItem item) => switch (item) {
  MovieItem(:final entry) => context.push(
    '/movies/${entry.movie.tmdbId}',
    extra: entry,
  ),
  ShowItem(:final show) => context.push('/series/${show.series.tmdbId}'),
};

Future<void> _markWatched(
  BuildContext context,
  WidgetRef ref,
  WatchlistEntry entry,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Mark “${entry.movie.title}” watched?'),
      content: const Text(
        'This records a past viewing with an unknown date and archives it from your watchlist.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('Mark watched'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(historyRepositoryProvider)!.recordManual(entry.movie.tmdbId);
    ref
      ..invalidate(viewingHistoryProvider)
      ..invalidate(watchlistItemsProvider)
      ..invalidate(watchlistControllerProvider)
      ..invalidate(todayEnvelopeProvider);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't mark it watched. Try again.")),
      );
    }
  }
}

/// List row: swipe right to remove. Below the threshold it snaps back.
class _WatchlistRow extends ConsumerWidget {
  const _WatchlistRow({super.key, required this.item});

  final WatchlistItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final item = this.item;
    return Semantics(
      // Swiping isn't reachable with a screen reader; this action is.
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Remove from watchlist'): () =>
            _removeWithUndo(context, ref, item),
      },
      child: ExcludeTabSwipe(
        child: Dismissible(
          key: ValueKey('dismiss-${item.id}'),
          direction: DismissDirection.startToEnd,
          dismissThresholds: const {DismissDirection.startToEnd: 0.4},
          confirmDismiss: (_) => _removeWithUndo(context, ref, item),
          background: ColoredBox(
            color: AppColors.accent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, color: AppColors.background),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Remove',
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium?.copyWith(
                        color: AppColors.background,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: ColoredBox(
            color: AppColors.background,
            child: InkWell(
              onTap: () => _open(context, item),
              child: MovieListTile(
                movie: item.info,
                lines: _details(item),
                trailing:
                    item is MovieItem &&
                        ref.watch(historyRepositoryProvider) != null
                    ? IconButton(
                        tooltip: 'Mark ${item.info.title} watched',
                        onPressed: () => _markWatched(context, ref, item.entry),
                        icon: const Icon(Icons.check_circle_outline),
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Poster tile: long-press for actions. No swipe in the grid.
class _PosterTile extends ConsumerWidget {
  const _PosterTile({super.key, required this.item});

  final WatchlistItem item;

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final item = this.item;
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                item.info.title,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            if (item is MovieItem)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Mark watched'),
                onTap: () => Navigator.pop(sheet, 'watched'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from watchlist'),
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (action == 'remove' && context.mounted) {
      await _removeWithUndo(context, ref, item);
    } else if (action == 'watched' && item is MovieItem && context.mounted) {
      await _markWatched(context, ref, item.entry);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = item.info;
    return ExcludeTabSwipe(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(context, item),
        onLongPress: () => _actions(context, ref),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: MoviePoster(movie: info),
              ),
            ),
            const SizedBox(height: _titleGap),
            Text(
              info.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _titleStyle(context),
            ),
          ],
        ),
      ),
    );
  }
}
