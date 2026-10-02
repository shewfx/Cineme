import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/tab_page.dart';
import '../../../preview/preview_store.dart';
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

class _ProfileBody extends StatelessWidget {
  const _ProfileBody({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    String genres(List<Genre> g, String none) =>
        g.isEmpty ? none : g.map((x) => x.name).join(', ');
    final cap = profile.defaultMaxRuntimeMinutes;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const _Section('Account'),
        _Row('Display name', profile.displayName ?? 'Not set'),
        _Row(
          'Time zone',
          profile.timezone,
          note: profile.timezone == 'UTC'
              ? 'Default until you choose your time zone.'
              : null,
        ),
        const _Section('Recommendation preferences'),
        _Row('Preferred genres', genres(profile.preferredGenres, 'None yet')),
        _Row('Blocked genres', genres(profile.blockedGenres, 'None')),
        _Row('Default time limit', cap == null ? 'No limit' : 'Up to $cap min'),
        _Row(
          'Describe tonight in words',
          profile.aiContextEnabled ? 'On' : 'Off',
          note: 'When on, only the sentence you type is sent to the parser, never your history.',
        ),
        const _Section('Never recommend'),
        _Row(
          'Blocked films',
          profile.blockedMovies.isEmpty
              ? 'None'
              : profile.blockedMovies.map((m) => m.title).join(', '),
        ),
        const _Section('About'),
        const _Row(
          'Movie data',
          'This product uses the TMDB API but is not endorsed or certified by TMDB.',
        ),
        const _PreviewTools(),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 28, 24, 6),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: AppColors.textMuted),
      ),
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
