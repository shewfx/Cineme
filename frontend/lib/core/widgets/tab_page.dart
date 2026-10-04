import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Header (title, optional muted subtitle and action) above a tab's content.
class TabPage extends StatelessWidget {
  const TabPage({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    // One line even at large text sizes, so header actions
                    // never push the content off small screens.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        header: true,
                        child: Text(title, style: text.headlineMedium),
                      ),
                    ),
                  ),
                  ?action,
                ],
              ),
            ),
            if (subtitle != null)
              // Full width under the title row, so a row of header actions
              // never squeezes it into a narrow column.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                child: Text(
                  subtitle!,
                  style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
