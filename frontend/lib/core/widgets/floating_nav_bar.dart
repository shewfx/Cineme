import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class NavTab {
  const NavTab({required this.label, required this.icon, this.selectedIcon});

  final String label;
  final IconData icon;
  final IconData? selectedIcon;
}

/// The floating capsule: four icon-only tabs, evenly spaced, the selected one
/// in a coral pill around its icon. No visible text and no expansion, so the
/// capsule never changes with the selection. Sizing is plain layout (no
/// transforms), so what is drawn is what is touched. Every tab keeps its
/// semantic label, a tooltip and a target of at least 48 px.
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

  /// The capsule is a compact control, not a full-width bar: at most this
  /// wide on every screen, shrinking only on very narrow phones.
  static const double maxWidth = 316;
  static const double _padding = 8;
  static const double _slotWidth = 60;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(_padding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Equal slots with equal gaps (ends included); slots only shrink
          // when a very narrow screen leaves less room, never below 48 px.
          final slot = math.max(
            itemHeight,
            math.min(_slotWidth, constraints.maxWidth / tabs.length),
          );
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < tabs.length; i++)
                SizedBox(
                  width: slot,
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
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Tooltip(
        message: tab.label,
        excludeFromSemantics: true,
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
            child: SizedBox(
              height: FloatingNavBar.itemHeight,
              child: Center(
                child: Icon(
                  selected ? (tab.selectedIcon ?? tab.icon) : tab.icon,
                  color: selected ? AppColors.accent : AppColors.textMuted,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
