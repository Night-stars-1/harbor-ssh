import 'package:flutter/material.dart';

import 'theme.dart';

class SidebarNavigationItem extends StatelessWidget {
  const SidebarNavigationItem({
    super.key,
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.count = '',
    this.collapsed = false,
    this.bottomSpacing = 0,
  });
  final IconData icon;
  final String title, count;
  final bool selected, collapsed;
  final VoidCallback onTap;
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Semantics(
        label: collapsed ? title : null,
        selected: selected,
        button: true,
        child: Material(
          animationDuration: HarborMotion.effects(context),
          color: selected ? colors.secondaryContainer : Colors.transparent,
          shape: HarborShapes.pill,
          child: InkWell(
            customBorder: HarborShapes.pill,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 24,
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                    ),
                    if (!collapsed) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: selected
                                    ? colors.onSecondaryContainer
                                    : colors.onSurface,
                              ),
                        ),
                      ),
                      if (count.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          count,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: selected
                                    ? colors.onSecondaryContainer
                                    : colors.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
