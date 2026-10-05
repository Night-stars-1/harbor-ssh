import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ai_conversation_store.dart';
import '../data/ai_image.dart';
import '../data/ai_image_input.dart';
import '../data/terminal_ai.dart';

import 'ai_task_controller.dart';
import 'ai_markdown_code_block.dart';
import 'ai_markdown_style.dart';
import 'ai_markdown_table.dart';
import 'theme.dart';

class TerminalAiPanel extends StatefulWidget {
  const TerminalAiPanel({
    super.key,
    required this.task,
    required this.hostName,
    this.onSettings,
    this.onClose,
    this.onDetach,
    this.onDock,
    this.imageInput,
  });
  final AiTaskController task;
  final String hostName;
  final VoidCallback? onSettings;
  final VoidCallback? onClose;

  /// Opens this panel in a separate system window. Null keeps the panel
  /// embedded, so the detached-window entry point never appears.
  final VoidCallback? onDetach;

  /// Returns the detached window's panel to the main window. Null keeps the
  /// dock entry point hidden, which is the embedded panel's normal state.
  final VoidCallback? onDock;
  final AiImageInput? imageInput;
  @override
  State<TerminalAiPanel> createState() => _TerminalAiPanelState();
}

class _TerminalAiPanelState extends State<TerminalAiPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _scrollQueued = false;
  final _images = <AiImage>[];
  bool _loadingImages = false;
  bool _dragging = false;
  List<String> _models = const [];
  String? _modelsKey;
  String? _modelsError;
  bool _loadingModels = false;
  final _modelMenu = MenuController();
  final _approvalMenu = MenuController();
  bool _historyOpen = false;
  bool _wasRunning = false;
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

  @override
  void initState() {
    super.initState();
    widget.task.addListener(_changed);
    // Loading here keeps the history list ready before it is opened. The store
    // is injected by the app; without one this is a no-op.
    unawaited(widget.task.loadHistory());
  }

  void _changed() {
    final running = widget.task.running;
    if (running && !_wasRunning) {
      // The message is accepted only once the turn starts; a rejected start
      // (validation failure) leaves the draft in the composer.
      if (_input.text.isNotEmpty || _images.isNotEmpty) {
        _input.clear();
        setState(() => _images.clear());
      }
      _scrollToEnd();
    }
    _wasRunning = running;
    if (_scrollQueued ||
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset > 80) {
      return;
    }
    _scrollToEnd();
  }

  void _scrollToEnd() {
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
    if (widget.task.running ||
        _loadingImages ||
        (text.isEmpty && _images.isEmpty)) {
      return;
    }
    // The draft is cleared by _changed once the turn actually starts; a start
    // rejected by validation keeps the text and shows failure instead.
    unawaited(widget.task.start(text, images: List.of(_images)));
  }

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // Let the IME confirm its candidate before interpreting Enter as send.
    if (_input.value.composing.isValid && !_input.value.composing.isCollapsed) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (event is KeyDownEvent && !widget.task.running) {
      if (keyboard.isShiftPressed) {
        _insertText('\n');
      } else {
        _send();
      }
    }
    return KeyEventResult.handled;
  }

  String _modelsCacheKey(AiTaskController task) {
    final settings = task.settings();
    return '${settings.baseUrl}|${settings.protocol}|${settings.provider}';
  }

  Future<void> _loadModels(AiTaskController task, {bool force = false}) async {
    if (task.running || _loadingModels) return;
    final key = _modelsCacheKey(task);
    if (!force && _modelsKey == key && _models.isNotEmpty) return;
    setState(() {
      _loadingModels = true;
      _modelsError = null;
      _modelsKey = key;
    });
    try {
      final models = await task.listModels();
      if (!mounted) return;
      setState(() => _models = models);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _models = const [];
        _modelsError = error is AiFailure ? error.message : '获取模型失败，请重试';
      });
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _openModelMenu(AiTaskController task) async {
    if (task.running) return;
    await _loadModels(task);
    if (mounted) _modelMenu.open();
  }

  /// Shows saved conversations as a wide master/detail dialog on desktop and a
  /// sheet on phones. The browser decides list-only vs. two panes from the
  /// width it is given, so a narrow desktop window behaves like a phone.
  Future<void> _openHistory() async {
    final task = widget.task;
    if (task.running || _historyOpen) return;
    _historyOpen = true;
    try {
      // Refresh in the background; the browser renders the loading state.
      unawaited(task.loadHistory());
      final size = MediaQuery.sizeOf(context);
      if (size.width < 600) {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          builder: (_) => FractionallySizedBox(
            heightFactor: 0.85,
            child: SafeArea(
              top: false,
              child: _AiHistoryWorkspace(
                task: task,
                hasDraft: _hasDraft,
                clearDraft: _clearDraft,
              ),
            ),
          ),
        );
      } else {
        // A scroll view cannot be measured by Dialog's IntrinsicWidth, so the
        // browser gets an explicit size instead. It grows with the viewport up
        // to a comfortable reading width, and both panes need bounded height.
        final width = math.min(1000.0, size.width - 48);
        final height = math.min(640.0, size.height - 48);
        await showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            clipBehavior: Clip.antiAlias,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            child: SizedBox(
              width: width,
              height: height,
              child: _AiHistoryWorkspace(
                task: task,
                hasDraft: _hasDraft,
                clearDraft: _clearDraft,
              ),
            ),
          ),
        );
      }
    } finally {
      _historyOpen = false;
    }
  }

  bool _hasDraft() => _input.text.trim().isNotEmpty || _images.isNotEmpty;

  /// The draft belongs to the conversation that was open; switching drops it.
  void _clearDraft() {
    if (!mounted) return;
    _input.clear();
    setState(() => _images.clear());
  }

  /// Non-blocking hint that history could not be read or written. It stays
  /// visible without opening the list and never replaces or hides the chat.
  Widget _historyNotice(AiTaskController task) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        key: const ValueKey('ai-history-notice'),
        borderRadius: BorderRadius.circular(12),
        onTap: task.running ? null : _openHistory,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 16,
                color: colors.error,
                semanticLabel: '历史对话异常',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.historyFailure!,
                  key: const ValueKey('ai-history-notice-text'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.error),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ButtonStyle _floatingMenuItemStyle({bool selected = false}) {
    final colors = Theme.of(context).colorScheme;
    return MenuItemButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.sm)),
      backgroundColor: selected ? colors.secondaryContainer : null,
      foregroundColor: selected ? colors.onSecondaryContainer : null,
    );
  }

  Widget _modelMenuContent(AiTaskController task) {
    final models = <String>{
      task.activeModel,
      ..._models,
    }.where((model) => model.trim().isNotEmpty).toList()..sort();
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: 260,
        maxWidth: 360,
        maxHeight: 360,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadingModels)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_modelsError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  _modelsError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (final model in models)
              MenuItemButton(
                style: _floatingMenuItemStyle(
                  selected: model == task.activeModel,
                ),
                leadingIcon: Icon(
                  model == task.activeModel
                      ? Icons.check_rounded
                      : Icons.circle_outlined,
                  size: 18,
                ),
                onPressed: () {
                  task.setModel(model);
                  _modelMenu.close();
                },
                child: Text(model, overflow: TextOverflow.ellipsis),
              ),
            MenuItemButton(
              style: _floatingMenuItemStyle(),
              leadingIcon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: () => _loadModels(task, force: true),
              child: const Text('刷新模型列表'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelPicker(AiTaskController task, {bool compact = false}) {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _modelMenu,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [_modelMenuContent(task)],
      builder: (context, controller, child) => Tooltip(
        message: '切换模型（${task.activeModel}）',
        child: compact
            ? SizedBox.square(
                dimension: 40,
                child: IconButton(
                  key: const ValueKey('ai-model-picker'),
                  onPressed: task.running ? null : () => _openModelMenu(task),
                  icon: const Icon(Icons.tune_rounded),
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              )
            : TextButton.icon(
                key: const ValueKey('ai-model-picker'),
                onPressed: task.running ? null : () => _openModelMenu(task),
                icon: Icon(Icons.tune_rounded, size: 15, color: colors.primary),
                label: Text(
                  task.activeModel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: colors.primary),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
      ),
    );
  }

  Widget _compactModelPicker(AiTaskController task) =>
      _modelPicker(task, compact: true);

  Widget _approvalMode(AiTaskController task, {bool compact = false}) {
    final mode = task.approvalMode;
    final label = switch (mode) {
      AiApprovalMode.auto => '自动审批',
      AiApprovalMode.readOnly => '只读模式',
      AiApprovalMode.manual => '手动审批',
    };
    final message = switch (mode) {
      AiApprovalMode.auto => '高风险命令将自动执行',
      AiApprovalMode.readOnly => 'AI 只发起工具调用，命令由客户端执行',
      AiApprovalMode.manual => '高风险命令执行前询问',
    };
    final icon = switch (mode) {
      AiApprovalMode.auto => Icons.verified_user_rounded,
      AiApprovalMode.readOnly => Icons.visibility_outlined,
      AiApprovalMode.manual => Icons.gpp_maybe_outlined,
    };
    return MenuAnchor(
      controller: _approvalMenu,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final item in [
          (
            AiApprovalMode.manual,
            '手动审批',
            '高风险命令执行前询问',
            Icons.gpp_maybe_outlined,
          ),
          (
            AiApprovalMode.auto,
            '自动审批',
            '高风险命令将自动执行',
            Icons.verified_user_rounded,
          ),
          (
            AiApprovalMode.readOnly,
            '只读模式',
            'AI 只能调用读取工具，命令由客户端执行',
            Icons.visibility_outlined,
          ),
        ])
          MenuItemButton(
            style: _floatingMenuItemStyle(selected: mode == item.$1),
            leadingIcon: Icon(
              mode == item.$1 ? Icons.check_rounded : item.$4,
              size: 18,
            ),
            onPressed: () => task.setApprovalMode(item.$1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.$2),
                Text(item.$3, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: message,
        child: compact
            ? SizedBox.square(
                dimension: 40,
                child: IconButton(
                  key: const ValueKey('ai-auto-approve'),
                  onPressed: controller.isOpen
                      ? controller.close
                      : controller.open,
                  icon: Icon(icon),
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              )
            : TextButton.icon(
                key: const ValueKey('ai-auto-approve'),
                onPressed: controller.isOpen
                    ? controller.close
                    : controller.open,
                icon: Icon(icon, size: 16),
                label: Text(label),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
      ),
    );
  }

  Widget _composerOptions(AiTaskController task) {
    final compact = MediaQuery.sizeOf(context).width < 360;
    final modelControl = task.settings().configured
        ? compact
              ? _compactModelPicker(task)
              : Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _modelPicker(task),
                  ),
                )
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Row(
        children: [
          if (compact)
            SizedBox.square(
              dimension: 40,
              child: IconButton(
                key: const ValueKey('ai-add-image'),
                onPressed: task.running || _loadingImages ? null : _pickImages,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
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
            )
          else
            IconButton(
              key: const ValueKey('ai-add-image'),
              onPressed: task.running || _loadingImages ? null : _pickImages,
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
          _approvalMode(task, compact: compact),
          if (modelControl != null) ...[
            modelControl,
            if (!compact) const SizedBox(width: 4),
          ] else
            const Spacer(),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (context, value, _) => compact
                ? SizedBox.square(
                    dimension: 40,
                    child: IconButton.filled(
                      key: const ValueKey('ai-send'),
                      onPressed: task.running
                          ? task.stop
                          : _loadingImages ||
                                (value.text.trim().isEmpty && _images.isEmpty)
                          ? null
                          : _send,
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(40),
                        maximumSize: const Size.square(40),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      icon: Icon(
                        task.running
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                        semanticLabel: task.running ? '停止' : '发送',
                      ),
                    ),
                  )
                : IconButton.filled(
                    key: const ValueKey('ai-send'),
                    onPressed: task.running
                        ? task.stop
                        : _loadingImages ||
                              (value.text.trim().isEmpty && _images.isEmpty)
                        ? null
                        : _send,
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(48),
                      maximumSize: const Size.square(48),
                      padding: EdgeInsets.zero,
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
    );
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
              _thumbnails(
                _images,
                removable: true,
                onRemove: _loadingImages || task.running
                    ? null
                    : (index) => setState(() => _images.removeAt(index)),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    onKeyEvent: _composerKey,
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
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.send,
                        onEditingComplete: () {},
                        onSubmitted: (_) => _send(),
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
                ),
              ],
            ),
            _composerOptions(task),
          ],
        ),
      ),
    );
  }

  /// Title-bar entry point for the separate system window. The embedded panel
  /// offers [onDetach] (pop out), the detached window offers [onDock] (return);
  /// the caller passes at most one, so both keys never render together.
  Widget _windowModeButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool compact,
  }) => Tooltip(
    message: label,
    child: IconButton(
      key: key,
      onPressed: onPressed,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 40, height: 40)
          : null,
      padding: compact ? EdgeInsets.zero : null,
      visualDensity: compact ? VisualDensity.compact : null,
      style: compact
          ? IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      icon: Icon(icon, semanticLabel: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      child: ListenableBuilder(
        listenable: widget.task,
        builder: (context, _) {
          final task = widget.task;
          final messages = _messageGroups(task.entries);
          final configured = task.settings().configured;
          // A window-mode entry point costs one more title-bar action. On
          // phone-width surfaces the decorative mark yields its slot so the
          // existing history/new/close actions keep their full-size layout and
          // the 240px/2x header still fits without overflow.
          final hasWindowAction =
              widget.onDetach != null || widget.onDock != null;
          final compactHeader =
              hasWindowAction && MediaQuery.sizeOf(context).width < 360;
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
                      if (!compactHeader) ...[
                        Icon(Icons.auto_awesome_rounded, color: colors.primary),
                        const SizedBox(width: 10),
                      ],
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
                      IconButton(
                        key: const ValueKey('ai-history'),
                        onPressed: task.running ? null : _openHistory,
                        icon: const Icon(
                          Icons.history_rounded,
                          semanticLabel: '历史对话',
                        ),
                      ),
                      if (task.entries.isNotEmpty)
                        IconButton(
                          key: const ValueKey('ai-new-conversation'),
                          onPressed: task.running
                              ? null
                              : () => unawaited(task.newConversation()),
                          icon: const Icon(
                            Icons.edit_square,
                            semanticLabel: '新对话',
                          ),
                        ),
                      if (widget.onDetach != null)
                        _windowModeButton(
                          key: const ValueKey('ai-popout'),
                          icon: Icons.open_in_new_rounded,
                          label: '在独立窗口中打开',
                          onPressed: widget.onDetach!,
                          compact: compactHeader,
                        ),
                      if (widget.onDock != null)
                        _windowModeButton(
                          key: const ValueKey('ai-dock'),
                          icon: Icons.close_fullscreen_rounded,
                          label: '返回主窗口',
                          onPressed: widget.onDock!,
                          compact: compactHeader,
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
                  if (task.historyFailure != null) _historyNotice(task),
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
                                              messages.length +
                                              (task.running ? 1 : 0),
                                          itemBuilder: (_, index) =>
                                              index < messages.length
                                              ? _AiMessageBubble(
                                                  key: ObjectKey(
                                                    messages[index].first,
                                                  ),
                                                  entries: messages[index],
                                                )
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
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(task.pending!.reason),
                                      ),
                                      _approvalMode(
                                        task,
                                        compact:
                                            MediaQuery.sizeOf(context).width <
                                            360,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 120,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
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

/// Horizontal strip of image thumbnails. The composer passes [onRemove] so an
/// attachment can be dropped again; transcript bubbles reuse the same strip
/// read-only.
Widget _thumbnails(
  List<AiImage> images, {
  bool removable = false,
  ValueChanged<int>? onRemove,
}) => SizedBox(
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
                onPressed: onRemove == null ? null : () => onRemove(index),
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

/// Groups flat entries the way a transcript reads: a user or notice entry
/// always starts a bubble, while assistant text and tool calls join the
/// assistant bubble above them.
List<List<AiTaskEntry>> _messageGroups(List<AiTaskEntry> entries) {
  final groups = <List<AiTaskEntry>>[];
  for (final entry in entries) {
    if (entry.user == true ||
        entry.notice == true ||
        groups.isEmpty ||
        groups.last.first.user == true ||
        groups.last.first.notice == true) {
      groups.add([entry]);
    } else {
      groups.last.add(entry);
    }
  }
  return groups;
}

/// One chat bubble: model header, markdown text, image thumbnails and
/// collapsible tool calls. The live transcript and the read-only history
/// preview share it, so a saved conversation renders exactly as it did live.
class _AiMessageBubble extends StatefulWidget {
  const _AiMessageBubble({super.key, required this.entries});

  /// The bubble's entries in order; the first one decides user/notice/model.
  final List<AiTaskEntry> entries;

  @override
  State<_AiMessageBubble> createState() => _AiMessageBubbleState();
}

class _AiMessageBubbleState extends State<_AiMessageBubble> {
  /// Tool disclosures the user opened, keyed by entry so incoming output does
  /// not collapse them again.
  late final _expandedTools = Expando<bool>();

  void _linkFailure() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('无法打开链接')));
  }

  Widget _markdown(String text) {
    final theme = Theme.of(context);
    void onTapLink(String text, String? href, String title) async {
      final uri = Uri.tryParse(href ?? '');
      if (uri == null ||
          !const ['https', 'http', 'mailto'].contains(uri.scheme)) {
        return;
      }
      try {
        if (!await launchUrl(uri)) _linkFailure();
      } catch (_) {
        _linkFailure();
      }
    }

    return MarkdownBody(
      data: text,
      selectable: true,
      fitContent: false,
      blockSyntaxes: const [AiMarkdownTableSyntax()],
      builders: {
        'pre': AiMarkdownCodeBuilder(),
        AiMarkdownTableSyntax.tag: AiMarkdownTableBuilder(onTapLink: onTapLink),
      },
      styleSheet: aiMarkdownStyle(theme),
      onTapLink: onTapLink,
    );
  }

  Widget _toolEntry(AiTaskEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shape = HarborShapes.superellipse(BorderRadius.circular(20));
    final expanded = _expandedTools[entry] ?? false;
    return ExpansionTile(
      key: ObjectKey(entry),
      initiallyExpanded: expanded,
      onExpansionChanged: (value) =>
          setState(() => _expandedTools[entry] = value),
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
          ],
        ),
        style: theme.textTheme.labelLarge,
      ),
      subtitle: expanded
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    entry.text.replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.output.isNotEmpty
                        ? entry.output.replaceAll(RegExp(r'\s+'), ' ')
                        : entry.interruption ??
                              (entry.finished ? '无输出' : '等待输出…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final entry = entries.first;
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
    final model = entries.map((item) => item.model).nonNulls.firstOrNull;
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
                        model ?? 'AI',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              for (var index = 0; index < entries.length; index++) ...[
                if (index > 0) const SizedBox(height: 12),
                if (entries[index].command)
                  _toolEntry(entries[index])
                else ...[
                  if (entries[index].images?.isNotEmpty == true) ...[
                    _thumbnails(entries[index].images!),
                    if (entries[index].text.isNotEmpty)
                      const SizedBox(height: 10),
                  ],
                  if (entries[index].text.isNotEmpty)
                    _markdown(entries[index].text),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Below this width the browser shows either the list or the preview, not both.
const _historyWideBreakpoint = 700.0;

/// Saved conversations for one host as a master/detail workspace: the left
/// list only selects, the right side previews a conversation read-only, and
/// 「打开对话」 is the one control that switches the live conversation. Reads
/// only the controller's public API so persistence stays in the data layer.
class _AiHistoryWorkspace extends StatefulWidget {
  const _AiHistoryWorkspace({
    required this.task,
    required this.hasDraft,
    required this.clearDraft,
  });

  final AiTaskController task;

  /// Whether the composer holds unsent text or images for the open conversation.
  final bool Function() hasDraft;

  /// Drops the composer draft once another conversation is open.
  final VoidCallback clearDraft;

  @override
  State<_AiHistoryWorkspace> createState() => _AiHistoryWorkspaceState();
}

class _AiHistoryWorkspaceState extends State<_AiHistoryWorkspace> {
  /// Row whose open or delete request is in flight.
  String? _busyId;

  /// Conversation shown in the preview, or null before any selection.
  String? _previewId;
  List<AiTaskEntry>? _previewEntries;
  bool _previewLoading = false;

  /// Bumped per selection so a slower read cannot overwrite a newer choice.
  int _previewRevision = 0;

  /// Narrow layouts replace the list with the preview once one is selected.
  bool _previewVisible = false;

  @override
  void initState() {
    super.initState();
    // Previewing the conversation that is already open reads the live entries
    // and changes nothing, so the desktop pane opens with real content.
    final active = widget.task.activeConversationId;
    if (active != null) {
      _previewId = active;
      _previewLoading = true;
      _loadPreview(widget.task, active);
    }
  }

  void _loadPreview(AiTaskController task, String id) {
    final revision = ++_previewRevision;
    task.previewConversation(id).then((entries) {
      if (!mounted || revision != _previewRevision) return;
      setState(() {
        _previewLoading = false;
        _previewEntries = entries;
      });
    });
  }

  /// Selects [id] for the preview only; the live conversation is untouched.
  /// [reveal] switches the narrow layout to the preview view.
  void _select(AiTaskController task, String id, {bool reveal = true}) {
    setState(() {
      _previewId = id;
      _previewEntries = null;
      _previewLoading = true;
      if (reveal) _previewVisible = true;
    });
    _loadPreview(task, id);
  }

  AiConversationSummary? _conversationFor(AiTaskController task, String? id) {
    if (id == null) return null;
    for (final conversation in task.conversations) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }

  Future<void> _open(String id) async {
    final task = widget.task;
    if (task.running || task.historyLoading || _busyId != null) return;
    // Unsent input belongs to the conversation being left; ask before dropping.
    if (widget.hasDraft()) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('切换对话？'),
          content: const Text('输入框内容与待发送图片属于当前对话，切换后会清空。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('切换'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    setState(() => _busyId = id);
    try {
      await task.openConversation(id);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    // Keep the browser open when the switch failed so historyFailure stays
    // visible instead of looking like a successful open.
    if (mounted &&
        task.activeConversationId == id &&
        task.historyFailure == null) {
      widget.clearDraft();
      // The open succeeded, so the browser closes even from the phone preview
      // view, where a back request would otherwise only return to the list.
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete(String id, String title) async {
    final task = widget.task;
    if (task.running || task.historyLoading || _busyId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除历史对话？'),
        content: Text('将删除「$title」的本机加密记录，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final index = task.conversations.indexWhere((item) => item.id == id);
    setState(() => _busyId = id);
    try {
      await task.deleteConversation(id);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    if (!mounted || _previewId != id) return;
    final remaining = task.conversations;
    // A failed delete keeps the row and the preview: nothing to move on to.
    if (remaining.any((item) => item.id == id)) return;
    if (remaining.isEmpty) {
      _previewRevision++;
      setState(() {
        _previewId = null;
        _previewEntries = null;
        _previewLoading = false;
        _previewVisible = false;
      });
      return;
    }
    // The next conversation is previewed in place; on a phone the list stays
    // where the delete was confirmed.
    _select(
      task,
      remaining[index < 0 ? 0 : math.min(index, remaining.length - 1)].id,
      reveal: false,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.task,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final task = widget.task;
        final compact = constraints.maxWidth < _historyWideBreakpoint;
        final detail = compact && _previewVisible && _previewId != null;
        // On a phone the system back gesture leaves the preview first; the
        // browser only closes from the list.
        return PopScope(
          canPop: !detail,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && detail) setState(() => _previewVisible = false);
          },
          child: compact
              ? detail
                    ? _previewPane(task, compact: true)
                    : _listPane(task)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: constraints.maxWidth >= 900
                          ? 340
                          : math.max(240, constraints.maxWidth * 0.36),
                      child: _listPane(task),
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: _previewPane(task, compact: false)),
                  ],
                ),
        );
      },
    ),
  );

  /// Navigation pane: title, problems, and one selectable row per conversation.
  Widget _listPane(AiTaskController task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final conversations = task.conversations;
    // Looking at a saved conversation is safe while a task runs; opening or
    // deleting one is not.
    final selectable = !task.historyLoading && _busyId == null;
    return Material(
      color: colors.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '历史对话',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (task.historyLoading)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          if (task.historyFailure != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                task.historyFailure!,
                key: const ValueKey('ai-history-error'),
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ),
          if (conversations.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Text(
                    task.historyLoading
                        ? '正在读取历史对话…'
                        : task.historyFailure != null
                        ? '历史对话不可用'
                        : '暂无历史对话，发送消息后会自动加密保存在本机',
                    key: const ValueKey('ai-history-empty'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                key: const ValueKey('ai-history-list'),
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                itemCount: conversations.length,
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  final active = conversation.id == task.activeConversationId;
                  final previewing = conversation.id == _previewId;
                  final model = conversation.model.trim();
                  return Padding(
                    padding: const EdgeInsets.only(
                      bottom: HarborShapes.listGap,
                    ),
                    child: Material(
                      key: ValueKey('ai-history-item-${conversation.id}'),
                      color: previewing
                          ? colors.secondaryContainer
                          : colors.surfaceContainer,
                      shape: HarborShapes.superellipse(
                        HarborShapes.listItem(
                          HarborShapes.listSlot(index, conversations.length),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        selected: previewing,
                        selectedColor: colors.onSecondaryContainer,
                        enabled: selectable,
                        onTap: selectable
                            ? () => _select(task, conversation.id)
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 2,
                        ),
                        leading: _busyId == conversation.id
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                active
                                    ? Icons.chat_bubble_rounded
                                    : Icons.history_rounded,
                                size: 20,
                              ),
                        title: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (active) '当前',
                            _historyTime(conversation.updatedAt),
                            if (model.isNotEmpty) model,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        trailing: IconButton(
                          key: ValueKey('ai-history-delete-${conversation.id}'),
                          onPressed: !task.running && selectable
                              ? () =>
                                    _delete(conversation.id, conversation.title)
                              : null,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            semanticLabel: '删除对话',
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Detail pane: read-only preview plus the one control that opens it.
  Widget _previewPane(AiTaskController task, {required bool compact}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final conversation = _conversationFor(task, _previewId);
    final canOpen =
        conversation != null &&
        !task.running &&
        !task.historyLoading &&
        _busyId == null;
    return Material(
      color: colors.surfaceContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 4 : 20,
              compact ? 2 : 16,
              16,
              compact ? 2 : 12,
            ),
            child: Row(
              children: [
                if (compact)
                  IconButton(
                    key: const ValueKey('ai-history-preview-back'),
                    onPressed: () => setState(() => _previewVisible = false),
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      semanticLabel: '返回列表',
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation?.title ?? '预览',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _previewMeta(conversation),
                        key: const ValueKey('ai-history-preview-meta'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _previewBody(task)),
          const Divider(height: 1),
          _previewActions(
            task,
            conversation: conversation,
            canOpen: canOpen,
            compact: compact,
          ),
        ],
      ),
    );
  }

  String _previewMeta(AiConversationSummary? conversation) {
    if (conversation == null) return '从左侧列表选择一条对话';
    return [
      '只读预览',
      _historyTime(conversation.updatedAt),
      if (conversation.model.trim().isNotEmpty) conversation.model.trim(),
    ].join(' · ');
  }

  Widget _previewBody(AiTaskController task) {
    if (_previewId == null) {
      return _previewMessage(
        '从左侧列表选择一条对话，可在此查看完整内容',
        key: const ValueKey('ai-history-preview-idle'),
        icon: Icons.forum_outlined,
      );
    }
    if (_previewLoading) {
      return const Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(
            key: ValueKey('ai-history-preview-loading'),
            strokeWidth: 2.5,
          ),
        ),
      );
    }
    final entries = _previewEntries;
    if (entries == null) {
      return _previewMessage(
        task.historyFailure ?? '无法读取这条对话',
        key: const ValueKey('ai-history-preview-error'),
        icon: Icons.error_outline_rounded,
        error: true,
      );
    }
    if (entries.isEmpty) {
      return _previewMessage(
        '这条对话没有可预览的内容',
        key: const ValueKey('ai-history-preview-empty'),
        icon: Icons.forum_outlined,
      );
    }
    final groups = _messageGroups(entries);
    // The preview scrolls independently of the live transcript, so a long
    // conversation never clips and never disturbs the open one.
    return ListView.builder(
      key: const ValueKey('ai-history-preview'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: groups.length,
      itemBuilder: (_, index) => _AiMessageBubble(
        key: ObjectKey(groups[index].first),
        entries: groups[index],
      ),
    );
  }

  Widget _previewMessage(
    String text, {
    required Key key,
    required IconData icon,
    bool error = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 28,
              color: error ? colors.error : colors.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              key: key,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: error ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewActions(
    AiTaskController task, {
    required AiConversationSummary? conversation,
    required bool canOpen,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final busy = _busyId != null && _busyId == _previewId;
    final button = FilledButton.icon(
      key: const ValueKey('ai-history-open'),
      onPressed: canOpen ? () => _open(conversation!.id) : null,
      icon: busy
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.forum_outlined, size: 18),
      label: const Text('打开对话'),
    );
    final hint = task.running
        ? '任务运行中，可预览，但不能打开或删除'
        : conversation == null
        ? '选择左侧的对话即可只读预览'
        : '预览不会切换当前对话，打开后才恢复上下文';
    final style = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  hint,
                  key: const ValueKey('ai-history-preview-hint'),
                  textAlign: TextAlign.center,
                  style: style,
                ),
                const SizedBox(height: 8),
                button,
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Text(
                    hint,
                    key: const ValueKey('ai-history-preview-hint'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                const SizedBox(width: 12),
                button,
              ],
            ),
    );
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Relative label for a saved conversation, falling back to a date after a week.
String _historyTime(DateTime time) {
  final local = time.toLocal();
  final elapsed = DateTime.now().difference(local);
  if (elapsed.inMinutes < 1) return '刚刚';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} 分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours} 小时前';
  if (elapsed.inDays < 7) return '${elapsed.inDays} 天前';
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
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
