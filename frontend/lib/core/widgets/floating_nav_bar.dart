import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class NavTab {
  const NavTab({required this.label, required this.icon, this.selectedIcon});

  final String label;
  final IconData icon;
  final IconData? selectedIcon;
}

/// The floating pill: inactive tabs are icon-only, the active tab carries its
/// label inside a coral pill. Sizing is plain layout (no transforms), so what
/// is drawn is what is touched. Every tab keeps its semantic label, a tooltip
/// and a 48 px target even when its text is hidden.
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<NavTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double itemHeight = 48;
  static const double _maxLabelScale = 1.3;

  /// The capsule is a compact control, not a full-width bar: at most this
  /// wide on every screen, shrinking only on very narrow phones.
  static const double maxWidth = 316;
  static const double _padding = 8;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(_padding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Fixed slots: every inactive tab 48 px, and the active tab gets
          // everything else, so the shell never changes with the selection.
          final active = math.max(
            itemHeight,
            constraints.maxWidth - itemHeight * (tabs.length - 1),
          );
          return Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                SizedBox(
                  width: i == selectedIndex ? active : itemHeight,
                  child: _NavItem(
                    tab: tabs[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final NavTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textMuted;
    final icon = Icon(
      selected ? (tab.selectedIcon ?? tab.icon) : tab.icon,
      color: color,
      size: 24,
    );
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: AppColors.text,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: tab.label,
        excludeFromSemantics: true,
        // A fixed row height: Center would otherwise fill an unbounded slot.
        child: SizedBox(
          height: FloatingNavBar.itemHeight,
          child: Center(
            child: Material(
              key: ValueKey('nav-${tab.label}'),
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.16)
                  : Colors.transparent,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                customBorder: const StadiumBorder(),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: FloatingNavBar.itemHeight,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: selected ? 14 : 0,
                    ),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          icon,
                          if (selected) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              // Large text shrinks the label to fit the pill
                              // rather than overflowing it.
                              child: MediaQuery.withClampedTextScaling(
                                maxScaleFactor: FloatingNavBar._maxLabelScale,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    tab.label,
                                    maxLines: 1,
                                    softWrap: false,
                                    style: labelStyle,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
