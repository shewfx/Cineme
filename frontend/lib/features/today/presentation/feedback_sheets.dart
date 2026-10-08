import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/choice_pill.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../core/widgets/rating_stars.dart';
import '../../../core/widgets/selector_field.dart';
import '../../../shared/models/series.dart';
import '../../../shared/models/session_context.dart';
import '../../../shared/models/today_state.dart';
import '../../../shared/models/viewing.dart';
import 'today_widgets.dart';

/// Lightweight reasons (FRONTEND_SPEC). Both skips map to `not_tonight`.
const sheetReasons = <(String, RejectReason)>[
  ('Not feeling this one', RejectReason.notTonight),
  ('Too long', RejectReason.tooLong),
  ('Something lighter', RejectReason.wantLighter),
  ('Different genre', RejectReason.wrongGenre),
  ('Already watched', RejectReason.alreadyWatched),
  ('Just give me another', RejectReason.notTonight),
];

class RejectRequest {
  const RejectRequest({
    required this.reason,
    required this.chooseAnother,
    this.maxRuntimeMinutes,
    this.avoidGenreIds = const {},
  });

  final RejectReason reason;
  final bool chooseAnother;
  final int? maxRuntimeMinutes;
  final Set<int> avoidGenreIds;
}

Future<RejectRequest?> showRejectSheet(
  BuildContext context, {
  required TitleInfo movie,
  required SessionContext tonight,
  required int rejectionCount,
  bool episode = false,
}) => showModalBottomSheet<RejectRequest>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (_) => _RejectSheet(
    movie: movie,
    tonight: tonight,
    rejectionCount: rejectionCount,
    // An episode can't be "already watched" here: that would move progress
    // silently. Set my progress is the honest way to say it.
    reasons: [
      for (final r in sheetReasons)
        if (!(episode && r.$2 == RejectReason.alreadyWatched)) r,
    ],
  ),
);

class _RejectSheet extends StatefulWidget {
  const _RejectSheet({
    required this.movie,
    required this.tonight,
    required this.rejectionCount,
    required this.reasons,
  });

  final TitleInfo movie;
  final SessionContext tonight;
  final int rejectionCount;
  final List<(String, RejectReason)> reasons;

  @override
  State<_RejectSheet> createState() => _RejectSheetState();
}

class _RejectSheetState extends State<_RejectSheet> {
  int? _choice;
  int? _shorterCap;
  final _avoid = <int>{};

  RejectReason? get _reason =>
      _choice == null ? null : widget.reasons[_choice!].$2;

  bool get _valid =>
      _reason != null &&
      (_reason != RejectReason.wrongGenre || _avoid.isNotEmpty);

  void _stop() => _reason == null
      ? Navigator.pop(
          context,
          const RejectRequest(
            reason: RejectReason.notTonight,
            chooseAnother: false,
          ),
        )
      : _submit(false);

  void _submit(bool chooseAnother) => Navigator.pop(
    context,
    RejectRequest(
      reason: _reason!,
      chooseAnother: chooseAnother,
      maxRuntimeMinutes: _reason == RejectReason.tooLong ? _shorterCap : null,
      avoidGenreIds: _reason == RejectReason.wrongGenre
          ? {..._avoid}
          : const {},
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cap = widget.tonight.maxRuntimeMinutes;
    final note = switch (_reason) {
      RejectReason.notTonight =>
        'Skips it for tonight only. It stays in your watchlist.',
      RejectReason.tooLong => null,
      RejectReason.wantLighter => 'Sets tonight to “Relaxing” and asks for lighter films where tone is known.',
      RejectReason.wrongGenre => null,
      RejectReason.alreadyWatched => "Records it as seen before, date unknown. It won't count as tonight's movie.",
      _ => null,
    };
    Widget pills(List<Widget> children) =>
        Wrap(spacing: 8, runSpacing: 8, children: children);

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text('Not this one?', style: text.titleLarge),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick a reason, or just stop for tonight. Nothing here changes your long-term taste.',
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            // One dropdown in the app's option-sheet style. Choosing a reason
            // never submits: Show another does.
            SelectorField(
              label: 'Reason',
              value: _choice == null
                  ? 'Select a reason'
                  : widget.reasons[_choice!].$1,
              onTap: () async {
                final picked = await showOptionSheet<int>(
                  context,
                  title: 'Reason',
                  options: [
                    for (var i = 0; i < widget.reasons.length; i++)
                      (i, widget.reasons[i].$1),
                  ],
                  selected: _choice,
                );
                final index = picked?.$1;
                if (index != null && index != _choice) {
                  setState(() {
                    _choice = index;
                    // Details belong to one reason; start clean for the next.
                    _shorterCap = null;
                    _avoid.clear();
                  });
                }
              },
            ),
            if (_reason == RejectReason.tooLong) ...[
              const SizedBox(height: 20),
              const SectionLabel(
                'Shorter limit for tonight?',
                note: 'Optional',
              ),
              const SizedBox(height: 10),
              pills([
                ChoicePill(
                  label: cap == null ? 'Keep no limit' : 'Keep my limit',
                  selected: _shorterCap == null,
                  onTap: () => setState(() => _shorterCap = null),
                ),
                for (final (minutes, label) in runtimeOptions)
                  if (minutes != null && (cap == null || minutes < cap))
                    ChoicePill(
                      label: label,
                      selected: _shorterCap == minutes,
                      onTap: () => setState(() => _shorterCap = minutes),
                    ),
              ]),
            ],
            if (_reason == RejectReason.wrongGenre) ...[
              const SizedBox(height: 20),
              const SectionLabel('Avoid tonight', note: 'Choose at least one'),
              const SizedBox(height: 10),
              pills([
                for (final g in widget.movie.genres)
                  ChoicePill(
                    label: g.name,
                    selected: _avoid.contains(g.id),
                    onTap: () => setState(
                      () => _avoid.contains(g.id)
                          ? _avoid.remove(g.id)
                          : _avoid.add(g.id),
                    ),
                  ),
              ]),
            ],
            if (note != null) ...[
              const SizedBox(height: 16),
              Text(
                note,
                style: text.bodyMedium?.copyWith(color: AppColors.textSoft),
              ),
            ],
            if (widget.rejectionCount + 1 >= 3) ...[
              const SizedBox(height: 12),
              Text(
                widget.rejectionCount + 1 == 3
                    ? "That's your third pass tonight, so Cinemé will pause instead of picking again."
                    : "That's pass ${widget.rejectionCount + 1} tonight, so Cinemé will pause instead of picking again.",
                style: text.labelMedium?.copyWith(color: AppColors.textMuted),
              ),
            ],
            const SizedBox(height: 24),
            PrimaryAction(
              label: 'Show another',
              disabledHint: 'Choose a reason first',
              onPressed: _valid ? () => _submit(true) : null,
            ),
            const SizedBox(height: 4),
            // Separate from the reason: stopping needs none. With a reason
            // chosen it is recorded as before; without one it is a plain
            // "not tonight" (temporary, never a dislike).
            Center(
              child: TextButton(
                onPressed: _reason == null || _valid ? () => _stop() : null,
                child: const Text('Stop for tonight'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared whole-star selector; clearing remains an explicit sheet action.
class RatingSelector extends StatelessWidget {
  const RatingSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final Rating? value;
  final ValueChanged<Rating?>? onChanged;

  @override
  Widget build(BuildContext context) => FiveStarSelector(
    value: value,
    onChanged: (rating) => onChanged?.call(rating),
  );
}

Future<(bool, Rating?)?> showRatingSheet(
  BuildContext context, {
  required TitleInfo movie,
  required Rating? current,
}) => showModalBottomSheet<(bool, Rating?)>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (_) => _EditRatingSheet(movie: movie, current: current),
);

class _EditRatingSheet extends StatefulWidget {
  const _EditRatingSheet({required this.movie, required this.current});
  final TitleInfo movie;
  final Rating? current;

  @override
  State<_EditRatingSheet> createState() => _EditRatingSheetState();
}

class _EditRatingSheetState extends State<_EditRatingSheet> {
  late Rating? _rating = widget.current;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.movie.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          RatingSelector(
            value: _rating,
            onChanged: (value) => setState(() => _rating = value),
          ),
          const SizedBox(height: 20),
          PrimaryAction(
            label: 'Save rating',
            disabledHint: 'Choose a star rating first',
            onPressed: _rating == null
                ? null
                : () => Navigator.pop(context, (true, _rating)),
          ),
          if (widget.current != null)
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context, (true, null)),
                child: const Text('Clear rating'),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Confirms tonight's completion. Rating is optional and separate.
Future<(bool, Rating?)?> showMarkWatchedSheet(
  BuildContext context,
  TitleInfo movie, {
  String? subject,
  bool completesTonight = true,
}) => showModalBottomSheet<(bool, Rating?)>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (_) => _MarkWatchedSheet(
    subject: subject ?? '“${movie.title}”',
    completesTonight: completesTonight,
  ),
);

class _MarkWatchedSheet extends StatefulWidget {
  const _MarkWatchedSheet({
    required this.subject,
    required this.completesTonight,
  });

  final String subject;
  final bool completesTonight;

  @override
  State<_MarkWatchedSheet> createState() => _MarkWatchedSheetState();
}

class _MarkWatchedSheetState extends State<_MarkWatchedSheet> {
  Rating? _rating;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Mark ${widget.subject} as watched?',
                style: text.titleLarge,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.completesTonight
                  ? 'This completes tonight. Rating is optional and you can change it later.'
                  : 'Rating is optional and you can change it later.',
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            RatingSelector(
              value: _rating,
              onChanged: (r) => setState(() => _rating = r),
            ),
            const SizedBox(height: 24),
            PrimaryAction(
              label: 'Mark watched',
              onPressed: () => Navigator.pop(context, (true, _rating)),
            ),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Not yet'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
