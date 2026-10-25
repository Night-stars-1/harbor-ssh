import 'package:flutter/material.dart';

import '../data/terminal_ai.dart';
import 'expressive_widgets.dart';
import 'settings_widgets.dart';

/// The prompt section of the AI settings page: an editable supplement that is
/// appended to the built-in, read-only prompt.
///
/// The supplement lives in [controller]. It is edited in a dialog that keeps
/// its own draft, so cancelling the dialog never touches the page. The
/// built-in prompt is always sent, so it is shown for reference but cannot be
/// edited or removed.
class AiPromptSettings extends StatefulWidget {
  const AiPromptSettings({
    super.key,
    required this.controller,
    this.enabled = true,
    this.builtinExpanded = false,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool builtinExpanded;

  @override
  State<AiPromptSettings> createState() => _AiPromptSettingsState();
}

class _AiPromptSettingsState extends State<AiPromptSettings> {
  Future<void> _edit() async {
    final next = await showExpressiveDialog<String>(
      context: context,
      builder: (context) =>
          _PromptEditorDialog(initial: widget.controller.text),
    );
    // Escape and the barrier pop with null, which leaves the supplement as is.
    if (!mounted || next == null) return;
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsGroup(
      title: '提示词',
      children: [
        SettingsRow(
          title: '默认提示词',
          inline: true,
          control: FilledButton.tonalIcon(
            key: const ValueKey('ai-setting-prompt-edit'),
            onPressed: widget.enabled ? _edit : null,
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: const Text('编辑'),
          ),
        ),
        ExpansionTile(
          key: const ValueKey('ai-setting-builtin-prompt'),
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: widget.builtinExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: const Text('查看内置提示词'),
          subtitle: const Text('内置安全与行为要求（只读）'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                aiSystemPrompt,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Edits the supplement against a private draft; only "确定" hands the text
/// back to the page. The draft controller is owned by this state so it stays
/// alive for the route's exit animation and is never disposed by the caller
/// on the other side of its `await`.
class _PromptEditorDialog extends StatefulWidget {
  const _PromptEditorDialog({required this.initial});

  final String initial;

  @override
  State<_PromptEditorDialog> createState() => _PromptEditorDialogState();
}

class _PromptEditorDialogState extends State<_PromptEditorDialog> {
  late final TextEditingController _draft = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AlertDialog sizes itself to its intrinsic content, which would make the
    // dialog jump while typing. Pin one stable width that still fits a 320px
    // screen with the dialog's own horizontal inset.
    final width = (MediaQuery.sizeOf(context).width - 80).clamp(
      200.0,
      520.0,
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('编辑默认提示词'),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: TextField(
            key: const ValueKey('ai-setting-system-prompt'),
            controller: _draft,
            autofocus: true,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '例如：回答时优先给出可回滚的操作步骤',
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('ai-setting-prompt-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('ai-setting-prompt-confirm'),
          onPressed: () => Navigator.of(context).pop(_draft.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
