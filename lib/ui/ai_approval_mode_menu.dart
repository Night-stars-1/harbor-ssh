import 'package:flutter/material.dart';

import '../data/terminal_ai.dart';
import 'theme.dart';

IconData aiApprovalIcon(AiApprovalMode mode) => switch (mode) {
  AiApprovalMode.auto => Icons.verified_user_rounded,
  AiApprovalMode.readOnly => Icons.visibility_outlined,
  AiApprovalMode.manual => Icons.gpp_maybe_outlined,
};

ButtonStyle aiMenuItemStyle(BuildContext context, {bool selected = false}) {
  final colors = Theme.of(context).colorScheme;
  return MenuItemButton.styleFrom(
    minimumSize: const Size(0, 48),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.sm)),
    backgroundColor: selected ? colors.secondaryContainer : null,
    foregroundColor: selected ? colors.onSecondaryContainer : null,
  );
}

/// Approval-mode menu shared by the AI panel and the AI settings page; each
/// caller supplies its own trigger through [builder].
class AiApprovalModeMenu extends StatelessWidget {
  const AiApprovalModeMenu({
    super.key,
    required this.mode,
    required this.onSelected,
    required this.builder,
    this.controller,
  });
  final AiApprovalMode mode;
  final ValueChanged<AiApprovalMode> onSelected;
  final MenuAnchorChildBuilder builder;
  final MenuController? controller;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: controller,
    alignmentOffset: const Offset(0, 4),
    menuChildren: [
      for (final item in AiApprovalMode.values)
        MenuItemButton(
          style: aiMenuItemStyle(context, selected: mode == item),
          leadingIcon: Icon(
            mode == item ? Icons.check_rounded : aiApprovalIcon(item),
            size: 18,
          ),
          onPressed: () => onSelected(item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.label),
              Text(
                item.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
    ],
    builder: builder,
  );
}
