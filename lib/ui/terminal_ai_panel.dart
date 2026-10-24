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

import 'ai_approval_mode_menu.dart';
import 'ai_task_controller.dart';
import 'ai_window_session.dart';
import 'ai_markdown_code_block.dart';
import 'ai_markdown_style.dart';
import 'ai_markdown_table.dart';
import 'expressive_widgets.dart';
import 'theme.dart';

/// Minimum window width that earns the standalone workbench's action rail;
/// below it the same actions move into the header toolbar.
const _workspaceRailMinWidth = 900.0;

/// The rail also needs height for its actions and host facts, so short windows
/// fall back to the toolbar and give the chat a usable height instead.
const _workspaceRailMinHeight = 560.0;

const _workspaceRailWidth = 220.0;

/// Reading measure shared by the transcript surface and the composer below it.
const _workspaceReadingWidth = 860.0;

/// Largest share of the chat column the approval prompt and composer may take.
/// Beyond it that bottom region scrolls, so a short window with large text can
/// never push the transcript into an overflow.
const _workspaceBottomShare = 0.7;

/// Composer width (at 1x text) below which the model and approval controls
/// collapse to icon buttons. It follows the composer's own constraints, not the
/// whole window, and grows with the text scale.
const _composerCompactWidth = 300.0;

/// Standalone transcript bubbles: a user message reads as a right-aligned note
/// and an assistant reply as a left-aligned document. Each is capped by an
/// absolute width and by a share of the chat column, so a narrow window keeps
/// both sides readable instead of letting a bubble run the full width.
const _bubbleMaxUserWidth = 480.0;
const _bubbleMaxAssistantWidth = 640.0;
const _bubbleMaxUserShare = 0.78;
const _bubbleMaxAssistantShare = 0.92;

/// Safe opening prompts for the empty workbench. Tapping one only prefills the
/// composer: nothing is sent and no command runs.
const _workspaceSuggestions = <String>[
  '检查磁盘空间，找出占用最大的目录',
  '查看最近的服务错误日志',
  '列出内存占用最高的进程',
];

/// Composer draft for one SSH session in the detached window. The window root
/// keeps one per session, so switching sessions and coming back restores the
/// text, the pending attachments and the transcript scroll offset without
/// keeping hidden panels alive.
class AiPanelDraft {
  const AiPanelDraft({
    this.text = const TextEditingValue(),
    this.images = const <AiImage>[],
    this.scrollOffset,
  });

  final TextEditingValue text;
  final List<AiImage> images;
  final double? scrollOffset;
}

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
    this.sessionSelection,
    this.draft,
    this.onDraftChanged,
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

  /// The open SSH sessions the detached window may switch between. Null keeps
  /// the panel a single-session view: the embedded panel and the read-only
  /// previews never offer a session switcher.
  final AiWindowSessionSelection? sessionSelection;

  /// Draft to restore when this panel is built for a session; the detached
  /// window root keeps the drafts so switching sessions never loses one.
  final AiPanelDraft? draft;

  /// Reports the composer draft while the user edits, so the root can store it
  /// under the current session before the panel is rebuilt for another one.
  final ValueChanged<AiPanelDraft>? onDraftChanged;
  @override
  State<TerminalAiPanel> createState() => _TerminalAiPanelState();
}

class _TerminalAiPanelState extends State<TerminalAiPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// The session this panel was built for, captured once. Notifications from
  /// the shared controller may arrive for a different session before the root
  /// swaps the panel, and those must never touch this session's draft.
  String? _sessionId;
  bool _scrollQueued = false;
  final _images = <AiImage>[];

  /// Immutable snapshot of [_images] handed to the draft report. It is rebuilt
  /// only when the attachments change, so typing and scrolling never copy the
  /// list, and the reported draft never aliases the mutable composer list.
  List<AiImage> _imagesSnapshot = const <AiImage>[];
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
    _imagesChanged();
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
    if (mounted) {
      setState(() => _images.addAll(added));
      _imagesChanged();
    }
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
    _sessionId = widget.sessionSelection?.sessionId;
    final draft = widget.draft;
    if (draft != null) {
      _input.value = draft.text;
      _images.addAll(draft.images);
      _imagesSnapshot = List.unmodifiable(_images);
    }
    // A panel can be created for a session that is already running (switching
    // back to it). That is not a new accepted send, so the first notification
    // must not clear the draft that was just restored.
    _wasRunning = widget.task.running;
    _input.addListener(_reportDraft);
    _scroll.addListener(_reportDraft);
    widget.task.addListener(_changed);
    // Loading here keeps the history list ready before it is opened. The store
    // is injected by the app; without one this is a no-op.
    unawaited(widget.task.loadHistory());
    final offset = draft?.scrollOffset;
    if (offset != null && offset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(offset);
      });
    }
  }

  /// Stores the composer draft under the session it belongs to. The root keeps
  /// one draft per session, so the panel can be rebuilt for another session
  /// without keeping hidden panels (and their listeners) alive.
  void _reportDraft() {
    final report = widget.onDraftChanged;
    if (report == null) return;
    report(
      AiPanelDraft(
        text: _input.value,
        images: _imagesSnapshot,
        scrollOffset: _scroll.hasClients ? _scroll.offset : null,
      ),
    );
  }

  /// Rebuilds the immutable attachment snapshot, then reports the draft. Only
  /// the places that add or remove an attachment call this.
  void _imagesChanged() {
    _imagesSnapshot = List.unmodifiable(_images);
    _reportDraft();
  }

  void _changed() {
    // A notification for another session must not clear this session's draft:
    // switching to a running session would otherwise wipe the draft of the one
    // the user just left.
    if (_sessionId != null &&
        widget.sessionSelection?.sessionId != _sessionId) {
      return;
    }
    final running = widget.task.running;
    if (running && !_wasRunning) {
      // The message is accepted only once the turn starts; a rejected start
      // (validation failure) leaves the draft in the composer.
      if (_input.text.isNotEmpty || _images.isNotEmpty) {
        _input.clear();
        setState(() => _images.clear());
        _imagesChanged();
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
    _input.removeListener(_reportDraft);
    _scroll.removeListener(_reportDraft);
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
        await showExpressiveBottomSheet<void>(
          context: context,
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
        await showExpressiveDialog<void>(
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
    _imagesChanged();
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

  ButtonStyle _floatingMenuItemStyle({bool selected = false}) =>
      aiMenuItemStyle(context, selected: selected);

  Widget _modelMenuContent(AiTaskController task) {
    final models = <String>{
      task.activeModel,
      ..._models,
    }.where((model) => model.trim().isNotEmpty).toList()..sort();
    // A 240 dp window (or 200% text on a narrow one) must still fit the menu,
    // so the nominal 260..360 width yields to the space actually available
    // instead of overflowing. Height stays capped and the whole menu body —
    // effort slider first, then the model list — scrolls inside it, so at
    // 200% text no control can be clipped out of reach.
    final availableWidth = math.max(0.0, MediaQuery.sizeOf(context).width - 16);
    final minWidth = math.min(260.0, availableWidth);
    final maxWidth = math.max(minWidth, math.min(360.0, availableWidth));
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minWidth,
        maxWidth: maxWidth,
        maxHeight: 360,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              // The MenuAnchor panel already owns a PrimaryScrollController
              // for its own scrollbar. Without this, this inner view attaches
              // a second position to it and Scrollbar throws.
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The effort slider leads the menu; moving it never closes
                  // the menu, switches the model or touches the draft.
                  _ReasoningEffortSection(task: task),
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
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
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
                ],
              ),
            ),
          ),
          // Refresh stays pinned below the scrolling body so a tall slide of
          // models (or 200% text) can never push it out of the menu. The menu
          // stays open so the spinner, any error and the new list show in
          // place.
          MenuItemButton(
            key: const ValueKey('ai-refresh-models'),
            closeOnActivate: false,
            style: _floatingMenuItemStyle(),
            leadingIcon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: _loadingModels
                ? null
                : () => _loadModels(task, force: true),
            child: const Text('刷新模型列表'),
          ),
        ],
      ),
    );
  }

  Widget _modelPicker(AiTaskController task, {bool compact = false}) {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _modelMenu,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        if (Theme.of(context).windowBackdrop.frosted) const HarborSurfaceBlur(),
        _modelMenuContent(task),
      ],
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
    final icon = aiApprovalIcon(mode);
    return AiApprovalModeMenu(
      controller: _approvalMenu,
      mode: mode,
      onSelected: task.setApprovalMode,
      builder: (context, controller, child) => Tooltip(
        message: mode.description,
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
                label: Text(mode.label),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The composer's own width decides, not the window: the detached
          // workbench can be narrow inside a wide window. The threshold grows
          // with the text scale so a 2x composer collapses to icon buttons
          // before its labels start fighting for room.
          final compact =
              constraints.maxWidth <
              MediaQuery.textScalerOf(context).scale(_composerCompactWidth);
          final model = task.settings().configured
              ? compact
                    ? _compactModelPicker(task)
                    : Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _modelPicker(task),
                        ),
                      )
              : null;
          final pickable = !task.running && !_loadingImages;
          return Row(
            children: [
              if (compact)
                SizedBox.square(
                  dimension: 40,
                  child: IconButton(
                    key: const ValueKey('ai-add-image'),
                    onPressed: pickable ? _pickImages : null,
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
                  onPressed: pickable ? _pickImages : null,
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
              if (model != null) ...[
                if (compact) const Spacer(),
                model,
                if (!compact) const SizedBox(width: 4),
              ] else
                const Spacer(),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _input,
                builder: (context, value, _) {
                  // Stopping a running turn is always available; sending needs
                  // a draft and no image still loading.
                  final sendable =
                      !_loadingImages &&
                      (value.text.trim().isNotEmpty || _images.isNotEmpty);
                  final VoidCallback? onPressed = task.running
                      ? task.stop
                      : (sendable ? _send : null);
                  return compact
                      ? SizedBox.square(
                          dimension: 40,
                          child: IconButton.filled(
                            key: const ValueKey('ai-send'),
                            onPressed: onPressed,
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
                            icon: _sendIcon(task),
                          ),
                        )
                      : IconButton.filled(
                          key: const ValueKey('ai-send'),
                          onPressed: onPressed,
                          style: IconButton.styleFrom(
                            minimumSize: const Size.square(48),
                            maximumSize: const Size.square(48),
                            padding: EdgeInsets.zero,
                          ),
                          icon: _sendIcon(task),
                        );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  /// The composer's primary action: stop while a turn runs, send otherwise.
  Icon _sendIcon(AiTaskController task) => Icon(
    task.running ? Icons.stop_rounded : Icons.arrow_upward_rounded,
    semanticLabel: task.running ? '停止' : '发送',
  );

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
                    : (index) {
                        setState(() => _images.removeAt(index));
                        _imagesChanged();
                      },
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
      color: Theme.of(context).windowBackdrop.chrome(colors.surfaceContainer),
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
            // The detached window (`onDock`) gets the standalone workbench
            // layout; the embedded panel keeps the in-pane layout.
            child: widget.onDock != null
                ? _workspaceBody(context, task, configured)
                : _embeddedBody(task, configured),
          );
        },
      ),
    );
  }

  /// The embedded in-pane panel. Its layout and behaviour are unchanged: one
  /// compact header row above a scrolling transcript, with the composer — or
  /// the approval prompt — at the end of the column.
  ///
  /// A drag handle can leave the panel far narrower than the window it sits in,
  /// so both compact decisions below follow the panel's own width instead of
  /// the window's.
  Widget _embeddedBody(AiTaskController task, bool configured) => LayoutBuilder(
    builder: (context, constraints) => _embeddedBodyContent(
      context,
      task,
      configured,
      compact: constraints.maxWidth < 360,
    ),
  );

  Widget _embeddedBodyContent(
    BuildContext context,
    AiTaskController task,
    bool configured, {
    required bool compact,
  }) {
    final colors = Theme.of(context).colorScheme;
    final messages = _messageGroups(task.entries);
    // A window-mode entry point costs one more title-bar action. On
    // phone-width surfaces the decorative mark yields its slot so the
    // existing history/new/close actions keep their full-size layout and
    // the 240px/2x header still fits without overflow.
    final hasWindowAction = widget.onDetach != null || widget.onDock != null;
    final compactHeader = hasWindowAction && compact;
    return Padding(
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
                icon: const Icon(Icons.history_rounded, semanticLabel: '历史对话'),
              ),
              if (task.entries.isNotEmpty)
                IconButton(
                  key: const ValueKey('ai-new-conversation'),
                  onPressed: task.running
                      ? null
                      : () => unawaited(task.newConversation()),
                  icon: const Icon(Icons.edit_square, semanticLabel: '新对话'),
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
                    300 * MediaQuery.textScalerOf(context).scale(14) / 14,
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
                                      messages.length + (task.running ? 1 : 0),
                                  itemBuilder: (_, index) =>
                                      index < messages.length
                                      ? _AiMessageBubble(
                                          key: ObjectKey(messages[index].first),
                                          entries: messages[index],
                                        )
                                      : _AiActivity(
                                          key: const ValueKey('ai-activity'),
                                          label: task.status,
                                          waiting: task.pending != null,
                                          startedAt: task.turnStartedAt,
                                        ),
                                ),
                        ),
                        if (task.failure != null &&
                            (task.entries.isEmpty ||
                                task.entries.last.notice != true ||
                                task.entries.last.text != task.failure)) ...[
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
                              Expanded(child: Text(task.pending!.reason)),
                              _approvalMode(task, compact: compact),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 120),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SelectableText(
                                    task.pending!.command,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
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
    );
  }

  // ---------------------------------------------------------------------------
  // Standalone workbench (detached window)
  // ---------------------------------------------------------------------------

  /// The detached window reads as a workbench instead of a pane: a header that
  /// names the host and the current task state, an optional action rail on
  /// large windows, a reading-width chat surface and the composer pinned below
  /// it. Everything below reuses the embedded transcript, composer, approval
  /// and history pieces, so both layouts share one implementation.
  Widget _workspaceBody(
    BuildContext context,
    AiTaskController task,
    bool configured,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final showRail =
          constraints.maxWidth >= _workspaceRailMinWidth &&
          constraints.maxHeight >= _workspaceRailMinHeight;
      final chat = _workspaceChat(context, task, configured);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _workspaceHeader(
            context,
            task,
            configured: configured,
            showRail: showRail,
          ),
          Expanded(
            // The chat keeps its slot (and its transcript state) when the rail
            // appears or disappears on resize; only the rail is added or
            // dropped.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: chat),
                if (showRail) _workspaceRail(context, task),
              ],
            ),
          ),
        ],
      );
    },
  );

  /// Host context for the workbench: identity, host name and what the task is
  /// doing right now. The narrow fallback keeps the same actions in a toolbar
  /// under the identity row so a 480px window never crowds the title.
  Widget _workspaceHeader(
    BuildContext context,
    AiTaskController task, {
    required bool configured,
    required bool showRail,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = _workspaceStatus(task, configured);
    final subtitle = '${widget.hostName} · $status';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExpressiveMark(
                size: 44,
                flower: true,
                icon: Icons.auto_awesome_rounded,
                color: colors.primaryContainer,
                foreground: colors.onPrimaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI 工作台',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '返回主窗口',
                child: IconButton(
                  key: const ValueKey('ai-dock'),
                  onPressed: widget.onDock,
                  icon: const Icon(
                    Icons.close_fullscreen_rounded,
                    semanticLabel: '返回主窗口',
                  ),
                ),
              ),
            ],
          ),
          if (!showRail) ...[
            const SizedBox(height: 4),
            _workspaceToolbar(context, task),
          ],
          if (task.historyFailure != null) _historyNotice(task),
        ],
      ),
    );
  }

  /// One line of task state for the header; the rail repeats the model and
  /// approval facts.
  String _workspaceStatus(AiTaskController task, bool configured) {
    if (!configured) return '未配置模型服务';
    if (task.pending != null) return '等待审批';
    if (task.running) {
      final status = task.status.trim();
      return status.isEmpty ? '执行中' : status;
    }
    return task.entries.isEmpty ? '待命' : '已就绪';
  }

  /// Compact header toolbar: the rail's actions for windows too narrow (or too
  /// short) to carry a rail. The session switcher joins them as a menu so a
  /// narrow window can still move between the open SSH sessions.
  Widget _workspaceToolbar(BuildContext context, AiTaskController task) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: [
      if (widget.sessionSelection?.sessions.isNotEmpty ?? false)
        _workspaceSessionMenu(widget.sessionSelection!),
      _workspaceActionButton(
        key: const ValueKey('ai-history'),
        icon: Icons.history_rounded,
        label: '历史对话',
        onPressed: task.running ? null : _openHistory,
      ),
      _workspaceActionButton(
        key: const ValueKey('ai-new-conversation'),
        icon: Icons.edit_square,
        label: '新对话',
        onPressed: task.running
            ? null
            : () => unawaited(task.newConversation()),
      ),
      if (widget.onSettings != null)
        _workspaceActionButton(
          key: const ValueKey('ai-settings'),
          icon: Icons.settings_outlined,
          label: '设置',
          onPressed: widget.onSettings,
        ),
    ],
  );

  Widget _workspaceActionButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => TextButton.icon(
    key: key,
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      minimumSize: const Size(0, 40),
      shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.sm)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  /// Action rail for large windows: the primary actions and, above all, the
  /// open SSH sessions the workbench can switch between. The host facts that
  /// used to fill this rail are already repeated by the composer, so the rail
  /// now spends its space on the session list instead of dead whitespace.
  Widget _workspaceRail(BuildContext context, AiTaskController task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selection = widget.sessionSelection;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 16, 16),
      child: SizedBox(
        width: _workspaceRailWidth,
        child: Material(
          color: colors.surfaceContainerHigh,
          shape: HarborShapes.superellipse(
            const BorderRadius.all(HarborShapes.xl),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: FilledButton.icon(
                  key: const ValueKey('ai-new-conversation'),
                  onPressed: task.running
                      ? null
                      : () => unawaited(task.newConversation()),
                  icon: const Icon(Icons.edit_square, size: 18),
                  label: const Text('新对话'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    shape: HarborShapes.superellipse(
                      const BorderRadius.all(HarborShapes.md),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _workspaceActionButton(
                        key: const ValueKey('ai-history'),
                        icon: Icons.history_rounded,
                        label: '历史',
                        onPressed: task.running ? null : _openHistory,
                      ),
                    ),
                    if (widget.onSettings != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: _workspaceActionButton(
                          key: const ValueKey('ai-settings'),
                          icon: Icons.settings_outlined,
                          label: '设置',
                          onPressed: widget.onSettings,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: colors.outlineVariant),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Text(
                  'SSH 会话',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: _workspaceSessionList(context, selection)),
              if (selection?.selectingSession ?? false)
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The open SSH sessions, the current one highlighted. Selecting one asks the
  /// detached engine to mirror that session; the system window itself is reused.
  Widget _workspaceSessionList(
    BuildContext context,
    AiWindowSessionSelection? selection,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (selection == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          widget.hostName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final sessions = selection.sessions;
    if (sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          '暂无已打开的 SSH 会话',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('ai-session-list'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: sessions.length,
      itemBuilder: (context, index) =>
          _workspaceSessionTile(context, selection, sessions[index]),
    );
  }

  Widget _workspaceSessionTile(
    BuildContext context,
    AiWindowSessionSelection selection,
    AiWindowSession session,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = session.id == selection.sessionId;
    final selectable = !selected && !selection.selectingSession;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? colors.secondaryContainer
            : colors.surfaceContainerHighest,
        shape: HarborShapes.superellipse(BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('ai-session-${session.id}'),
          onTap: selectable
              ? () => unawaited(selection.selectSession(session.id))
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 16,
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.hostName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  session.endpoint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                _workspaceSessionStatus(context, session),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Connection and task state for one session: approval and running outrank a
  /// plain connection so the list shows what needs attention first.
  Widget _workspaceSessionStatus(
    BuildContext context,
    AiWindowSession session,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (label, icon, color) = session.waitingApproval
        ? ('等待审批', Icons.hourglass_top_rounded, colors.tertiary)
        : session.running
        ? ('运行中', Icons.bolt_rounded, colors.primary)
        : session.connected
        ? ('已连接', Icons.link_rounded, colors.secondary)
        : ('未连接', Icons.link_off_rounded, colors.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }

  /// Narrow-window session switcher: the same sessions as the rail, folded into
  /// one menu button that stays reachable in the header toolbar.
  Widget _workspaceSessionMenu(AiWindowSessionSelection selection) {
    final current = _workspaceCurrentSession(selection);
    return MenuAnchor(
      builder: (context, controller, child) => TextButton.icon(
        key: const ValueKey('ai-session-menu'),
        onPressed: selection.selectingSession
            ? null
            : (controller.isOpen ? controller.close : controller.open),
        icon: const Icon(Icons.dns_outlined, size: 18),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140),
          child: Text(
            current?.hostName ?? '切换会话',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: const Size(0, 40),
          shape: HarborShapes.superellipse(
            const BorderRadius.all(HarborShapes.sm),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      menuChildren: [
        if (Theme.of(context).windowBackdrop.frosted) const HarborSurfaceBlur(),
        for (final session in selection.sessions)
          MenuItemButton(
            key: ValueKey('ai-session-menu-${session.id}'),
            leadingIcon: Icon(
              session.id == selection.sessionId
                  ? Icons.check_rounded
                  : Icons.dns_outlined,
              size: 18,
            ),
            onPressed: () => unawaited(selection.selectSession(session.id)),
            child: Text('${session.hostName} · ${session.endpoint}'),
          ),
      ],
    );
  }

  AiWindowSession? _workspaceCurrentSession(
    AiWindowSessionSelection selection,
  ) {
    for (final session in selection.sessions) {
      if (session.id == selection.sessionId) return session;
    }
    return null;
  }

  /// Chat column: one reading-width stack with the transcript surface on top
  /// and the approval prompt plus composer pinned at the bottom.
  ///
  /// The bottom region is capped at a share of the column, so a short window
  /// with large text scrolls the composer and the approval prompt instead of
  /// overflowing the transcript off the screen.
  Widget _workspaceChat(
    BuildContext context,
    AiTaskController task,
    bool configured,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _workspaceReadingWidth),
        child: SizedBox(
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _workspaceSurface(context, task, configured)),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * _workspaceBottomShare,
                  ),
                  child: SingleChildScrollView(
                    child: _workspaceBottom(context, task),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _workspaceBottom(BuildContext context, AiTaskController task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final showFailure =
        task.failure != null &&
        (task.entries.isEmpty ||
            task.entries.last.notice != true ||
            task.entries.last.text != task.failure);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showFailure) ...[
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 72),
            child: SingleChildScrollView(
              child: Text(
                task.failure!,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ),
          ),
        ],
        if (task.pending != null) ...[
          const SizedBox(height: 12),
          _workspaceApproval(context, task),
        ],
        const SizedBox(height: 12),
        _composer(task),
      ],
    );
  }

  /// The transcript lives on its own tonal surface so the chat reads as one
  /// continuous sheet, separate from the composer below it.
  Widget _workspaceSurface(
    BuildContext context,
    AiTaskController task,
    bool configured,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).windowBackdrop.sheet(colors.surfaceContainerLow),
      shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.xl)),
      clipBehavior: Clip.antiAlias,
      child: _workspaceSurfaceContent(context, task, configured),
    );
  }

  Widget _workspaceSurfaceContent(
    BuildContext context,
    AiTaskController task,
    bool configured,
  ) {
    if (!configured) {
      return _workspaceCentered(
        children: [
          const Text('先在设置 → AI 配置模型服务', textAlign: TextAlign.center),
          if (widget.onSettings != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => widget.onSettings!(),
              child: const Text('打开设置'),
            ),
          ],
        ],
      );
    }
    if (task.entries.isEmpty) return _workspaceEmpty(context, task);
    final messages = _messageGroups(task.entries);
    return ListView.builder(
      key: const ValueKey('ai-transcript'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      itemCount: messages.length + (task.running ? 1 : 0),
      itemBuilder: (_, index) => index < messages.length
          ? _AiMessageBubble(
              key: ObjectKey(messages[index].first),
              entries: messages[index],
              standalone: true,
            )
          : _AiActivity(
              key: const ValueKey('ai-activity'),
              label: task.status,
              waiting: task.pending != null,
              startedAt: task.turnStartedAt,
            ),
    );
  }

  Widget _workspaceCentered({required List<Widget> children}) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );

  /// Empty transcript: the expressive mark plus three safe prompts. They only
  /// prefill the composer — nothing is sent or executed — and an existing
  /// draft is never overwritten.
  Widget _workspaceEmpty(BuildContext context, AiTaskController task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return _workspaceCentered(
      children: [
        const ExpressiveMark(
          size: 76,
          flower: true,
          icon: Icons.auto_awesome_rounded,
        ),
        const SizedBox(height: 20),
        Text('开始一段对话', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '描述你的目标，AI 会在 ${widget.hostName} 上执行命令并汇报结果。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _input,
          builder: (context, value, _) {
            final blocked = task.running || value.text.trim().isNotEmpty;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final (index, suggestion) in _workspaceSuggestions.indexed)
                  OutlinedButton(
                    key: ValueKey('ai-suggestion-$index'),
                    onPressed: blocked ? null : () => _prefillDraft(suggestion),
                    style: OutlinedButton.styleFrom(
                      shape: HarborShapes.superellipse(
                        const BorderRadius.all(HarborShapes.md),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    child: Text(suggestion, textAlign: TextAlign.center),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Approval prompt in its own tonal area above the composer: the command
  /// scrolls on its own while both decisions stay visible. The approval mode
  /// itself stays in the composer's options row, so only one mode control is
  /// ever on screen.
  Widget _workspaceApproval(BuildContext context, AiTaskController task) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final pending = task.pending!;
    return Material(
      color: colors.surfaceContainerHigh,
      shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.xl)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.gpp_maybe_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '需要审批',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(pending.reason, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: ShapeDecoration(
                color: colors.surfaceContainerLow,
                shape: HarborShapes.superellipse(
                  const BorderRadius.all(HarborShapes.sm),
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      pending.command,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
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
          ],
        ),
      ),
    );
  }

  /// Prefills the composer without sending, executing or replacing a draft.
  void _prefillDraft(String text) {
    if (widget.task.running) return;
    if (_input.text.trim().isNotEmpty) return;
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Leading block of the model menu. The slider is a session-level override:
/// every step calls [AiTaskController.setReasoningEffort] immediately, so the
/// menu stays open while the model, the composer draft and the panel state are
/// untouched. Dragged values are mirrored locally only for the duration of the
/// gesture, so a controller rebuild cannot fight the thumb.
class _ReasoningEffortSection extends StatefulWidget {
  const _ReasoningEffortSection({required this.task});

  final AiTaskController task;

  @override
  State<_ReasoningEffortSection> createState() =>
      _ReasoningEffortSectionState();
}

class _ReasoningEffortSectionState extends State<_ReasoningEffortSection> {
  AiReasoningEffort? _dragValue;

  static AiReasoningEffort _at(double value) =>
      AiReasoningEffort.values[value
          .round()
          .clamp(0, AiReasoningEffort.values.length - 1)
          .toInt()];

  void _select(double value) {
    final next = _at(value);
    setState(() => _dragValue = next);
    widget.task.setReasoningEffort(next);
  }

  void _commit(double value) {
    widget.task.setReasoningEffort(_at(value));
    setState(() => _dragValue = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final effort = _dragValue ?? widget.task.reasoningEffort;
    final enabled = !widget.task.running;
    final last = AiReasoningEffort.values.length - 1;
    final index = AiReasoningEffort.values.indexOf(effort);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 2,
            children: [
              Text('思考等级', style: theme.textTheme.labelLarge),
              Text(
                effort.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.primary,
                ),
              ),
            ],
          ),
          Slider(
            key: const ValueKey('ai-reasoning-effort-slider'),
            padding: EdgeInsets.zero,
            value: index.toDouble(),
            max: last.toDouble(),
            divisions: last,
            label: effort.label,
            semanticFormatterCallback: (value) => '思考等级 ${_at(value).label}',
            onChanged: enabled ? _select : null,
            onChangeEnd: enabled ? _commit : null,
          ),
          const Divider(height: 20),
        ],
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
  const _AiMessageBubble({
    super.key,
    required this.entries,
    this.standalone = false,
  });

  /// The bubble's entries in order; the first one decides user/notice/model.
  final List<AiTaskEntry> entries;

  /// Standalone workbench transcript: the bubble aligns to its own side and is
  /// capped by [_bubbleMaxUserWidth]/[_bubbleMaxAssistantWidth]. The embedded
  /// panel and the read-only history keep the full-width layout.
  final bool standalone;

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
    final user = entry.user == true;
    final bubble = Material(
      key: ObjectKey(entry),
      color: user ? colors.secondaryContainer : colors.surfaceContainerHigh,
      shape: HarborShapes.superellipse(BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!user) ...[
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
    );
    if (!widget.standalone) {
      return Padding(
        padding: EdgeInsets.only(bottom: 16, left: user ? 20 : 0),
        child: bubble,
      );
    }
    // The standalone workbench reads as a chat: the user writes on the right,
    // the assistant answers on the left, and neither side runs the full width.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = math.min(
            user ? _bubbleMaxUserWidth : _bubbleMaxAssistantWidth,
            constraints.maxWidth *
                (user ? _bubbleMaxUserShare : _bubbleMaxAssistantShare),
          );
          return Align(
            alignment: user ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: bubble,
            ),
          );
        },
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
      final confirmed = await showExpressiveDialog<bool>(
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
    final confirmed = await showExpressiveDialog<bool>(
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

/// Narrowest embedded panel that still leaves the composer its own compact
/// layout; narrower than this the model and approval controls have no room.
const _aiPanelMinWidth = 320.0;

/// Widest embedded panel, so the transcript keeps a readable measure instead of
/// spreading one chat bubble across the whole pane.
const _aiPanelMaxWidth = 720.0;

/// The terminal never gives up more than this, no matter where the handle lands.
const _aiPanelMinTerminalWidth = 280.0;

/// Width of the drag strip between terminal and panel; it also carries the
/// divider, so the 8px gap doubles as the grab area.
const _aiPanelHandleWidth = 8.0;

/// One accessibility nudge, matching the sidebar's resize handle.
const _aiPanelResizeStep = 16.0;

/// Keeps terminal and composer state across desktop split and compact AI views.
/// The split width lives here for the life of the element, so closing and
/// re-opening the panel, docking it, or crossing the compact breakpoint keeps
/// the width the user chose.
class TerminalAiLayout extends StatefulWidget {
  const TerminalAiLayout({super.key, required this.terminal, this.panel});

  final Widget terminal;
  final Widget? panel;

  @override
  State<TerminalAiLayout> createState() => _TerminalAiLayoutState();
}

class _TerminalAiLayoutState extends State<TerminalAiLayout> {
  /// Width the user dragged to, or null while the panel keeps the automatic
  /// share of the pane (40%, clamped to 320..440).
  double? _width;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final maxWidth = constraints.maxWidth;
      final horizontal = maxWidth >= 800;
      final hidden = !horizontal && widget.panel != null;
      // Boundaries hold at the breakpoint: 800px always leaves the panel at
      // least 320 wide and the terminal at least 280.
      final upper = math.min(
        _aiPanelMaxWidth,
        maxWidth - _aiPanelHandleWidth - _aiPanelMinTerminalWidth,
      );
      final lower = math.min(_aiPanelMinWidth, upper);
      final panelWidth = horizontal
          ? (_width ?? (maxWidth * .4).clamp(320.0, 440.0)).clamp(lower, upper)
          : maxWidth;
      final terminalWidth = horizontal && widget.panel != null
          ? maxWidth - panelWidth - _aiPanelHandleWidth
          : maxWidth;

      // Clamping the stored width keeps a drag that overshoots a boundary from
      // sticking there: dragging back moves the panel on the next delta.
      void resize(double next) {
        final clamped = next.clamp(lower, upper);
        if (clamped == _width) return;
        setState(() => _width = clamped);
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            key: const ValueKey('ai-layout-terminal'),
            left: 0,
            top: 0,
            bottom: 0,
            width: terminalWidth,
            child: Offstage(
              offstage: hidden,
              child: TickerMode(
                enabled: !hidden,
                child: ExcludeFocus(excluding: hidden, child: widget.terminal),
              ),
            ),
          ),
          if (widget.panel != null) ...[
            // Only the split view gets a handle; the compact view is a single
            // full-width column, so there is nothing to size.
            if (horizontal)
              Positioned(
                key: const ValueKey('ai-layout-resize'),
                left: terminalWidth,
                top: 0,
                bottom: 0,
                width: _aiPanelHandleWidth,
                child: Semantics(
                  label: '调整 AI 面板宽度',
                  value: '${panelWidth.round()}',
                  increasedValue:
                      '${(panelWidth + _aiPanelResizeStep).clamp(lower, upper).round()}',
                  decreasedValue:
                      '${(panelWidth - _aiPanelResizeStep).clamp(lower, upper).round()}',
                  onIncrease: () => resize(panelWidth + _aiPanelResizeStep),
                  onDecrease: () => resize(panelWidth - _aiPanelResizeStep),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                      key: const ValueKey('ai-panel-resize-handle'),
                      behavior: HitTestBehavior.opaque,
                      // Anchor on the width actually on screen, so a drag that
                      // starts after a clamp continues from the visible edge.
                      onHorizontalDragStart: (_) => _width = panelWidth,
                      // The panel is on the right: dragging left widens it.
                      onHorizontalDragUpdate: (details) =>
                          resize((_width ?? panelWidth) - details.delta.dx),
                      onDoubleTap: () => setState(() => _width = null),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(
                          width: 1,
                          height: double.infinity,
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              key: const ValueKey('ai-layout-panel'),
              right: 0,
              top: 0,
              bottom: 0,
              width: panelWidth,
              child: widget.panel!,
            ),
          ],
        ],
      );
    },
  );
}
