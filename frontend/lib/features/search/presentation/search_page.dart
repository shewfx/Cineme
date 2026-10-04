import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_list_tile.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/models/inventory.dart';
import '../../history/data/history_repository.dart';
import '../application/search_controller.dart';
import '../data/search_repository.dart';

/// Search/Add: separate "Add to watchlist" and "Already watched" actions.
class SearchPage extends ConsumerWidget {
  const SearchPage({super.key, this.logMode = false});
  final bool logMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(searchRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'Search'));
    }
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);
    final text = Theme.of(context).textTheme;

    final Widget body = switch (state.results) {
      null => _Hint(
        state.query.isEmpty
            ? (logMode
                  ? 'Search for a film you watched.'
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
            return _ResultRow(result: results[i], logMode: logMode);
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

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 24, 8),
              child: Row(
                children: [
                  const BackButton(),
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      onChanged: controller.onQueryChanged,
                      textInputAction: TextInputAction.search,
                      style: text.bodyLarge,
                      decoration: InputDecoration(
                        hintText: logMode
                            ? 'Find a watched film'
                            : 'Search films',
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
            Expanded(child: body),
          ],
        ),
      ),
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
  const _ResultRow({required this.result, required this.logMode});

  final SearchResult result;
  final bool logMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movie = result.movie;
    final state = ref.watch(searchControllerProvider);
    final mark = state.marks[movie.tmdbId];
    final busy = state.busy.contains(movie.tmdbId);

    Future<void> run(Future<SearchOutcome> Function() action) async {
      final messenger = ScaffoldMessenger.of(context);
      final outcome = await action();
      final t = movie.title;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(switch (outcome) {
              SearchOutcome.added => 'Added “$t” to your watchlist.',
              SearchOutcome.alreadySaved =>
                '“$t” is already in your watchlist.',
              SearchOutcome.alreadyWatched =>
                "You've already watched “$t”, so it isn't added.",
              SearchOutcome.ineligible => "“$t” can't be added.",
              SearchOutcome.blocked =>
                "You chose never to recommend “$t”. Unblock it in Profile first.",
              SearchOutcome.recorded => 'Recorded “$t” as watched.',
              SearchOutcome.alreadyRecorded =>
                '“$t” was already in your history.',
              SearchOutcome.failed => connectionErrorMessage,
            }),
          ),
        );
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
    } else if (mark == ResultMark.saved) {
      action = const _Status(Icons.bookmark, 'In watchlist');
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
        !logMode &&
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
