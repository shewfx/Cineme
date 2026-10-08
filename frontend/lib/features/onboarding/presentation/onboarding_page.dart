import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/primary_action.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/auth_repository.dart';
import '../../search/presentation/search_page.dart';
import '../../today/presentation/today_widgets.dart';
import '../../watchlist/application/watchlist_controller.dart';

/// How many films the nudge suggests. Never a requirement.
const onboardingSuggestedFilms = 5;

enum _Step { welcome, add }

/// First-run screen for a new account (shown while the server says
/// onboarding is incomplete). Skip and Continue both complete it; leaving
/// without either does not, so it is shown again on the next launch or
/// device. Films are saved by the normal search/add path as they are added.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  _Step? _step;
  bool _busy = false;
  bool _failed = false;

  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      // On success the gate leaves onboarding and the router opens Tonight.
      await ref.read(onboardingDoneProvider.notifier).complete();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(watchlistControllerProvider);
    if (_step == null) {
      // Resume: films already saved (this or another device) skip the intro.
      if (list.isLoading && !list.hasValue) {
        return Scaffold(
          body: Center(
            child: Semantics(
              label: 'Loading',
              child: const CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        );
      }
      _step = list.value?.items.isNotEmpty == true ? _Step.add : _Step.welcome;
    }
    final count = list.value?.items.length;
    final more = list.value?.hasMore ?? false;
    return PopScope(
      // Back from the add step returns to the intro; it never completes
      // onboarding or opens Tonight.
      canPop: _step == _Step.welcome,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _step = _Step.welcome);
      },
      child: switch (_step!) {
        _Step.welcome => _Welcome(
          busy: _busy,
          failed: _failed,
          onAdd: () => setState(() => _step = _Step.add),
          onSkip: _finish,
        ),
        _Step.add => _AddFilms(
          busy: _busy,
          failed: _failed,
          count: count,
          more: more,
          onRetryCount: () => ref.invalidate(watchlistControllerProvider),
          onFinish: _finish,
        ),
      },
    );
  }
}

class _SignOutButton extends ConsumerWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    onPressed: () => ref.read(authRepositoryProvider)!.signOut(),
    child: const Text('Sign out'),
  );
}

const _failedMessage =
    "Couldn't save that. Check your connection and try again.";

class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.busy,
    required this.failed,
    required this.onAdd,
    required this.onSkip,
  });

  final bool busy;
  final bool failed;
  final VoidCallback onAdd;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const Wordmark(),
            const SizedBox(height: 40),
            Semantics(
              header: true,
              child: Text(
                'One pick. No scrolling.',
                style: text.headlineMedium,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Tell Cinemé what you want from tonight and how much time you '
              'have, and it picks one film from your own watchlist.',
              style: text.bodyLarge?.copyWith(color: AppColors.textSoft),
            ),
            const SizedBox(height: 12),
            Text(
              'First, add a few films you have been meaning to watch. Five is a '
              'good start, but nothing is required.',
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            const Center(child: _SignOutButton()),
          ],
        ),
      ),
      // Pinned, so the choices stay reachable at large text sizes.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _failedMessage,
                    style: text.bodyMedium?.copyWith(color: AppColors.accent),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              PrimaryAction(
                label: 'Add movies',
                compact: true,
                onPressed: busy ? null : onAdd,
              ),
              TextButton(
                onPressed: busy ? null : onSkip,
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddFilms extends StatelessWidget {
  const _AddFilms({
    required this.busy,
    required this.failed,
    required this.count,
    required this.more,
    required this.onRetryCount,
    required this.onFinish,
  });

  final bool busy;
  final bool failed;

  /// Films on the server-side watchlist; null while unknown.
  final int? count;
  final bool more;
  final VoidCallback onRetryCount;
  final VoidCallback onFinish;

  String _progress(int n) {
    final shown = more ? '$n+' : '$n';
    if (n == 0) return 'Nothing is required. Five is a good start.';
    if (n < onboardingSuggestedFilms) {
      return '$shown ${n == 1 ? 'film' : 'films'} added. Five is a good start.';
    }
    return "$shown films added. That's a good start. You can add more any time.";
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final n = count;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Scrolls inside its share of the screen at very large text so the
            // search results always keep room.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                'Add films you want to watch',
                                style: text.titleLarge,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: busy ? null : onFinish,
                            child: const Text('Skip'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        // Announced when it changes, so adding by screen reader is
                        // confirmed without hunting for the counter.
                        child: Semantics(
                          liveRegion: true,
                          child: n == null
                              ? TextButton(
                                  onPressed: onRetryCount,
                                  child: const Text(
                                    "Couldn't load your list. Retry",
                                  ),
                                )
                              : Text(
                                  _progress(n),
                                  style: text.bodyMedium?.copyWith(
                                    color: AppColors.textMuted,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Expanded(
              flex: 3,
              child: SearchPanel(mode: SearchMode.onboarding, autofocus: false),
            ),
          ],
        ),
      ),
      // A Scaffold bottom bar, so snack bars (Added / couldn't add) float
      // above Continue instead of covering it.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _failedMessage,
                    style: text.bodyMedium?.copyWith(color: AppColors.accent),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              PrimaryAction(
                label: 'Continue',
                compact: true,
                loading: busy,
                onPressed: onFinish,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
