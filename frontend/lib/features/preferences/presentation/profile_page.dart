import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../preview/preview_store.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/auth_repository.dart';
import '../../../shared/models/movie.dart';
import '../../../shared/models/profile.dart';
import '../application/profile_controller.dart';
import '../data/profile_repository.dart';

/// Read-only profile shell. Editing arrives in P3; sign-out with auth in P2.
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(profileRepositoryProvider) == null) {
      return const Scaffold(body: UnavailableView(what: 'Your profile'));
    }
    return TabPage(
      title: 'Profile',
      child: ref
          .watch(profileProvider)
          .when(
            loading: () => const SkeletonList(rows: 4),
            error: (_, _) => ListView(
              children: [
                ErrorPanel(onRetry: () => ref.invalidate(profileProvider)),
                // Keeps the switch reachable so errors can be turned off.
                const _PreviewTools(),
              ],
            ),
            data: (p) => _ProfileBody(profile: p),
          ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String genres(List<Genre> g, String none) =>
        g.isEmpty ? none : g.map((x) => x.name).join(', ');
    final cap = profile.defaultMaxRuntimeMinutes;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const _Section('Account', note: 'Editing is coming later.'),
        _Row('Display name', profile.displayName ?? 'Not set'),
        _Row(
          'Time zone',
          profile.timezone,
          note: profile.timezone == 'UTC'
              ? 'Default for now. Choosing your time zone is coming later.'
              : null,
        ),
        const _Section(
          'Recommendation preferences',
          note: 'Shown for reference. Editing is coming later.',
        ),
        _Row('Preferred genres', genres(profile.preferredGenres, 'None yet')),
        _Row('Blocked genres', genres(profile.blockedGenres, 'None')),
        _Row('Default time limit', cap == null ? 'No limit' : 'Up to $cap min'),
        const _Row(
          'Describe tonight in words',
          'Coming later',
          note:
              'Not available yet. When it arrives it will be opt-in, and only '
              'the sentence you type will be sent, never your history.',
        ),
        const _Section('Never recommend'),
        if (profile.blockedMovies == null)
          const _Row('Blocked films', 'Coming later')
        else if (profile.blockedMovies!.isEmpty)
          const _Row('Blocked films', 'None')
        else
          for (final m in profile.blockedMovies!)
            _BlockedRow(title: m.title, tmdbId: m.tmdbId),
        const _Section('About'),
        const _Row(
          'Movie data',
          'This product uses the TMDB API but is not endorsed or certified by TMDB.',
        ),
        const _PreviewTools(),
        const _AccountSection(),
      ],
    );
  }
}

/// Normal build only: who is signed in, and Sign out. Sign-out clears the
/// local session even if the network revoke fails; the router then returns
/// to sign-in and private screens rebuild for the next user.
class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authRepositoryProvider);
    final user = ref.watch(authUserProvider).value;
    if (auth == null || user == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Section('Signed in'),
        _Row('Email', user.email),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: OutlinedButton(
            onPressed: auth.signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.text,
              side: const BorderSide(color: AppColors.border),
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Sign out'),
          ),
        ),
      ],
    );
  }
}

/// Never recommend is reversible. Unblocking does not re-add the film to
/// the watchlist.
class _BlockedRow extends ConsumerStatefulWidget {
  const _BlockedRow({required this.title, required this.tmdbId});

  final String title;
  final int tmdbId;

  @override
  ConsumerState<_BlockedRow> createState() => _BlockedRowState();
}

class _BlockedRowState extends ConsumerState<_BlockedRow> {
  bool _busy = false;

  Future<void> _unblock() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(profileRepositoryProvider)!.unblock(widget.tmdbId);
      ref.invalidate(profileProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '“${widget.title}” can be recommended again once you add it back.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        const SnackBar(content: Text(connectionErrorMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 4, 12, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            widget.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        _busy
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : TextButton(
                onPressed: _unblock,
                child: Text(
                  'Unblock',
                  semanticsLabel: 'Unblock ${widget.title}',
                ),
              ),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 28, 24, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: AppColors.textMuted),
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note!,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: AppColors.textMuted),
            ),
          ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.titleMedium),
          const SizedBox(height: 2),
          Text(
            value,
            style: text.bodyMedium?.copyWith(color: AppColors.textSoft),
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note!,
              style: text.labelMedium?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Preview-build only: toggles simulated connection errors in every fake.
class _PreviewTools extends ConsumerStatefulWidget {
  const _PreviewTools();

  @override
  ConsumerState<_PreviewTools> createState() => _PreviewToolsState();
}

class _PreviewToolsState extends ConsumerState<_PreviewTools> {
  @override
  Widget build(BuildContext context) {
    final store = ref.watch(previewStoreProvider);
    if (store == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Section('Preview build'),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          activeThumbColor: AppColors.accent,
          title: const Text('Simulate connection errors'),
          subtitle: const Text(
            'Screens show their error state until you turn this off and retry.',
            style: TextStyle(color: AppColors.textMuted),
          ),
          value: store.simulateErrors,
          onChanged: (v) => setState(() => store.simulateErrors = v),
        ),
      ],
    );
  }
}
