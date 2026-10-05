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

/// Cinemé logo and wordmark, with a single accessible brand label.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    label: 'Cinemé',
    child: ExcludeSemantics(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/branding/cineme-icon.png',
                width: 36,
                height: 36,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(width: 10),
            Text.rich(
              const TextSpan(
                text: 'Cine',
                children: [
                  TextSpan(
                    text: 'mé',
                    style: TextStyle(color: AppColors.accent),
                  ),
                ],
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      ),
    ),
  );
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
