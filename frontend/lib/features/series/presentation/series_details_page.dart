import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../core/widgets/selector_field.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/models/inventory.dart';
import '../../../shared/models/series.dart';
import '../../today/presentation/feedback_sheets.dart';
import '../../watchlist/presentation/watchlist_page.dart' show showStateLine;
import '../application/series_controllers.dart';

/// A show: where you are, what is next, and how to correct it. Progress only
/// moves forward through Mark watched; "Set my progress" is the explicit way
/// to jump or go back, and it never records viewings.
class SeriesDetailsPage extends ConsumerStatefulWidget {
  const SeriesDetailsPage({super.key, required this.tmdbId});

  final int tmdbId;

  @override
  ConsumerState<SeriesDetailsPage> createState() => _SeriesDetailsPageState();
}

class _SeriesDetailsPageState extends ConsumerState<SeriesDetailsPage> {
  String? _busy;

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = label);
    try {
      await action();
    } on ApiError catch (e) {
      _say(
        e.code == 'VERSION_CONFLICT'
            ? 'Your progress changed elsewhere. It has been refreshed.'
            : e.code == 'NOT_NEXT_EPISODE'
            ? 'That is not the next episode any more. It has been refreshed.'
            : e.message,
      );
      ref.invalidate(seriesDetailsProvider(widget.tmdbId));
    } on InventoryConflict catch (c) {
      _say(switch (c.code) {
        'SERIES_BLOCKED' =>
          'You chose never to recommend this show. Unblock it first.',
        'WATCHLIST_LIMIT' => 'Your watchlist is full.',
        _ => "This show can't be added.",
      });
    } catch (_) {
      _say(connectionErrorMessage);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(seriesDetailsProvider(widget.tmdbId));
    return Scaffold(
      appBar: AppBar(title: const Text('Show details')),
      body: SafeArea(
        child: details.when(
          skipLoadingOnReload: true,
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          error: (error, _) => error is ApiError && error.status == 404
              ? const EmptyState(
                  title: 'Show not found',
                  message: 'This show is no longer available from TMDB.',
                )
              : ErrorPanel(
                  onRetry: () =>
                      ref.invalidate(seriesDetailsProvider(widget.tmdbId)),
                ),
          data: _content,
        ),
      ),
    );
  }

  Widget _content(SeriesDetails d) {
    final text = Theme.of(context).textTheme;
    final entry = d.entry;
    final series = d.series;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 108,
                height: 162,
                child: MoviePoster(movie: series),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(series.name, style: text.headlineSmall),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      'Show',
                      if (series.year != null) '${series.year}',
                      ?series.status,
                    ].join('  ·  '),
                    style: text.bodyMedium?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                  if (series.genres.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      series.genres.map((g) => g.name).join(', '),
                      style: text.bodyMedium?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (entry == null) _notOnList(d) else _progress(entry),
        if (d.overview != null) ...[
          const SizedBox(height: 24),
          Text('Overview', style: text.titleMedium),
          const SizedBox(height: 6),
          Text(d.overview!, style: text.bodyMedium),
        ],
        const SizedBox(height: 24),
        Text(
          d.limitations,
          key: const ValueKey('series-limitations'),
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (d.stale)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Showing saved details; TMDB could not be reached.',
              style: text.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
        if (entry != null) ...[
          const SizedBox(height: 16),
          Center(
            child: TextButton.icon(
              onPressed: _busy != null ? null : () => _remove(entry),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove from watchlist'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _notOnList(SeriesDetails d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Not on your watchlist.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 12),
      PrimaryAction(
        label: 'Add to watchlist',
        loading: _busy == 'add',
        onPressed: d.series.canAdd
            ? () => _run(
                'add',
                () => ref.read(seriesActionsProvider).add(widget.tmdbId),
              )
            : null,
      ),
    ],
  );

  Widget _progress(ShowEntry entry) {
    final text = Theme.of(context).textTheme;
    final next = entry.next;
    final progress = entry.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your progress', style: text.titleMedium),
        const SizedBox(height: 6),
        Text(
          progress == null
              ? 'Not started'
              : 'Last watched: Season ${progress.season}, Episode ${progress.episode}',
          key: const ValueKey('series-progress'),
          style: text.bodyLarge,
        ),
        const SizedBox(height: 4),
        Text(
          showStateLine(entry),
          key: const ValueKey('series-next'),
          style: text.bodyMedium?.copyWith(color: AppColors.textSoft),
        ),
        if (next.state == NextState.upNext && next.episode?.name != null)
          Text(
            next.episode!.name!,
            style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
          ),
        const SizedBox(height: 16),
        if (next.state == NextState.upNext)
          PrimaryAction(
            label: 'Mark ${next.episode!.code} watched',
            loading: _busy == 'watch',
            onPressed: () => _markWatched(entry, next.episode!),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy != null ? null : () => _setProgress(entry),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            side: const BorderSide(color: AppColors.border),
            minimumSize: const Size.fromHeight(50),
          ),
          child: const Text('Set my progress'),
        ),
      ],
    );
  }

  Future<void> _markWatched(ShowEntry entry, Episode episode) async {
    final result = await showMarkWatchedSheet(
      context,
      entry.series,
      subject: '${episode.code} of “${entry.series.name}”',
      completesTonight: false,
    );
    if (result == null || !result.$1) return;
    await _run(
      'watch',
      () => ref
          .read(seriesActionsProvider)
          .markNextWatched(
            widget.tmdbId,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            rating: result.$2,
          ),
    );
  }

  Future<void> _setProgress(ShowEntry entry) async {
    final picked = await showModalBottomSheet<_Picked>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (_) => _ProgressSheet(tmdbId: widget.tmdbId, current: entry),
    );
    if (picked == null) return;
    await _run(
      'progress',
      () => ref
          .read(seriesActionsProvider)
          .setProgress(
            widget.tmdbId,
            expectedVersion: entry.progressVersion,
            last: picked.last,
          ),
    );
  }

  Future<void> _remove(ShowEntry entry) async {
    await _run('remove', () async {
      await ref.read(seriesActionsProvider).remove(entry.id);
      _say('Removed “${entry.series.name}”. Your progress is kept.');
    });
  }
}

class _Picked {
  const _Picked(this.last);

  /// Null means "Not started".
  final (int, int)? last;
}

/// Season and episode pickers over the cached regular episodes. Only episodes
/// that have aired can be chosen: progress means "I have watched this".
class _ProgressSheet extends ConsumerStatefulWidget {
  const _ProgressSheet({required this.tmdbId, required this.current});

  final int tmdbId;
  final ShowEntry current;

  @override
  ConsumerState<_ProgressSheet> createState() => _ProgressSheetState();
}

class _ProgressSheetState extends ConsumerState<_ProgressSheet> {
  int? _season;
  int? _episode;

  @override
  void initState() {
    super.initState();
    final p = widget.current.progress;
    _season = p?.season;
    _episode = p?.episode;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final seasons = ref.watch(seriesSeasonsProvider(widget.tmdbId));
    final now = DateTime.now();
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: seasons.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
          error: (_, _) => ErrorPanel(
            onRetry: () => ref.invalidate(seriesSeasonsProvider(widget.tmdbId)),
          ),
          data: (list) {
            final aired = [
              for (final s in list)
                SeasonInfo(
                  number: s.number,
                  episodes: [
                    for (final e in s.episodes)
                      if (e.airDate != null && !e.airDate!.isAfter(now)) e,
                  ],
                ),
            ].where((s) => s.episodes.isNotEmpty).toList();
            final season = aired.where((s) => s.number == _season).firstOrNull;
            final valid =
                season != null &&
                season.episodes.any((e) => e.episodeNumber == _episode);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text('Set my progress', style: text.titleLarge),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pick the last episode you watched. Cinemé offers the one '
                  'after it. This does not log any viewings.',
                  style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
                ),
                const SizedBox(height: 16),
                SelectorField(
                  label: 'Season',
                  value: _season == null
                      ? 'Choose a season'
                      : 'Season $_season',
                  onTap: () async {
                    final r = await showOptionSheet<int>(
                      context,
                      title: 'Season',
                      options: [
                        for (final s in aired) (s.number, 'Season ${s.number}'),
                      ],
                      selected: _season,
                    );
                    final n = r?.$1;
                    if (n != null && n != _season) {
                      setState(() {
                        _season = n;
                        _episode = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                SelectorField(
                  label: 'Episode',
                  value: _episode == null
                      ? 'Choose an episode'
                      : 'Episode $_episode',
                  onTap: season == null
                      ? null
                      : () async {
                          final r = await showOptionSheet<int>(
                            context,
                            title: 'Episode',
                            options: [
                              for (final e in season.episodes)
                                (
                                  e.episodeNumber,
                                  e.name == null
                                      ? 'Episode ${e.episodeNumber}'
                                      : 'Episode ${e.episodeNumber} · ${e.name}',
                                ),
                            ],
                            selected: _episode,
                          );
                          final n = r?.$1;
                          if (n != null) setState(() => _episode = n);
                        },
                ),
                const SizedBox(height: 20),
                PrimaryAction(
                  label: 'Save progress',
                  onPressed: valid
                      ? () => Navigator.pop(
                          context,
                          _Picked((_season!, _episode!)),
                        )
                      : null,
                ),
                if (widget.current.progress != null)
                  Center(
                    child: TextButton(
                      onPressed: () =>
                          Navigator.pop(context, const _Picked(null)),
                      child: const Text('Not started'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
