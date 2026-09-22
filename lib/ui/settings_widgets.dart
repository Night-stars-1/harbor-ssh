import 'package:flutter/material.dart';

import 'theme.dart';

void showSettingsNotice(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 480;
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: SettingsNotice(message: message, error: error),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: Colors.transparent,
        padding: EdgeInsets.zero,
        width: wide ? 440 : null,
        margin: wide ? null : const EdgeInsets.all(16),
      ),
    );
}

/// Rounded transient notice used for settings feedback.
///
/// [showSettingsNotice] hosts it in a snack bar. Callers that cannot use a
/// scaffold — dialogs render above one, so a snack bar would sit behind them —
/// place it in the navigator overlay instead.
class SettingsNotice extends StatelessWidget {
  const SettingsNotice({
    super.key,
    required this.message,
    this.error = false,
  });
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onPrimaryContainer;
    return Center(
      heightFactor: 1,
      child: Material(
        color: error ? colors.errorContainer : colors.primaryContainer,
        shape: HarborShapes.superellipse(BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                error
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 22,
                color: foreground,
                semanticLabel: error ? '错误' : '成功',
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      ),
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: HarborShapes.listGap),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: HarborShapes.superellipse(
            HarborShapes.listItem(HarborShapes.listSlot(i, children.length)),
          ),
          clipBehavior: Clip.antiAlias,
          child: children[i],
        ),
      ],
    ],
  );
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.description,
    required this.control,
    this.inline = false,
  });
  final String title;
  final String? description;
  final Widget control;
  final bool inline;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final label = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(
                description!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
        if (inline) {
          return Row(
            children: [
              Expanded(child: label),
              const SizedBox(width: 16),
              control,
            ],
          );
        }
        if (constraints.maxWidth >= 480) {
          return Row(
            children: [
              SizedBox(width: 156, child: label),
              const SizedBox(width: 20),
              Expanded(child: control),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [label, const SizedBox(height: 12), control],
        );
      },
    ),
  );
}

class SettingsList extends StatelessWidget {
  const SettingsList({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}
