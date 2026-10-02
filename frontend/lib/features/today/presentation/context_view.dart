import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/choice_pill.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../application/today_controller.dart';
import 'today_widgets.dart';

enum ContextMode {
  /// No session yet today.
  initial,

  /// A session exists without a pick (after Stop or a context change).
  ready,

  /// Edit tonight: Save or Pick with this context; back cancels.
  edit,
}

/// Desired experience (required), mood and time (optional), kept separate.
class ContextView extends ConsumerStatefulWidget {
  const ContextView({super.key, this.mode = ContextMode.initial, this.today});

  final ContextMode mode;

  /// The current envelope, used to seed the draft from saved context.
  final TodayEnvelope? today;

  @override
  ConsumerState<ContextView> createState() => _ContextViewState();
}

class _ContextViewState extends ConsumerState<ContextView> {
  String? _notice;

  /// Set once Save or Pick succeeds; leaving otherwise discards the edit.
  bool _committed = false;

  @override
  void initState() {
    super.initState();
    final saved = widget.today?.context;
    if (widget.mode != ContextMode.initial && saved != null) {
      // Seeding after the frame keeps provider writes out of build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(todayControllerProvider.notifier).seedFrom(saved);
      });
    }
  }

  TodayViewState get _draft => ref.read(todayControllerProvider);

  /// An accepted plan is only replaced after a visible confirmation.
  Future<bool> _confirmReplacingPlan() async {
    final today = widget.today;
    final draft = _draft.context;
    if (today?.state != TodayStatus.accepted ||
        draft == null ||
        today!.context!.sameScoringAs(draft)) {
      return true;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Replace tonight's plan?"),
        content: Text(
          'You planned to watch “${today.recommendation!.movie.title}”. '
          'Changing what you want from tonight clears that plan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep plan'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _pick() async {
    if (!await _confirmReplacingPlan()) return;
    final controller = ref.read(todayControllerProvider.notifier);
    final ok = await controller.pickMyMovie();
    if (!mounted) return;
    if (!ok) {
      setState(
        () => _notice = 'Change what you want from tonight to pick again, or go back and choose Continue once.',
      );
      return;
    }
    if (widget.mode == ContextMode.edit && _draft.pick is! AsyncError) {
      _committed = true;
      context.pop();
    }
  }

  Future<void> _save() async {
    if (!await _confirmReplacingPlan()) return;
    await ref.read(todayControllerProvider.notifier).saveContext();
    if (mounted && _draft.pick is! AsyncError) {
      _committed = true;
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(todayControllerProvider);
    final controller = ref.read(todayControllerProvider.notifier);
    final text = Theme.of(context).textTheme;
    final pick = state.pick;
    final edit = widget.mode == ContextMode.edit;

    Widget choices(List<Widget> children) =>
        Wrap(spacing: 8, runSpacing: 8, children: children);

    final (heading, subtitle) = switch (widget.mode) {
      ContextMode.initial => (
        'What do you want from tonight?',
        'Choose the feeling. We pick one film from your watchlist.',
      ),
      ContextMode.ready => (
        'Ready for another pick?',
        'Your choices for tonight are saved. Change anything, or pick again.',
      ),
      ContextMode.edit => (
        'Edit tonight',
        'Changing only how you feel keeps tonight’s film. Changing what you want or your time clears it.',
      ),
    };
    final avoided = state.carried?.avoidGenreIds ?? const <int>{};

    final content = <Widget>[
      if (!edit) ...[const Wordmark(), const SizedBox(height: 40)],
      Semantics(header: true, child: Text(heading, style: text.headlineMedium)),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
      ),
      const SizedBox(height: 24),
      choices([
        for (final intent in DesiredExperience.values)
          ChoicePill(
            label: intent.label,
            selected: state.desiredExperience == intent,
            onTap: () => controller.selectDesiredExperience(intent),
          ),
      ]),
      const SizedBox(height: 32),
      const SectionLabel(
        'How are you feeling?',
        note: 'Optional · never decides the pick',
      ),
      const SizedBox(height: 12),
      choices([
        for (final mood in CurrentMood.values)
          ChoicePill(
            label: mood.label,
            selected: state.currentMood == mood,
            onTap: () => controller.toggleMood(mood),
          ),
      ]),
      // Feeling down offers the documented follow-ups; none is preselected.
      if (state.currentMood == CurrentMood.down &&
          state.desiredExperience == null) ...[
        const SizedBox(height: 20),
        Text(
          'What would help tonight?',
          style: text.bodyMedium?.copyWith(color: AppColors.textSoft),
        ),
        const SizedBox(height: 10),
        choices([
          for (final (label, intent) in downFollowUps)
            ChoicePill(
              label: label,
              selected: false,
              onTap: () => controller.selectDesiredExperience(intent),
            ),
        ]),
      ],
      const SizedBox(height: 28),
      const SectionLabel('How much time?', note: 'Optional'),
      const SizedBox(height: 12),
      choices([
        for (final (minutes, label) in runtimeOptions)
          ChoicePill(
            label: label,
            selected: state.maxRuntimeMinutes == minutes,
            onTap: () => controller.selectMaxRuntime(minutes),
          ),
      ]),
      if (avoided.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text(
          'Also avoiding ${avoided.length == 1 ? 'one genre' : '${avoided.length} genres'} tonight, from an earlier pass.',
          style: text.labelMedium?.copyWith(color: AppColors.textMuted),
        ),
      ],
    ];

    final actions = Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_notice != null || pick is AsyncError) ...[
            Text(
              _notice ??
                  "Couldn't reach Cinemé. Your choices are kept; try again.",
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 10),
          ],
          if (edit) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: state.canPick ? _save : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.text,
                  side: const BorderSide(color: AppColors.border),
                  minimumSize: const Size.fromHeight(52),
                ),
                child: state.busy == TodayAction.save
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('Save'),
              ),
            ),
            const SizedBox(height: 10),
          ],
          PrimaryAction(
            label: edit ? 'Pick with this context' : 'Pick my movie',
            disabledHint: 'Choose what you want from tonight first',
            loading: state.busy == TodayAction.pick,
            onPressed: state.canPick ? _pick : null,
          ),
        ],
      ),
    );

    // Large text on a short screen: the buttons scroll with the choices
    // instead of pinning over them.
    final inline =
        MediaQuery.textScalerOf(context).scale(1) > 1.3 &&
        MediaQuery.sizeOf(context).height < 760;

    final scaffold = Scaffold(
      appBar: edit
          ? AppBar(
              backgroundColor: AppColors.background,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
            )
          : null,
      body: SafeArea(
        child: inline
            ? SingleChildScrollView(
                padding: const EdgeInsets.only(top: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: content,
                      ),
                    ),
                    actions,
                  ],
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: content,
                      ),
                    ),
                  ),
                  actions,
                ],
              ),
      ),
    );
    if (!edit) return scaffold;
    // Back is Cancel: the saved context and tonight's pick stay as they were.
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_committed) {
          ref
              .read(todayControllerProvider.notifier)
              .seedFrom(widget.today?.context);
        }
      },
      child: scaffold,
    );
  }
}

/// `/today/context`: Edit tonight over the current envelope.
class EditTonightPage extends ConsumerWidget {
  const EditTonightPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.read(todayEnvelopeProvider).value;
    return ContextView(mode: ContextMode.edit, today: today);
  }
}
