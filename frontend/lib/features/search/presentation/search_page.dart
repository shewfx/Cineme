import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';
import '../../history/data/history_repository.dart';
import '../../series/application/series_support.dart';
import '../../series/presentation/show_search_panel.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../application/search_controller.dart';
import '../data/search_repository.dart';
import 'search_feedback.dart';
import 'discovery_grid.dart';

/// What a result row offers.
enum SearchMode {
  /// Add to watchlist, plus Already watched when history exists.
  add,

  /// Log a past viewing only.
  log,

  /// Add to watchlist only: onboarding is about the watchlist, not history.
  onboarding,
}

/// Search/Add: separate "Add to watchlist" and "Already watched" actions. With
/// shows available, a Movies | Shows control under the field keeps media
/// explicit; the two never mix in one list.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    this.logMode = false,
    this.initialShows = false,
  });

  final bool logMode;

  /// Open on the Shows side (Watchlist's "Add shows").
  final bool initialShows;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late MediaType _media = widget.initialShows
      ? MediaType.series
      : MediaType.movie;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(searchRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'Search'));
    }
    final shows = !widget.logMode && ref.watch(seriesEnabledProvider);
    final control = shows
        ? Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: SegmentedButton<MediaType>(
              key: const ValueKey('media-toggle'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: MediaType.movie, label: Text('Movies')),
                ButtonSegment(value: MediaType.series, label: Text('Shows')),
              ],
              selected: {_media},
              style: SegmentedButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: AppColors.text,
                selectedBackgroundColor: AppColors.accent.withValues(
                  alpha: 0.18,
                ),
                selectedForegroundColor: AppColors.accent,
              ),
              onSelectionChanged: (s) => setState(() => _media = s.first),
            ),
          )
        : null;
    return Scaffold(
      body: SafeArea(
        child: shows && _media == MediaType.series
            ? ShowSearchPanel(leading: const BackButton(), below: control)
            : SearchPanel(
                mode: widget.logMode ? SearchMode.log : SearchMode.add,
                leading: const BackButton(),
                below: control,
              ),
      ),
    );
  }
}

/// The query field and result list, shared by the Search page and
/// onboarding so both add films through exactly the same rows and rules.
class SearchPanel extends ConsumerWidget {
  const SearchPanel({
    super.key,
    this.mode = SearchMode.add,
    this.leading,
    this.autofocus = true,
    this.below,
  });

  final SearchMode mode;
  final Widget? leading;

  /// Rendered under the field (the Movies | Shows control).
  final Widget? below;

  /// Onboarding does not open the keyboard over its own actions.
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logMode = mode == SearchMode.log;
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final text = Theme.of(context).textTheme;

    final Widget body = switch (state.results) {
      // Nothing typed: discovery. Onboarding shows weekly trending only;
      // the add screen offers the three lists.
      null when mode != SearchMode.log && state.query.isEmpty => DiscoveryGrid(
        choices: mode == SearchMode.onboarding
            ? const [DiscoveryList.trending]
            : DiscoveryList.values,
      ),
      null => _Hint(
        state.query.isEmpty
            ? (logMode
                  ? 'Search for a film you watched.'
                  : mode == SearchMode.onboarding
                  ? 'Search by title for a film you want to watch.'
                  : 'Search by title to add films to your watchlist.')
            : 'Type at least $minQueryLength letters to search.',
      ),
      AsyncLoading() => const SkeletonList(),
      AsyncError() => ErrorPanel(
        message:
            "Search isn't available right now. Your watchlist is unaffected.",
        onRetry: controller.retry,
      ),
      AsyncData(value: final results) when results.isEmpty => EmptyState(
        title: 'No films match “${state.query}”',
        message: 'Check the spelling or try another title.',
      ),
      AsyncData(value: final results) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: results.length + (state.hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < results.length) {
            return _ResultRow(result: results[i], mode: mode);
          }
          if (state.loadMoreError == null && !state.loadingMore) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => controller.loadMore(),
            );
          }
          return LoadMoreRow(
            error: state.loadMoreError,
            onRetry: controller.loadMore,
          );
        },
      ),
    };

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(leading == null ? 24 : 8, 8, 24, 8),
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: TextField(
                  autofocus: autofocus,
                  onChanged: controller.onQueryChanged,
                  textInputAction: TextInputAction.search,
                  style: text.bodyLarge,
                  decoration: InputDecoration(
                    hintText: logMode ? 'Find a watched film' : 'Search films',
                    hintStyle: text.bodyLarge?.copyWith(
                      color: AppColors.textMuted,
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                    prefixIcon: const Icon(
                      Icons.search,
                      color: AppColors.textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.chip),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ?below,
        Expanded(child: body),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: AppColors.textMuted),
    ),
  );
}

class _ResultRow extends ConsumerWidget {
  const _ResultRow({required this.result, required this.mode});

  final SearchResult result;
  final SearchMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logMode = mode == SearchMode.log;
    final movie = result.movie;
    final state = ref.watch(searchControllerProvider);
    final mark = state.marks[movie.tmdbId];
    final busy = state.busy.contains(movie.tmdbId);
    // Onboarding keeps one selection across trending and search: a film
    // already on the server-side watchlist reads as added here too.
    final listed =
        mode != SearchMode.log &&
        (ref
                .watch(watchlistControllerProvider)
                .value
                ?.items
                .any((e) => e.movie.tmdbId == movie.tmdbId) ??
            false);

    Future<void> run(Future<SearchOutcome> Function() action) async {
      final messenger = ScaffoldMessenger.of(context);
      final outcome = await action();
      showSearchOutcome(messenger, outcome, movie.title);
    }

    Future<void> confirmWatched() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Record “${movie.title}” as watched?'),
          content: const Text(
            'This logs a past viewing with an unknown date. It adds no rating '
            'and removes the film from your watchlist.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Record'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await run(
          () =>
              ref.read(searchControllerProvider.notifier).recordWatched(result),
        );
      }
    }

    final Widget action;
    if (busy) {
      action = const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else if (logMode) {
      action = mark == ResultMark.watched
          ? const _Status(Icons.check, 'Recorded')
          : _SmallAction(
              label: 'Log watched',
              onPressed: () => run(
                () => ref
                    .read(searchControllerProvider.notifier)
                    .recordWatched(result),
              ),
            );
    } else if (!result.canAdd || mark == ResultMark.ineligible) {
      action = const _Status(Icons.block, "Can't add");
    } else if (mark == ResultMark.watched) {
      action = const _Status(Icons.check, 'Watched');
    } else if (mark == ResultMark.saved || listed) {
      action = _Status(
        mode == SearchMode.onboarding ? Icons.check : Icons.bookmark,
        mode == SearchMode.onboarding ? 'Added' : 'In watchlist',
      );
    } else {
      // The screen is already "add to watchlist", so the row says Add;
      // screen readers still hear the full action.
      action = _SmallAction(
        label: 'Add',
        semanticsLabel: 'Add ${movie.title} to watchlist',
        primary: true,
        onPressed: () =>
            run(() => ref.read(searchControllerProvider.notifier).add(result)),
      );
    }

    // Large text: stack the action under the details instead of squeezing
    // the title into a sliver beside it.
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 13;
    // Logging a past viewing needs viewing history (P5).
    final alreadyWatched =
        mode == SearchMode.add &&
            ref.watch(historyRepositoryProvider) != null &&
            mark != ResultMark.watched &&
            result.canAdd
        ? _SmallAction(label: 'Already watched', onPressed: confirmWatched)
        : null;
    final footer = [if (stacked) action, ?alreadyWatched];

    // Search results often have no runtime yet; that is simply left out.
    final yearLine = yearAndRuntime(movie, unknownRuntime: null);
    return MovieListTile(
      movie: movie,
      large: true,
      lines: [
        if (yearLine.isNotEmpty) yearLine,
        if (movie.genres.isNotEmpty) movie.genres.map((g) => g.name).join(', '),
        // Saveable, but never picked for Tonight until it's out.
        if (!movie.released) 'Not released yet',
      ],
      trailing: stacked ? null : action,
      footer: footer.isEmpty
          ? null
          : Wrap(spacing: 8, runSpacing: 4, children: footer),
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.semanticsLabel,
  });

  final String label;
  final VoidCallback onPressed;
  final bool primary;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: primary ? AppColors.accent : AppColors.text,
      side: BorderSide(color: primary ? AppColors.accent : AppColors.border),
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      textStyle: const TextStyle(
        fontFamily: 'Jost',
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
    ),
    child: Text(label, semanticsLabel: semanticsLabel),
  );
}

class _Status extends StatelessWidget {
  const _Status(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: AppColors.textMuted),
        ),
      ],
    ),
  );
}
