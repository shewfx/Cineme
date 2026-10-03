import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Full-width coral call to action. Disabled when [onPressed] is null; shows a
/// spinner instead of the label while [loading] and ignores taps.
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.disabledHint,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  /// Read by screen readers while disabled, explaining what unlocks it.
  final String? disabledHint;

  /// A slightly shorter button for a pinned action bar.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.surface,
          disabledForegroundColor: AppColors.textMuted,
          minimumSize: Size.fromHeight(compact ? 52 : 58),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 16 : 24,
            vertical: compact ? 10 : 16,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
          // 19px bold qualifies as WCAG large text, where white-on-coral passes 3:1.
          textStyle: const TextStyle(
            fontFamily: 'Jost',
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: loading
            ? Semantics(
                label: 'Picking',
                child: const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.textMuted,
                  ),
                ),
              )
            : Text(label, textAlign: TextAlign.center),
      ),
    );
    return onPressed == null && disabledHint != null
        ? Semantics(hint: disabledHint, child: button)
        : button;
  }
}
