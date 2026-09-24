import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../data/ssh_connection.dart';
import '../data/remote_metrics.dart';
import '../data/web_link.dart';
import '../data/terminal_ai.dart';
import 'ai_task_controller.dart';
import 'remote_status_bar.dart';
import 'terminal_ai_panel.dart';
import 'terminal_links.dart';
import 'terminal_completion.dart';
import 'terminal_theme.dart';
import 'file_browser.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.session,
    required this.onReconnect,
    this.onClose,
    this.onOpenLink,
    this.controller,
    this.showHeader = true,
    this.onFiles,
    this.headerTitle,
    this.headerActions = const [],
    this.autofocus = true,
    this.onFocused,
    this.maxErrorHeight = 180,
    this.fontSize = 14,
    this.terminalWrap = true,
    this.statusRefreshSeconds = 5,
    this.statusVisible = true,
    this.aiSettings,
    this.onAiSettings,
  });
  final SshConnection session;
  final VoidCallback onReconnect;
  final VoidCallback? onClose;
  final Future<void> Function(Uri)? onOpenLink;
  final TerminalPaneController? controller;
  final bool showHeader;
  final VoidCallback? onFiles;
  final Widget? headerTitle;
  final List<Widget> headerActions;
  final bool autofocus;
  final VoidCallback? onFocused;
  final double maxErrorHeight;
  final double fontSize;
  final bool terminalWrap;
  final int statusRefreshSeconds;

  /// Whether this pane is actually on screen; hidden panes stop sampling and
  /// hide the status strip without losing the terminal buffer.
  final bool statusVisible;
  final AiSettings Function()? aiSettings;
  final VoidCallback? onAiSettings;
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  AiTaskController? _ai;
  bool _aiOpen = false;

  void _openAi() {
    if (widget.aiSettings == null) return;
    if (_aiOpen) {
      _closeAi();
      return;
    }
    _completion?.dismiss();
    _ai ??= AiTaskController(
      settings: () => widget.aiSettings!(),
      executorFactory: () => widget.session.createAiExecutor(),
      connected: () => widget.session.status == ConnectionStatus.connected,
    );
    setState(() => _aiOpen = true);
  }

  void _closeAi() {
    _ai?.stop();
    setState(() => _aiOpen = false);
    _focus.requestFocus();
  }

  final _controller = TerminalController();
  final _focus = FocusNode();
  final _terminalKey = GlobalKey<TerminalViewState>();
  final _scrollController = ScrollController();
  final _linkStyle = TerminalLinkStyle(const Color(0xff9ecaff));

  late double _fontSize = widget.fontSize.clamp(10, 24).toDouble();
  PointerDownEvent? _linkDown;
  Uri? _pressedLink;
  Offset? _hoverPosition;
  bool _hoverRefreshPending = false;
  TerminalCompletion? _completion;
  final _completionStackKey = GlobalKey();
  Rect? _completionCaret;
  bool _completionGeometryPending = false;

  // Remote metrics use a configurable single-flight timer that runs only
  // while this pane is visible and connected. Results carry a generation so
  // a rebind, disconnect or hide discards anything that lands late instead
  // of painting stale values into the status strip.
  Timer? _metricsTimer;
  RemoteMetricsSample? _metricsSample;
  RemoteHostMetrics? _metrics;
  bool _metricsLoading = false;
  bool _metricsInFlight = false;
  int _metricsGeneration = 0;

  bool get _metricsEligible =>
      widget.statusVisible &&
      widget.session.status == ConnectionStatus.connected;

  void _syncMetrics() {
    if (!mounted || !_metricsEligible) {
      _stopMetrics();
      return;
    }
    _metricsTimer ??= Timer.periodic(
      Duration(seconds: widget.statusRefreshSeconds),
      (_) => _sampleMetrics(),
    );
    if (_metrics == null && !_metricsInFlight) unawaited(_sampleMetrics());
  }

  void _stopMetrics({bool notify = true}) {
    _metricsTimer?.cancel();
    _metricsTimer = null;
    // Invalidate any in-flight probe so its result is dropped.
    _metricsGeneration++;
    final wasVisible = _metrics != null || _metricsLoading;
    _metrics = null;
    _metricsSample = null;
    _metricsLoading = false;
    if (notify && wasVisible && mounted) setState(() {});
  }

  Future<void> _sampleMetrics() async {
    if (_metricsInFlight) return;
    if (!mounted || !_metricsEligible) return;
    _metricsInFlight = true;
    final generation = _metricsGeneration;
    final session = widget.session;
    setState(() => _metricsLoading = true);
    RemoteMetricsSample? sample;
    try {
      sample = await session.readRemoteMetrics();
    } catch (_) {
      sample = null;
    }
    _metricsInFlight = false;
    if (!mounted || generation != _metricsGeneration) return;
    setState(() {
      _metricsLoading = false;
      if (sample == null) {
        // Never fabricate zeros: drop the strip back to "unavailable".
        _metrics = null;
        _metricsSample = null;
      } else {
        _metrics = RemoteHostMetrics.fromSamples(sample, _metricsSample);
        _metricsSample = sample;
      }
    });
  }

  void _queueCompletionGeometry() {
    if (_completionGeometryPending || _completion?.entries.isNotEmpty != true) {
      return;
    }
    _completionGeometryPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _completionGeometryPending = false;
      if (!mounted || _completion?.entries.isNotEmpty != true) return;
      final state = _terminalKey.currentState;
      final box =
          _completionStackKey.currentContext?.findRenderObject() as RenderBox?;
      if (state == null || box == null || !box.attached) return;
      final caret = state.globalCursorRect;
      final local = box.globalToLocal(caret.topLeft) & caret.size;
      if (local != _completionCaret) setState(() => _completionCaret = local);
    });
  }

  void _completionChanged() {
    if (mounted) setState(() {});
  }

  void _bindCompletion() {
    _completion ??= TerminalCompletion(widget.session)
      ..addListener(_completionChanged);
    _focus.removeListener(_completionChanged);
    _focus.addListener(_completionChanged);
    _scrollController.removeListener(_queueCompletionGeometry);
    _scrollController.addListener(_queueCompletionGeometry);
  }

  Widget _completionPopup(BoxConstraints constraints) {
    final completion = _completion;
    if (completion == null || completion.entries.isEmpty || !_focus.hasFocus) {
      return const SizedBox.shrink();
    }
    _queueCompletionGeometry();
    final caret = _completionCaret;
    if (caret == null) return const SizedBox.shrink();
    final point = caret.bottomLeft;
    if (point.dy < 0 || point.dy > constraints.maxHeight) {
      return const SizedBox.shrink();
    }
    final availableWidth = constraints.maxWidth - 16;
    final width = availableWidth.clamp(
      0.0,
      completion.hasDescriptions && availableWidth >= 520 ? 568.0 : 320.0,
    );
    final height = completion.popupHeight(width);
    final below = point.dy + 4;
    final top = below + height <= constraints.maxHeight
        ? below
        : (point.dy - caret.height - height - 4).clamp(
            4.0,
            constraints.maxHeight,
          );
    return Positioned(
      left: point.dx.clamp(
        8.0,
        (constraints.maxWidth - width - 8).clamp(8.0, double.infinity),
      ),
      top: top,
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (constraints.maxHeight - top - 4).clamp(0.0, height),
        ),
        child: TapRegion(
          onTapOutside: (_) => completion.dismiss(),
          child: TerminalCompletionList(
            completion: completion,
            onAccept: (index) {
              completion.accept(index);
              _focus.requestFocus();
            },
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _focus.addListener(_reportFocus);
    _listenForLinkHover();
    _applyLineWrap();
    _syncMetrics();
  }

  void _reportFocus() {
    if (_focus.hasFocus) widget.onFocused?.call();
  }

  void _listenForLinkHover() {
    widget.session.removeListener(_connectionChanged);
    widget.session.addListener(_connectionChanged);
    _bindCompletion();
    HardwareKeyboard.instance.removeHandler(_handleHoverKey);
    HardwareKeyboard.instance.addHandler(_handleHoverKey);
    _scrollController.removeListener(_scheduleHoverRefresh);
    _scrollController.addListener(_scheduleHoverRefresh);
    widget.session.terminal.removeListener(_scheduleHoverRefresh);
    widget.session.terminal.addListener(_scheduleHoverRefresh);
  }

  void _connectionChanged() {
    if (widget.session.status != ConnectionStatus.connected) {
      _ai?.stop(message: 'SSH 已断开，AI 任务已停止');
    }
    _syncMetrics();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Rebuild transient candidates after code changes while keeping the SSH
    // session, terminal buffer and command history alive.
    _completion?.dispose();
    _completion = null;
    _completionCaret = null;
    widget.controller?._state = this;
    _listenForLinkHover();
    // Samples retained by hot reload may predate added metric fields.
    _stopMetrics(notify: false);
    _syncMetrics();
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.controller?._state = this;
    _applyLineWrap();
    if (oldWidget.fontSize != widget.fontSize) {
      _fontSize = widget.fontSize;
    }
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_connectionChanged);
      widget.session.addListener(_connectionChanged);
      _ai?.dispose();
      _ai = null;
      _aiOpen = false;
      _completion?.dispose();
      _completion = null;
      _bindCompletion();
      oldWidget.session.terminal.removeListener(_scheduleHoverRefresh);
      widget.session.terminal.addListener(_scheduleHoverRefresh);
      _hoverPosition = null;
      // A different session invalidates the previous counters entirely.
      _stopMetrics();
      _syncMetrics();
    } else if (oldWidget.statusVisible != widget.statusVisible ||
        oldWidget.statusRefreshSeconds != widget.statusRefreshSeconds) {
      if (oldWidget.statusRefreshSeconds != widget.statusRefreshSeconds) {
        _metricsTimer?.cancel();
        _metricsTimer = null;
      }
      _syncMetrics();
    }
  }

  void _applyLineWrap() {
    widget.session.terminal.lineWrap = widget.terminalWrap;
  }

  bool _handleHoverKey(KeyEvent event) {
    if (mounted &&
        (event.logicalKey == LogicalKeyboardKey.controlLeft ||
            event.logicalKey == LogicalKeyboardKey.controlRight)) {
      setState(() {});
    }
    return false;
  }

  void _scheduleHoverRefresh() {
    if (_hoverPosition == null || _hoverRefreshPending) return;
    _hoverRefreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hoverRefreshPending = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stopMetrics(notify: false);
    widget.session.removeListener(_connectionChanged);
    _ai?.dispose();
    _focus.removeListener(_completionChanged);
    _scrollController.removeListener(_queueCompletionGeometry);
    _completion?.dispose();
    if (widget.controller?._state == this) widget.controller?._state = null;
    HardwareKeyboard.instance.removeHandler(_handleHoverKey);
    widget.session.terminal.removeListener(_scheduleHoverRefresh);
    _scrollController.removeListener(_scheduleHoverRefresh);
    _controller.dispose();
    _focus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Uri? _linkAt(Offset globalPosition) {
    final render = _terminalKey.currentState?.renderTerminal;
    if (render == null) return null;
    final local = render.globalToLocal(globalPosition);
    if (!(Offset.zero & render.size).contains(local)) return null;
    final cell = render.getCellOffset(local);
    for (final link in terminalLinks(
      widget.session.terminal.buffer,
      cell.y,
      cell.y,
    )) {
      if (link.contains(cell)) return link.uri;
    }
    return null;
  }

  void _prepareLinkDecoration(int first, int last) {
    CellOffset? hover;
    final render = _terminalKey.currentState?.renderTerminal;
    if (_hoverPosition != null &&
        HardwareKeyboard.instance.isControlPressed &&
        render != null) {
      final local = render.globalToLocal(_hoverPosition!);
      if ((Offset.zero & render.size).contains(local)) {
        hover = render.getCellOffset(local);
      }
    }
    _linkStyle.prepare(
      widget.session.terminal.buffer,
      first,
      last,
      hover: hover,
    );
  }

  TerminalCellDecoration? _linkDecoration(int x, int y) {
    if (_controller.selection?.contains(CellOffset(x, y)) == true) {
      return null;
    }
    return _linkStyle.decoration(x, y);
  }

  void _selectOption(String value) {
    if (value == 'larger') {
      setState(() => _fontSize = (_fontSize + 1).clamp(10, 24));
    }
    if (value == 'smaller') {
      setState(() => _fontSize = (_fontSize - 1).clamp(10, 24));
    }
    if (value == 'copy') _copy();
    if (value == 'ai') _openAi();
    if (value == 'paste') _paste();
    if (value == 'disconnect') widget.session.close();
    if (value == 'close') widget.onClose?.call();
  }

  Future<void> _openLink(Uri uri) async {
    try {
      await (widget.onOpenLink ?? openWebLink)(uri);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接，请检查默认浏览器设置。')));
      }
    }
  }

  Future<void> _copyOrPaste() async {
    _completion?.dismiss();
    final selection = _controller.selection;
    if (selection != null && !selection.isCollapsed) {
      await _copy();
    } else {
      await _paste();
    }
  }

  Future<void> _copy() async {
    final selection = _controller.selection;
    if (selection == null) return;
    await Clipboard.setData(
      ClipboardData(text: widget.session.terminal.buffer.getText(selection)),
    );
    if (!mounted) return;
    _controller.clearSelection();
    _focus.requestFocus();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted ||
        data?.text == null ||
        widget.session.status != ConnectionStatus.connected) {
      return;
    }
    final text = data!.text!;
    if (text.contains('\n') || text.contains('\r')) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('粘贴多行内容？'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('换行可能使远程终端立即执行命令，请检查内容。'),
                  const SizedBox(height: 16),
                  SelectableText(
                    text.length > 2000
                        ? '${text.substring(0, 2000)}\n…（内容已截断）'
                        : text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('粘贴'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (widget.session.status == ConnectionStatus.connected) {
      widget.session.terminal.paste(text);
    }
    _focus.requestFocus();
  }

  Widget _terminalScrollbar(Widget child) {
    final behavior = ScrollConfiguration.of(context);
    // The scrollbar belongs to the panel edge, outside the text padding.
    return behavior.buildScrollbar(
      context,
      ScrollConfiguration(
        behavior: behavior.copyWith(scrollbars: false),
        child: child,
      ),
      ScrollableDetails(
        direction: AxisDirection.down,
        controller: _scrollController,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TerminalAiLayout(
    terminal: _buildTerminal(context),
    panel: _aiOpen && _ai != null
        ? TerminalAiPanel(
            task: _ai!,
            hostName: widget.session.host.name,
            onClose: _closeAi,
            onSettings: widget.onAiSettings,
          )
        : null,
  );

  Widget _buildTerminal(BuildContext context) {
    final session = widget.session;
    final connected = session.status == ConnectionStatus.connected;
    final colors = Theme.of(context).colorScheme;
    _linkStyle.color = colors.brightness == Brightness.dark
        ? const Color(0xff9ecaff)
        : const Color(0xff005bb5);
    final linkHoverPosition = HardwareKeyboard.instance.isControlPressed
        ? _hoverPosition
        : null;
    final hoveringLink =
        linkHoverPosition != null && _linkAt(linkHoverPosition) != null;

    return Column(
      children: [
        if (widget.showHeader)
          SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: connected ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child:
                        widget.headerTitle ??
                        Text(
                          session.host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1,
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                  ),
                  ...widget.headerActions,
                  if (widget.aiSettings != null)
                    IconButton(
                      key: const ValueKey('terminal-ai'),
                      isSelected: _aiOpen,
                      onPressed: _openAi,
                      icon: const Icon(
                        Icons.auto_awesome_outlined,
                        size: 20,
                        semanticLabel: 'AI 助手',
                      ),
                    ),
                  FileBrowserButton(
                    session: session,
                    onOpen: widget.onFiles,
                    onReturn: _focus.requestFocus,
                  ),
                  TerminalOptionsButton(
                    session: session,
                    controller: widget.controller,
                    onSelected: _selectOption,
                    hasSelection: () => _controller.selection != null,
                    canClose: widget.onClose != null,
                  ),
                ],
              ),
            ),
          ),
        Offstage(
          offstage: !widget.statusVisible,
          child: RemoteStatusBar(
            metrics: _metrics,
            connected: connected,
            loading: _metricsLoading,
          ),
        ),
        if (session.status == ConnectionStatus.connecting)
          const LinearProgressIndicator(minHeight: 2),
        if (session.error != null)
          Material(
            color: colors.errorContainer,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              constraints: BoxConstraints(maxHeight: widget.maxErrorHeight),
              child: SingleChildScrollView(
                child: SelectableText(
                  session.error!,
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ),
          ),
        if (session.status == ConnectionStatus.closed ||
            session.status == ConnectionStatus.failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '会话已结束，终端记录仍保留。',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: widget.onReconnect,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新连接'),
                ),
              ],
            ),
          ),
        Expanded(
          child: ColoredBox(
            color: colors.surfaceContainerLowest,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                key: _completionStackKey,
                fit: StackFit.expand,
                children: [
                  ListenableBuilder(
                    listenable: _controller,
                    builder: (context, _) => MouseRegion(
                      onEnter: (event) =>
                          setState(() => _hoverPosition = event.position),
                      onHover: (event) =>
                          setState(() => _hoverPosition = event.position),
                      onExit: (_) => setState(() => _hoverPosition = null),
                      child: Listener(
                        onPointerDown: (event) {
                          _linkDown = null;
                          _pressedLink = null;
                          if (event.buttons == kPrimaryMouseButton &&
                              HardwareKeyboard.instance.isControlPressed) {
                            _linkDown = event;
                            _pressedLink = _linkAt(event.position);
                          }
                        },
                        onPointerMove: (event) {
                          if (_linkDown?.pointer == event.pointer &&
                              (event.position - _linkDown!.position).distance >
                                  kTouchSlop) {
                            _pressedLink = null;
                          }
                        },
                        onPointerCancel: (_) {
                          _linkDown = null;
                          _pressedLink = null;
                        },
                        onPointerUp: (event) {
                          final uri = _pressedLink;
                          if (_linkDown?.pointer == event.pointer &&
                              uri != null &&
                              HardwareKeyboard.instance.isControlPressed &&
                              _linkAt(event.position) == uri) {
                            _openLink(uri);
                          }
                          _linkDown = null;
                          _pressedLink = null;
                        },
                        child: _terminalScrollbar(
                          TerminalView(
                            session.terminal,
                            key: _terminalKey,
                            scrollController: _scrollController,
                            mouseCursor: hoveringLink
                                ? SystemMouseCursors.click
                                : SystemMouseCursors.text,
                            controller: _controller,
                            focusNode: _focus,
                            autofocus: widget.autofocus,
                            onSecondaryTapUp: (_, _) => _copyOrPaste(),
                            readOnly: !connected,
                            shortcuts: const {},
                            deleteDetection: true,
                            theme: harborTerminalTheme(colors),
                            padding: const EdgeInsets.all(16),
                            onPrepareCellDecoration: _prepareLinkDecoration,
                            cellDecoration: _linkDecoration,
                            textStyle: TerminalStyle(
                              fontSize: _fontSize,
                              fontFamily: 'monospace',
                              fontFamilyFallback: const [
                                'Consolas',
                                'Menlo',
                                'Noto Sans Mono',
                                'Courier New',
                              ],
                            ),
                            onKeyEvent: (_, event) {
                              final completionResult = _completion?.handleKey(
                                event,
                              );
                              if (completionResult == KeyEventResult.handled) {
                                return KeyEventResult.handled;
                              }
                              final keys = HardwareKeyboard.instance;
                              // Ctrl-click belongs to the local link action, including
                              // when a remote program has enabled mouse reporting.
                              if (_controller.suspendedPointerInputs !=
                                  keys.isControlPressed) {
                                _controller.setSuspendPointerInput(
                                  keys.isControlPressed,
                                );
                              }
                              if (event is KeyDownEvent &&
                                  (event.logicalKey ==
                                          LogicalKeyboardKey.contextMenu ||
                                      (event.logicalKey ==
                                              LogicalKeyboardKey.f10 &&
                                          keys.isShiftPressed))) {
                                _copyOrPaste();
                                return KeyEventResult.handled;
                              }
                              if (event is KeyDownEvent &&
                                  (keys.isControlPressed ||
                                      keys.isMetaPressed)) {
                                if (event.logicalKey ==
                                    LogicalKeyboardKey.keyV) {
                                  _paste();
                                  return KeyEventResult.handled;
                                }
                                if (event.logicalKey ==
                                        LogicalKeyboardKey.keyC &&
                                    (keys.isShiftPressed ||
                                        keys.isMetaPressed)) {
                                  _copy();
                                  return KeyEventResult.handled;
                                }
                              }
                              return KeyEventResult.ignored;
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  _completionPopup(constraints),
                ],
              ),
            ),
          ),
        ),
        if (MediaQuery.sizeOf(context).width < 900)
          SafeArea(
            top: false,
            child: Material(
              color: colors.surfaceContainerLow,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    for (final entry in const <String, String>{
                      'Esc': '\x1b',
                      'Tab': '\t',
                      'Ctrl C': '\x03',
                      'Ctrl D': '\x04',
                      'Ctrl L': '\x0c',
                      '↑': '\x1b[A',
                      '↓': '\x1b[B',
                      '←': '\x1b[D',
                      '→': '\x1b[C',
                    }.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilledButton.tonal(
                          onPressed: connected
                              ? () {
                                  if (entry.key == 'Tab' &&
                                      _completion?.accept() == true) {
                                    _focus.requestFocus();
                                    return;
                                  }
                                  session.send(entry.value);
                                  _focus.requestFocus();
                                }
                              : null,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            visualDensity: VisualDensity.standard,
                            textStyle: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          child: Text(entry.key),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Shares terminal actions with the mobile app bar without moving terminal state.
class TerminalPaneController {
  _TerminalPaneState? _state;
  bool get hasSelection => _state?._controller.selection != null;
  void selectOption(String value) => _state?._selectOption(value);
  void requestFocus() => _state?._focus.requestFocus();
}

class TerminalOptionsButton extends StatelessWidget {
  const TerminalOptionsButton({
    super.key,
    required this.session,
    this.controller,
    this.onSelected,
    this.hasSelection,
    this.canClose = false,
  });
  final SshConnection session;
  final TerminalPaneController? controller;
  final ValueChanged<String>? onSelected;
  final bool Function()? hasSelection;
  final bool canClose;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '终端选项',
    onSelected: onSelected ?? controller!.selectOption,
    itemBuilder: (_) => [
      if (MediaQuery.sizeOf(context).width < 900) ...[
        PopupMenuItem(
          value: 'copy',
          enabled: (hasSelection?.call() ?? controller?.hasSelection ?? false),
          child: const Text('复制'),
        ),
        PopupMenuItem(
          value: 'paste',
          enabled: session.status == ConnectionStatus.connected,
          child: const Text('粘贴'),
        ),
      ],
      const PopupMenuItem(value: 'larger', child: Text('增大字体')),
      const PopupMenuItem(value: 'smaller', child: Text('缩小字体')),
      if (canClose) const PopupMenuItem(value: 'close', child: Text('关闭会话')),
      if (session.status == ConnectionStatus.connected)
        const PopupMenuItem(value: 'disconnect', child: Text('断开连接')),
    ],
  );
}
