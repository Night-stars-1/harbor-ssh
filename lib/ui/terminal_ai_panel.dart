import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ai_task_controller.dart';
import 'theme.dart';

class TerminalAiPanel extends StatefulWidget {
  const TerminalAiPanel({
    super.key,
    required this.task,
    required this.hostName,
    this.onSettings,
  });
  final AiTaskController task;
  final String hostName;
  final VoidCallback? onSettings;
  @override
  State<TerminalAiPanel> createState() => _TerminalAiPanelState();
}

class _TerminalAiPanelState extends State<TerminalAiPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _scrollQueued = false;

  @override
  void initState() {
    super.initState();
    widget.task.addListener(_changed);
  }

  void _changed() {
    if (_scrollQueued ||
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset > 80) {
      return;
    }
    _scrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollQueued = false;
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    widget.task.removeListener(_changed);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _start() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.task.start(text);
  }

  Widget _entry(AiTaskEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: entry.command
            ? colors.surfaceContainerHighest
            : colors.surfaceContainerLow,
        shape: HarborShapes.superellipse(BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (entry.command) ...[
                Row(
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 18,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.reason ?? '执行命令',
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              SelectableText(
                entry.text,
                style: entry.command
                    ? theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      )
                    : theme.textTheme.bodyMedium,
              ),
              if (entry.output.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      entry.output,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
              if (entry.finished) ...[
                const SizedBox(height: 8),
                Text(
                  entry.exitCode == null ? '未收到退出码' : '退出码 ${entry.exitCode}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: entry.exitCode == 0 ? colors.primary : colors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      alignment: size.width >= 900 ? Alignment.centerRight : Alignment.center,
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: colors.surfaceContainer,
      child: SizedBox(
        width: 480,
        height: math.min(760, size.height - 32),
        child: ListenableBuilder(
          listenable: widget.task,
          builder: (context, _) {
            final task = widget.task;
            final configured = task.settings().configured;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, color: colors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'AI 任务',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              widget.hostName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.close_rounded,
                          semanticLabel: '关闭 AI 面板',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!configured)
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '先在设置 → AI 配置模型服务',
                              textAlign: TextAlign.center,
                            ),
                            if (widget.onSettings != null) ...[
                              const SizedBox(height: 16),
                              FilledButton.tonal(
                                onPressed: () {
                                  Navigator.pop(context);
                                  widget.onSettings!();
                                },
                                child: const Text('打开设置'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  else ...[
                    Expanded(
                      child: task.entries.isEmpty
                          ? Center(
                              child: Text(
                                '例如：检查磁盘空间，找出占用最大的目录',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              itemCount: task.entries.length,
                              itemBuilder: (_, index) =>
                                  _entry(task.entries[index]),
                            ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      task.failure ?? task.status,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: task.failure == null
                            ? colors.onSurfaceVariant
                            : colors.error,
                      ),
                    ),
                    if (task.pending != null) ...[
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(task.pending!.reason),
                              const SizedBox(height: 8),
                              SelectableText(
                                task.pending!.command,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => task.approve(false),
                            child: const Text('取消任务'),
                          ),
                          FilledButton.tonal(
                            onPressed: () => task.approve(true),
                            child: const Text('批准并执行'),
                          ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('ai-task-input'),
                        controller: _input,
                        enabled: !task.running,
                        minLines: 1,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: '描述要在这台服务器上完成的任务',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: task.running
                            ? FilledButton.tonalIcon(
                                onPressed: task.stop,
                                icon: const Icon(Icons.stop_rounded, size: 18),
                                label: const Text('停止'),
                              )
                            : FilledButton.icon(
                                onPressed: _start,
                                icon: const Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 18,
                                ),
                                label: const Text('开始任务'),
                              ),
                      ),
                    ],
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
