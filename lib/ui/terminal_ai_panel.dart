import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';

import '../data/ai_image.dart';
import '../data/ai_image_input.dart';
import '../data/terminal_ai.dart';

import 'ai_task_controller.dart';
import 'theme.dart';

class TerminalAiPanel extends StatefulWidget {
  const TerminalAiPanel({
    super.key,
    required this.task,
    required this.hostName,
    this.onSettings,
    this.onClose,
    this.imageInput,
  });
  final AiTaskController task;
  final String hostName;
  final VoidCallback? onSettings;
  final VoidCallback? onClose;
  final AiImageInput? imageInput;
  @override
  State<TerminalAiPanel> createState() => _TerminalAiPanelState();
}

class _TerminalAiPanelState extends State<TerminalAiPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _scrollQueued = false;
  final _images = <AiImage>[];
  final _expandedTools = Expando<bool>();
  bool _loadingImages = false;
  bool _dragging = false;
  AiImageInput get _imageInput =>
      widget.imageInput ?? const NativeAiImageInput();

  void _notice(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error is AiFailure ? error.message : '无法读取图片，请重新选择'),
      ),
    );
  }

  void _addImage(AiImage image) {
    AiImage.validateBatch([..._images, image]);
    setState(() => _images.add(image));
  }

  Future<void> _readSources(List<AiImageSource> sources) async {
    if (sources.length + _images.length > AiImage.maxCount) {
      throw const AiFailure('每条消息最多添加 4 张图片');
    }
    final added = <AiImage>[];
    for (final source in sources) {
      final image = await source.read();
      if (!mounted || widget.task.running) return;
      added.add(image);
      AiImage.validateBatch([..._images, ...added]);
    }
    if (mounted) setState(() => _images.addAll(added));
  }

  Future<void> _loadImages(Future<void> Function() load) async {
    if (_loadingImages || widget.task.running) return;
    setState(() => _loadingImages = true);
    try {
      await load();
    } catch (error) {
      _notice(error);
    } finally {
      if (mounted) setState(() => _loadingImages = false);
    }
  }

  Future<void> _pickImages() => _loadImages(() async {
    final sources = await _imageInput.pick();
    if (mounted) await _readSources(sources);
  });

  Future<void> _paste() => _loadImages(() async {
    AiImage? image;
    try {
      image = await _imageInput.clipboard();
    } on MissingPluginException {
      // Existing app processes can keep running until native plugins are loaded
      // on the next launch. Ordinary text paste must continue to work.
      final text = await Clipboard.getData(Clipboard.kTextPlain);
      if (mounted && text?.text != null) {
        _insertText(text!.text!);
        return;
      }
      throw const AiFailure('请重启应用后使用图片粘贴');
    }
    if (!mounted) return;
    if (image != null) {
      _addImage(image);
    } else {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (mounted && data?.text != null) _insertText(data!.text!);
    }
  });

  void _insertText(String text) {
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _input.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  Stream<List<int>> _readDrop(DropItem item) async* {
    final bookmark = item.extraAppleBookmark;
    final scoped =
        bookmark != null &&
        bookmark.isNotEmpty &&
        await DesktopDrop.instance.startAccessingSecurityScopedResource(
          bookmark: bookmark,
        );
    try {
      yield* item.openRead();
    } finally {
      if (scoped) {
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(
          bookmark: bookmark,
        );
      }
    }
  }

  Widget _thumbnails(List<AiImage> images, {bool removable = false}) =>
      SizedBox(
        height: 88,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: images.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => SizedBox(
            width: 88,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: Image.memory(
                        images[index].bytes,
                        fit: BoxFit.contain,
                        cacheWidth: 176,
                        semanticLabel: images[index].name,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                ),
                if (removable)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton.filledTonal(
                      key: ValueKey('ai-remove-image-$index'),
                      onPressed: _loadingImages || widget.task.running
                          ? null
                          : () => setState(() => _images.removeAt(index)),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        semanticLabel: '移除图片',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

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

  void _send() {
    final text = _input.text.trim();
    if (_loadingImages || (text.isEmpty && _images.isEmpty)) return;
    widget.task.start(text, images: List.of(_images));
    if (widget.task.running) {
      _input.clear();
      setState(() => _images.clear());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Widget _composer(AiTaskController task) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: _dragging
          ? colors.secondaryContainer
          : colors.surfaceContainerHighest,
      shape: HarborShapes.superellipse(BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_images.isNotEmpty) ...[
              _thumbnails(_images, removable: true),
              const SizedBox(height: 8),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  key: const ValueKey('ai-add-image'),
                  onPressed: task.running || _loadingImages
                      ? null
                      : _pickImages,
                  icon: _loadingImages
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.add_photo_alternate_outlined,
                          semanticLabel: '添加图片',
                        ),
                ),
                Expanded(
                  child: Actions(
                    actions: {
                      PasteTextIntent: CallbackAction<PasteTextIntent>(
                        onInvoke: (_) {
                          _paste();
                          return null;
                        },
                      ),
                    },
                    child: TextField(
                      key: const ValueKey('ai-task-input'),
                      controller: _input,
                      enabled: !task.running,
                      contentInsertionConfiguration:
                          ContentInsertionConfiguration(
                            allowedMimeTypes: const [
                              'image/png',
                              'image/jpeg',
                              'image/webp',
                              'image/gif',
                            ],
                            onContentInserted: (content) =>
                                _loadImages(() async {
                                  if (content.data == null) {
                                    throw const AiFailure('无法读取粘贴的图片');
                                  }
                                  final image = await AiImage.fromBytes(
                                    '粘贴的图片',
                                    content.data!,
                                  );
                                  if (mounted) _addImage(image);
                                }),
                          ),
                      contextMenuBuilder: (context, state) =>
                          AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: state.contextMenuAnchors,
                            buttonItems: [
                              for (final item in state.contextMenuButtonItems)
                                if (item.type != ContextMenuButtonType.paste)
                                  item,
                              ContextMenuButtonItem(
                                type: ContextMenuButtonType.paste,
                                onPressed: () {
                                  state.hideToolbar();
                                  _paste();
                                },
                              ),
                            ],
                          ),
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '发送消息…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, value, _) => IconButton.filled(
                    key: const ValueKey('ai-send'),
                    onPressed: task.running
                        ? task.stop
                        : _loadingImages ||
                              (value.text.trim().isEmpty && _images.isEmpty)
                        ? null
                        : _send,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: Icon(
                      task.running
                          ? Icons.stop_rounded
                          : Icons.arrow_upward_rounded,
                      semanticLabel: task.running ? '停止' : '发送',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(AiTaskEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (entry.notice == true) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (entry.command) return _toolEntry(entry);
    return Padding(
      padding: EdgeInsets.only(bottom: 16, left: entry.user == true ? 20 : 0),
      child: Material(
        key: ObjectKey(entry),
        color: entry.user == true
            ? colors.secondaryContainer
            : colors.surfaceContainerHigh,
        shape: HarborShapes.superellipse(BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (entry.user != true) ...[
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.model ?? 'AI',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              if (entry.images?.isNotEmpty == true) ...[
                _thumbnails(entry.images!),
                if (entry.text.isNotEmpty) const SizedBox(height: 10),
              ],
              if (entry.text.isNotEmpty)
                SelectableText(entry.text, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolEntry(AiTaskEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final failed =
        entry.finished && entry.exitCode != null && entry.exitCode != 0;
    final label = entry.interruption != null
        ? (entry.started == true ? '已中止' : '未执行')
        : entry.finished
        ? (entry.exitCode == null ? '无退出码' : '退出码 ${entry.exitCode}')
        : entry.started == true
        ? '执行中'
        : '待确认';
    final shape = HarborShapes.superellipse(BorderRadius.circular(20));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        key: ObjectKey(entry),
        initiallyExpanded: _expandedTools[entry] ?? false,
        onExpansionChanged: (expanded) => _expandedTools[entry] = expanded,
        shape: shape,
        collapsedShape: shape,
        backgroundColor: colors.surfaceContainerLow,
        collapsedBackgroundColor: colors.surfaceContainerLow,
        iconColor: colors.onSurfaceVariant,
        collapsedIconColor: colors.onSurfaceVariant,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Text.rich(
          TextSpan(
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.terminal_rounded,
                    size: 18,
                    color: colors.primary,
                  ),
                ),
              ),
              TextSpan(text: entry.reason ?? '执行命令'),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: ShapeDecoration(
                      shape: const StadiumBorder(),
                      color: failed
                          ? colors.errorContainer
                          : colors.secondaryContainer,
                    ),
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: failed
                            ? colors.onErrorContainer
                            : colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          style: theme.textTheme.labelLarge,
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              entry.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (entry.output.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    entry.output,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (entry.interruption != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                entry.interruption!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      child: ListenableBuilder(
        listenable: widget.task,
        builder: (context, _) {
          final task = widget.task;
          final configured = task.settings().configured;
          return DropTarget(
            enable:
                !task.running &&
                !_loadingImages &&
                configured &&
                (ModalRoute.of(context)?.isCurrent ?? true),
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (details) => _loadImages(
              () => _readSources([
                for (final item in details.files)
                  AiImageSource(item.name, () => _readDrop(item)),
              ]),
            ),
            child: Padding(
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
                              'AI 助手',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
                      if (task.entries.isNotEmpty)
                        IconButton(
                          key: const ValueKey('ai-new-conversation'),
                          onPressed: task.running ? null : task.newConversation,
                          icon: const Icon(
                            Icons.edit_square,
                            semanticLabel: '新对话',
                          ),
                        ),
                      IconButton(
                        onPressed: widget.onClose,
                        icon: const Icon(
                          Icons.close_rounded,
                          semanticLabel: '关闭 AI 面板',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        child: SizedBox(
                          height: math.max(
                            constraints.maxHeight,
                            300 *
                                MediaQuery.textScalerOf(context).scale(14) /
                                14,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
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
                                          key: const ValueKey('ai-transcript'),
                                          controller: _scroll,
                                          itemCount:
                                              task.entries.length +
                                              (task.running ? 1 : 0),
                                          itemBuilder: (_, index) =>
                                              index < task.entries.length
                                              ? _entry(task.entries[index])
                                              : _AiActivity(
                                                  key: const ValueKey(
                                                    'ai-activity',
                                                  ),
                                                  label: task.status,
                                                  waiting: task.pending != null,
                                                  startedAt: task.turnStartedAt,
                                                ),
                                        ),
                                ),
                                if (task.failure != null &&
                                    (task.entries.isEmpty ||
                                        task.entries.last.notice != true ||
                                        task.entries.last.text !=
                                            task.failure)) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    task.failure!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: task.failure == null
                                              ? colors.onSurfaceVariant
                                              : colors.error,
                                        ),
                                  ),
                                ],
                                if (task.pending != null) ...[
                                  const SizedBox(height: 10),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 120,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(task.pending!.reason),
                                          const SizedBox(height: 8),
                                          SelectableText(
                                            task.pending!.command,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontFamily: 'monospace',
                                                ),
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
                                        child: const Text('取消'),
                                      ),
                                      FilledButton.tonal(
                                        onPressed: () => task.approve(true),
                                        child: const Text('批准并执行'),
                                      ),
                                    ],
                                  ),
                                ] else ...[
                                  const SizedBox(height: 12),
                                  _composer(task),
                                ],
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AiActivity extends StatefulWidget {
  const _AiActivity({
    super.key,
    required this.label,
    required this.waiting,
    this.startedAt,
  });
  final String label;
  final bool waiting;
  final DateTime? startedAt;

  @override
  State<_AiActivity> createState() => _AiActivityState();
}

class _AiActivityState extends State<_AiActivity>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !widget.waiting) setState(() {});
    });
  }

  void _updateMotion() {
    if (widget.waiting || MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant _AiActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final seconds = widget.startedAt == null
        ? 0
        : DateTime.now()
              .difference(widget.startedAt!)
              .inSeconds
              .clamp(0, 86400);
    final elapsed = seconds < 60
        ? '$seconds 秒'
        : '${seconds ~/ 60} 分 ${seconds % 60} 秒';
    return Semantics(
      liveRegion: true,
      label: widget.label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: widget.waiting
                    ? Icon(
                        Icons.pause_circle_outline_rounded,
                        size: 18,
                        color: colors.primary,
                      )
                    : FadeTransition(
                        opacity: Tween<double>(
                          begin: .35,
                          end: 1,
                        ).animate(_pulse),
                        child: Icon(
                          Icons.auto_awesome_rounded,
                          size: 16,
                          color: colors.primary,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (!widget.waiting && widget.startedAt != null) ...[
                const SizedBox(width: 8),
                Text(
                  elapsed,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps terminal and composer state across desktop split and compact AI views.
class TerminalAiLayout extends StatelessWidget {
  const TerminalAiLayout({super.key, required this.terminal, this.panel});

  final Widget terminal;
  final Widget? panel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = constraints.maxWidth >= 800;
      final hidden = !horizontal && panel != null;
      final panelWidth = horizontal
          ? (constraints.maxWidth * .4).clamp(320.0, 440.0)
          : constraints.maxWidth;
      final terminalWidth = horizontal && panel != null
          ? constraints.maxWidth - panelWidth - 1
          : constraints.maxWidth;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: terminalWidth,
            child: Offstage(
              offstage: hidden,
              child: TickerMode(
                enabled: !hidden,
                child: ExcludeFocus(excluding: hidden, child: terminal),
              ),
            ),
          ),
          if (panel != null) ...[
            Positioned(
              left: terminalWidth,
              top: 0,
              bottom: 0,
              width: horizontal ? 1 : 0,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: panelWidth,
              child: panel!,
            ),
          ],
        ],
      );
    },
  );
}
