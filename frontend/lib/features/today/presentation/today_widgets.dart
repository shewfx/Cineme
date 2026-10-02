import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Optional time choices; values are inclusive caps (PROJECT_SPEC: "under two
/// hours" -> 119). Null is no limit.
const runtimeOptions = <(int?, String)>[
  (null, 'Any length'),
  (90, 'Up to 90 min'),
  (119, 'Under 2 hours'),
  (150, 'Up to 2½ hours'),
];

String runtimeCapLabel(int? cap) => runtimeOptions
    .firstWhere((o) => o.$1 == cap, orElse: () => (cap, 'Up to $cap min'))
    .$2;

/// Small wordmark; the accent sits only on the final é.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    label: 'Cinemé',
    child: ExcludeSemantics(
      child: Text.rich(
        const TextSpan(
          text: 'Cinem',
          children: [
            TextSpan(
              text: 'é',
              style: TextStyle(color: AppColors.accent),
            ),
          ],
        ),
        style: Theme.of(context).textTheme.titleLarge,
      ),
    ),
  );
}

/// Tactile single-choice option. Selection is shown by coral border, tint and
/// a check icon, so it never relies on colour alone.
class ChoicePill extends StatelessWidget {
  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? AppColors.accent.withValues(alpha: 0.14)
            : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.chip),
          side: BorderSide(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.chip),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        height: 1.2,
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Quiet section heading with an optional muted note on the same line.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.title, {super.key, this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Text.rich(
      TextSpan(
        text: title,
        children: [
          if (note != null)
            TextSpan(
              text: '   $note',
              style: text.labelMedium?.copyWith(color: AppColors.textMuted),
            ),
        ],
      ),
      style: text.titleMedium,
    );
  }
}
