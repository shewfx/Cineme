import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A compact labelled field showing the current choice; tapping opens
/// [showOptionSheet]. Replaces walls of chips where space is tight.
class SelectorField extends StatelessWidget {
  const SelectorField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.note,
  });

  final String label;
  final String value;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            Text(label, style: text.titleSmall),
            if (note != null)
              Text(
                note!,
                style: text.labelMedium?.copyWith(color: AppColors.textMuted),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: '$label: $value',
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(value, style: text.bodyLarge)),
                  const Icon(Icons.expand_more, color: AppColors.textMuted),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Vertical option list in a bottom sheet; the current value is checked and
/// choosing closes the sheet. Returns a record so a chosen null ("Not set",
/// "Any length") differs from dismissing (null).
Future<(T?,)?> showOptionSheet<T>(
  BuildContext context, {
  required String title,
  required List<(T?, String)> options,
  required T? selected,
}) => showModalBottomSheet<(T?,)>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  showDragHandle: true,
  builder: (sheet) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheet).height * 0.85,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(title, style: Theme.of(sheet).textTheme.titleLarge),
            ),
          ),
          for (final (value, label) in options)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              title: Text(label),
              selected: value == selected,
              selectedColor: AppColors.accent,
              trailing: value == selected
                  ? const Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(sheet, (value,)),
            ),
        ],
      ),
    ),
  ),
);
