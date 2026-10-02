import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/choice_pill.dart';
import '../../../core/widgets/primary_action.dart';
import '../../../shared/models/movie.dart';
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
  ('Already seen', RejectReason.alreadyWatched),
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
  required Movie movie,
  required SessionContext tonight,
  required int rejectionCount,
  bool includeAlreadySeen = true,
}) => showModalBottomSheet<RejectRequest>(
  context: context,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (_) => _RejectSheet(
    movie: movie,
    tonight: tonight,
    rejectionCount: rejectionCount,
    // Already seen records viewing history, which arrives in P5.
    reasons: [
      for (final r in sheetReasons)
        if (includeAlreadySeen || r.$2 != RejectReason.alreadyWatched) r,
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

  final Movie movie;
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
              'Pick a reason. Nothing here changes your long-term taste.',
              style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            pills([
              for (var i = 0; i < widget.reasons.length; i++)
                ChoicePill(
                  label: widget.reasons[i].$1,
                  selected: _choice == i,
                  onTap: () => setState(() => _choice = i),
                ),
            ]),
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
                "That's your third pass tonight, so Cinemé will pause instead of picking again.",
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
            Center(
              child: TextButton(
                onPressed: _valid ? () => _submit(false) : null,
                child: const Text('Stop for tonight'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Four labelled buttons; tapping the selected one clears it. Not stars.
class RatingSelector extends StatelessWidget {
  const RatingSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final Rating? value;
  final ValueChanged<Rating?>? onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final r in Rating.values)
        ChoicePill(
          label: r.label,
          selected: value == r,
          onTap: () => onChanged?.call(value == r ? null : r),
        ),
    ],
  );
}

/// Confirms tonight's completion. Rating is optional and separate.
Future<(bool, Rating?)?> showMarkWatchedSheet(
  BuildContext context,
  Movie movie,
) => showModalBottomSheet<(bool, Rating?)>(
  context: context,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (_) => _MarkWatchedSheet(movie: movie),
);

class _MarkWatchedSheet extends StatefulWidget {
  const _MarkWatchedSheet({required this.movie});

  final Movie movie;

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
                'Mark “${widget.movie.title}” as watched?',
                style: text.titleLarge,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'This completes tonight. Rating is optional and you can change it later.',
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
