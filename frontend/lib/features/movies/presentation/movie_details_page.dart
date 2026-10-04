import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/movie_poster.dart';
import '../../../core/widgets/scroll_depth_hint.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/state/revision.dart';
import '../../../shared/models/inventory.dart';
import '../../today/presentation/availability_section.dart';
import '../../history/data/history_repository.dart';
import '../../preferences/application/profile_controller.dart';
import '../../preferences/data/profile_repository.dart';
import '../../watchlist/application/watchlist_controller.dart';
import '../data/movie_details_repository.dart';

class MovieDetailsPage extends ConsumerStatefulWidget {
  const MovieDetailsPage({super.key, required this.tmdbId, this.entry});

  final int tmdbId;
  final WatchlistEntry? entry;

  @override
  ConsumerState<MovieDetailsPage> createState() => _MovieDetailsPageState();
}

class _MovieDetailsPageState extends ConsumerState<MovieDetailsPage> {
  bool _removed = false;
  bool _watched = false;
  bool _blocked = false;
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final detailsRepository = ref.watch(movieDetailsRepositoryProvider);
    final entry = widget.entry;
    final Widget content;
    if (detailsRepository == null) {
      content = widget.entry == null
          ? const ErrorPanel(
              message: 'Movie details are unavailable in this build.',
              onRetry: _noop,
            )
          : _success(previewMovieDetails(widget.entry!.movie), entry);
    } else {
      content = ref
          .watch(movieDetailsProvider(widget.tmdbId))
          .when(
            loading: _loading,
            error: (error, _) => _error(error),
            data: (details) => _success(details, entry),
          );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Movie details')),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            Expanded(child: content),
            _actions(entry),
          ],
        ),
      ),
    );
  }

  static void _noop() {}

  Widget _loading() => ListView(
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 108,
            height: 162,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(width: 20),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonLine(width: 170, height: 24),
                SizedBox(height: 12),
                _SkeletonLine(width: 112),
                SizedBox(height: 9),
                _SkeletonLine(width: 140),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 28),
      const _SkeletonLine(width: 92),
      const SizedBox(height: 12),
      const _SkeletonLine(),
      const SizedBox(height: 8),
      const _SkeletonLine(width: 260),
      const SizedBox(height: 8),
      const _SkeletonLine(width: 210),
      const SizedBox(height: 26),
      const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    ],
  );

  Widget _error(Object error) {
    if (error case ApiError(status: 404)) {
      return const EmptyState(
        title: 'Movie not found',
        message: 'This film is no longer available from the movie database.',
      );
    }
    return ErrorPanel(
      onRetry: () => ref.invalidate(movieDetailsProvider(widget.tmdbId)),
    );
  }

  Widget _success(MovieDetails details, WatchlistEntry? entry) {
    final movie = details.movie;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: AppColors.textMuted,
    );
    final facts = <String>[
      if (details.releaseDate != null)
        shortDate(details.releaseDate!)
      else if (movie.year != null)
        '${movie.year}',
      if (movie.runtimeMinutes != null) '${movie.runtimeMinutes} min',
      if (movie.voteAverage case final rating?
          when rating.isFinite && rating > 0)
        'TMDB ${rating.toStringAsFixed(1)}',
      if (movie.genres.isNotEmpty)
        movie.genres.map((genre) => genre.name).join(', '),
    ];
    return ScrollDepthHint(
      child: SingleChildScrollView(
        key: const ValueKey('movie-details-scroll'),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 108,
                    height: 162,
                    child: MoviePoster(movie: movie),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            movie.title,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontSize: 27,
                            ),
                          ),
                        ),
                        if (details.originalTitle != null &&
                            details.originalTitle != movie.title) ...[
                          const SizedBox(height: 6),
                          Text(details.originalTitle!, style: muted),
                        ],
                        if (facts.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(facts.join('  ·  '), style: muted),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (details.stale) ...[
              const SizedBox(height: 14),
              Text(
                'Showing saved details. Fresh information is temporarily unavailable.',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ],
            if (details.overview != null) ...[
              const SizedBox(height: 28),
              Semantics(
                header: true,
                child: Text('Overview', style: theme.textTheme.titleLarge),
              ),
              const SizedBox(height: 8),
              Text(
                details.overview!,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSoft,
                ),
              ),
            ],
            const SizedBox(height: 24),
            AvailabilitySection(tmdbId: movie.tmdbId),
            if (entry != null && !_removed) ...[
              const SizedBox(height: 4),
              Text(
                'Added ${shortDate(entry.addedAt)}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(WatchlistEntry? entry) {
    final history = ref.watch(historyRepositoryProvider);
    final profile = ref.watch(profileRepositoryProvider);
    final children = <Widget>[];
    if (_watched) {
      children.add(_status('Watched · saved in History'));
    } else if (_removed) {
      children.add(_status('Removed from watchlist'));
    } else if (entry != null) {
      children.add(
        _action(
          'Remove from watchlist',
          Icons.bookmark_remove_outlined,
          _busy == null ? () => _remove(entry) : null,
        ),
      );
    }
    if (!_watched && history != null) {
      children.add(
        _action(
          'Mark watched',
          Icons.check_circle_outline,
          _busy == null ? _markWatched : null,
        ),
      );
    }
    if (_blocked) {
      children.add(_status('Never recommend · undo in Profile'));
    } else if (profile != null) {
      children.add(
        _action(
          'Never recommend',
          Icons.block_outlined,
          _busy == null ? _block : null,
        ),
      );
    }
    if (_busy != null) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(10),
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          runSpacing: 0,
          children: children,
        ),
      ),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback? onPressed) =>
      TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textSoft,
          minimumSize: const Size(48, 48),
        ),
      );

  Widget _status(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: AppColors.textMuted),
    ),
  );

  Future<void> _remove(WatchlistEntry entry) async {
    setState(() => _busy = 'remove');
    try {
      final removed = await ref
          .read(watchlistControllerProvider.notifier)
          .remove(entry);
      if (!mounted) return;
      setState(() => _busy = null);
      if (!removed) return;
      setState(() => _removed = true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Removed “${entry.movie.title}”.'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                try {
                  await ref
                      .read(watchlistControllerProvider.notifier)
                      .restore(entry);
                  if (mounted) setState(() => _removed = false);
                } catch (_) {
                  if (mounted) _showFailure('put the film back');
                }
              },
            ),
          ),
        );
    } catch (error) {
      if (mounted) {
        setState(() => _busy = null);
        if (error is ApiError && error.status == 404) {
          ref.invalidate(watchlistControllerProvider);
          setState(() => _removed = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This film was already removed.')),
          );
        } else {
          _showFailure('remove the film');
        }
      }
    }
  }

  Future<void> _markWatched() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Mark watched?'),
        content: const Text(
          'This records a past viewing with an unknown date and no rating. It will leave your active watchlist.',
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
    if (accepted != true || !mounted) return;
    setState(() => _busy = 'watched');
    try {
      await ref.read(historyRepositoryProvider)!.recordManual(widget.tmdbId);
      if (!mounted) return;
      ref.read(inventoryRevisionProvider.notifier).bump();
      setState(() {
        _busy = null;
        _watched = true;
        _removed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to watched history.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _busy = null);
        _showFailure('mark the film watched');
      }
    }
  }

  Future<void> _block() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Never recommend this film?'),
        content: const Text(
          'Cinemé will skip it in future picks. You can undo this in Profile. The film stays in your watchlist.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Never recommend'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = 'block');
    try {
      await ref.read(profileRepositoryProvider)!.block(widget.tmdbId);
      if (!mounted) return;
      ref.read(inventoryRevisionProvider.notifier).bump();
      ref.invalidate(profileProvider);
      setState(() {
        _busy = null;
        _blocked = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This film won’t be recommended.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _busy = null);
        _showFailure('block the film');
      }
    }
  }

  void _showFailure(String action) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text("Couldn't $action. Try again.")));
}

class InvalidMovieDetailsPage extends StatelessWidget {
  const InvalidMovieDetailsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Movie details')),
    body: const EmptyState(
      title: 'Movie not found',
      message: 'This movie link is invalid or out of date.',
    ),
  );
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({this.width = double.infinity, this.height = 12});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(6),
    ),
  );
}
