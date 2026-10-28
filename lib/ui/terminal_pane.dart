import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../data/ai_conversation_store.dart';
import '../data/ssh_connection.dart';
import '../data/remote_metrics.dart';
import '../data/web_link.dart';
import '../data/terminal_ai.dart';
import 'expressive_widgets.dart';
import 'ai_task_controller.dart';
import 'ai_window_bridge.dart';
import 'remote_status_bar.dart';
import 'terminal_ai_panel.dart';
import 'terminal_links.dart';
import 'terminal_completion.dart';
import 'terminal_theme.dart';
import 'theme.dart';
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
    this.onPortForward,
    this.headerTitle,
    this.headerActions = const [],
    this.autofocus = true,
    this.onFocused,
    this.maxErrorHeight = 180,
    this.fontSize = 14,
    this.fontFamily = '',
    this.terminalWrap = true,
    this.statusRefreshSeconds = 5,
    this.statusVisible = true,
    this.aiSettings,
    this.persistAiModel,
    this.onAiSettings,
    this.aiHistoryStore,
    this.aiWindow,
    this.aiRetention,
    this.aiPanelWidth,
    this.aiPanelWidthRevision = 0,
    this.onAiPanelWidthChanged,
  });
  final SshConnection session;
  final VoidCallback onReconnect;
  final VoidCallback? onClose;
  final Future<void> Function(Uri)? onOpenLink;
  final TerminalPaneController? controller;
  final bool showHeader;
  final VoidCallback? onFiles;
  final VoidCallback? onPortForward;
  final Widget? headerTitle;
  final List<Widget> headerActions;
  final bool autofocus;
  final VoidCallback? onFocused;
  final double maxErrorHeight;
  final double fontSize;

  /// Preferred terminal font family; empty uses the platform monospace font.
  final String fontFamily;
  final bool terminalWrap;
  final int statusRefreshSeconds;

  /// Whether this pane is actually on screen; hidden panes stop sampling and
  /// hide the status strip without losing the terminal buffer.
  final bool statusVisible;
  final AiSettings Function()? aiSettings;

  /// Saves an explicitly chosen assistant model as this machine's model, so
  /// the next session or a restart starts from it. Null keeps the choice
  /// session-scoped.
  final Future<void> Function(String model)? persistAiModel;
  final VoidCallback? onAiSettings;
  final AiConversationStore? aiHistoryStore;
  final AiWindowHost? aiWindow;

  /// When set, the assistant controller and whether its panel is open survive
  /// this pane being unmounted, so switching back to the session restores them.
  final TerminalAiRetention? aiRetention;

  /// Saved width of the embedded assistant panel, and the revision of the
  /// appearance prefs it came from. A pane adopts a restored value only once,
  /// and never while the user is dragging its handle.
  final double? aiPanelWidth;
  final int aiPanelWidthRevision;
  final ValueChanged<double?>? onAiPanelWidthChanged;
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  AiTaskController? _ai;
  bool _aiOpen = false;
  bool _aiDetached = false;

  void _openAi() {
    if (widget.aiSettings == null) return;
    if (_aiDetached) {
      // The assistant is already running in the other window. Bring that
      // panel back here instead of stopping the turn.
      unawaited(widget.aiWindow?.dock(widget.session.id));
      return;
    }
    if (_aiOpen) {
      _closeAi();
      return;
    }
    _completion?.dismiss();
    _ensureAi();
    setState(() => _aiOpen = true);
  }

  void _ensureAi() {
    if (_ai != null) return;
    final settings = widget.aiSettings;
    if (settings == null) return;
    final session = widget.session;
    final retention = widget.aiRetention;
    final historyStore = widget.aiHistoryStore;
    final historyScope = historyStore == null
        ? null
        : '${session.host.id}|${session.host.endpoint}|${session.host.username}';
    if (retention == null) {
      _ai = AiTaskController(
        settings: () => widget.aiSettings!(),
        executorFactory: () => widget.session.createAiExecutor(),
        connected: () => widget.session.status == ConnectionStatus.connected,
        historyStore: historyStore,
        historyScope: historyScope,
        persistModel: widget.persistAiModel,
      );
    } else {
      // Closures capture the session object, not this State: the controller
      // keeps running after the pane is unmounted.
      _ai = retention.create(
        sessionId: session.id,
        settings: settings,
        executorFactory: () => session.createAiExecutor(),
        connected: () => session.status == ConnectionStatus.connected,
        historyStore: historyStore,
        historyScope: historyScope,
        persistModel: widget.persistAiModel,
      );
    }
    _registerAi();
  }

  void _claimAi() {
    final retention = widget.aiRetention;
    if (retention == null) return;
    final session = widget.session;
    final restored = retention.claim(
      session.id,
      settings: widget.aiSettings,
      executorFactory: () => session.createAiExecutor(),
      connected: () => session.status == ConnectionStatus.connected,
      persistModel: widget.persistAiModel,
    );
    if (restored == null) return;
    _ai = restored.task;
    _aiOpen = restored.open;
    _aiDetached = widget.aiWindow?.isDetached(session.id) ?? restored.detached;
    _registerAi();
  }

  void _retargetAi() {
    final retention = widget.aiRetention;
    final session = widget.session;
    if (retention == null || _ai == null) return;
    retention.retarget(
      session.id,
      settings: widget.aiSettings,
      executorFactory: () => session.createAiExecutor(),
      connected: () => session.status == ConnectionStatus.connected,
      persistModel: widget.persistAiModel,
    );
  }

  /// Parks a still-living session's assistant, or tears it down when the
  /// session itself is gone. The session is explicit because a pane can be
  /// handed a different connection before this runs.
  void _releaseAi(
    SshConnection session, {
    required TerminalAiRetention? retention,
    required AiWindowHost? host,
    required VoidCallback? onSettings,
    required AiSettings Function()? settings,
    required Future<void> Function(String model)? persistModel,
  }) {
    final task = _ai;
    if (task != null && retention != null && retention.keeps(session.id)) {
      retention.park(
        session.id,
        open: _aiOpen,
        detached: _aiDetached,
        session: session,
        settings: settings,
        executorFactory: () => session.createAiExecutor(),
        connected: () => session.status == ConnectionStatus.connected,
        persistModel: persistModel,
      );
      host?.register(
        session.id,
        task,
        session.host.name,
        onDock: () => retention.noteDocked(session.id),
        onSettings: onSettings,
      );
    } else if (task != null && retention != null) {
      host?.unregister(session.id);
      retention.drop(session.id);
    } else if (task != null) {
      host?.unregister(session.id);
      task.dispose();
    }
    // A pane that owns no controller must not unregister one the workspace
    // created lazily for the detached window.
    _ai = null;
    _aiOpen = false;
    _aiDetached = false;
  }

  void _registerAi() {
    final task = _ai;
    final host = widget.aiWindow;
    if (task == null || host == null) return;
    host.register(
      widget.session.id,
      task,
      widget.session.host.name,
      onDock: _aiDocked,
      onSettings: widget.onAiSettings,
    );
  }

  void _aiDocked() {
    if (!mounted) return;
    setState(() {
      _aiOpen = true;
      _aiDetached = false;
    });
  }

  /// The main window's AI host moved the detached window (or closed it). Only
  /// the mirrored session keeps its panel hidden; every other pane must show
  /// its embedded panel again, so no two places render the same conversation.
  void _aiHostChanged() {
    if (!mounted) return;
    final detached = widget.aiWindow?.isDetached(widget.session.id) ?? false;
    if (detached && _ai == null) {
      // The workspace materialized this session's controller so the detached
      // window could show it; adopt the very same instance here.
      _claimAi();
    }
    if (detached == _aiDetached) return;
    _applyDetached(detached);
  }

  void _applyDetached(bool detached) {
    if (!mounted || detached == _aiDetached) return;
    // A notification can land while another widget builds; deferring the
    // rebuild keeps the framework from throwing mid-build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || detached == _aiDetached) return;
        setState(() {
          _aiDetached = detached;
          if (detached) _aiOpen = true;
        });
      });
      return;
    }
    setState(() {
      _aiDetached = detached;
      if (detached) _aiOpen = true;
    });
  }

  Future<void> _detachAi() async {
    final host = widget.aiWindow;
    if (host == null || _ai == null || _aiDetached) return;
    setState(() => _aiDetached = true);
    await host.open(widget.session.id);
    if (!mounted) return;
    final detached = host.isDetached(widget.session.id);
    if (detached != _aiDetached) setState(() => _aiDetached = detached);
  }

  void _closeAi() {
    // Closing or docking the separate window must not cancel the turn. The
    // embedded close button is the only control that stops it.
    if (_aiDetached) return;
    _ai?.stop();
    setState(() => _aiOpen = false);
    _focus.requestFocus();
  }

  final _controller = TerminalController();
  final _focus = FocusNode();
  final _terminalKey = GlobalKey<TerminalViewState>();
  final _scrollController = ScrollController();
  final _linkStyle = TerminalLinkStyle(const Color(0xff9ecaff));

  // TerminalView rebuilds replace the render object's theme and text style.
  // Both classes carry no value equality, so a freshly built instance clears
  // the painter's paragraph cache even when nothing visual changed. Reuse the
  // same instances across hover, completion and output rebuilds and only
  // rebuild them when the actual colors or font change.
  TerminalTheme? _cachedTerminalTheme;
  ColorScheme? _cachedTerminalColors;
  TerminalStyle? _cachedTerminalTextStyle;
  String? _cachedTerminalFontFamily;

  late double _fontSize = widget.fontSize.clamp(10, 24).toDouble();
  PointerDownEvent? _linkDown;
  Uri? _pressedLink;
  int? _secondaryPointer;

  void _syncPointerInput() {
    final suspend =
        _secondaryPointer != null || HardwareKeyboard.instance.isControlPressed;
    if (_controller.suspendedPointerInputs != suspend) {
      _controller.setSuspendPointerInput(suspend);
    }
  }

  void _releaseSecondaryPointer(PointerEvent event) {
    if (_secondaryPointer != event.pointer) return;
    // TapUp callbacks run during this pointer dispatch. Keep remote mouse
    // reporting suspended until the local copy/paste action has won the tap.
    scheduleMicrotask(() {
      if (!mounted || _secondaryPointer != event.pointer) return;
      _secondaryPointer = null;
      _syncPointerInput();
    });
  }

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
  //
  // CPU and transfer rates need two samples. The periodic timer waits a full
  // interval before its first tick, so the first pair is closed after one
  // second instead of the configured cadence.
  static const _metricsPrimeDelay = Duration(seconds: 1);
  Timer? _metricsTimer;
  Timer? _metricsPrimeTimer;
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
    _metricsPrimeTimer?.cancel();
    _metricsPrimeTimer = null;
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
    final hadBaseline = _metricsSample != null;
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
    if (sample != null && !hadBaseline) _schedulePrimeSample();
  }

  void _schedulePrimeSample() {
    if (widget.statusRefreshSeconds <= _metricsPrimeDelay.inSeconds) return;
    _metricsPrimeTimer?.cancel();
    _metricsPrimeTimer = Timer(_metricsPrimeDelay, () {
      _metricsPrimeTimer = null;
      if (!mounted || !_metricsEligible || _metricsInFlight) return;
      unawaited(_sampleMetrics());
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
    _claimAi();
    widget.aiWindow?.addListener(_aiHostChanged);
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
      _releaseAi(
        oldWidget.session,
        retention: oldWidget.aiRetention,
        host: oldWidget.aiWindow,
        onSettings: oldWidget.onAiSettings,
        settings: oldWidget.aiSettings,
        persistModel: oldWidget.persistAiModel,
      );
      _claimAi();
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
    } else if (oldWidget.aiWindow != widget.aiWindow) {
      oldWidget.aiWindow?.removeListener(_aiHostChanged);
      oldWidget.aiWindow?.unregister(widget.session.id);
      widget.aiWindow?.addListener(_aiHostChanged);
      _aiDetached = false;
      _registerAi();
      _aiHostChanged();
    }
    if (oldWidget.session == widget.session) _retargetAi();
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
    widget.aiWindow?.removeListener(_aiHostChanged);
    _releaseAi(
      widget.session,
      retention: widget.aiRetention,
      host: widget.aiWindow,
      onSettings: widget.onAiSettings,
      settings: widget.aiSettings,
      persistModel: widget.persistAiModel,
    );
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
    return _linkStyle.linkAt(widget.session.terminal.buffer, cell);
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
    // Most cells are not links; checking the decoration first keeps the
    // selection lookup off that common path.
    final decoration = _linkStyle.decoration(x, y);
    if (decoration == null) return null;
    if (_controller.selection?.contains(CellOffset(x, y)) == true) {
      return null;
    }
    return decoration;
  }

  TerminalTheme _terminalTheme(ColorScheme colors) {
    final cached = _cachedTerminalTheme;
    if (cached != null && _cachedTerminalColors == colors) return cached;
    _cachedTerminalColors = colors;
    return _cachedTerminalTheme = harborTerminalTheme(colors);
  }

  TerminalStyle get _terminalTextStyle {
    final cached = _cachedTerminalTextStyle;
    if (cached != null &&
        cached.fontSize == _fontSize &&
        _cachedTerminalFontFamily == widget.fontFamily) {
      return cached;
    }
    _cachedTerminalFontFamily = widget.fontFamily;
    return _cachedTerminalTextStyle = harborTerminalTextStyle(
      fontSize: _fontSize,
      fontFamily: widget.fontFamily,
    );
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
    if (value == 'forward') widget.onPortForward?.call();
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
      final confirmed = await showExpressiveDialog<bool>(
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
              autofocus: true,
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
    preferredPanelWidth: widget.aiPanelWidth,
    preferenceRevision: widget.aiPanelWidthRevision,
    onPanelWidthChanged: widget.onAiPanelWidthChanged,
    terminal: _buildTerminal(context),
    panel: _aiOpen && !_aiDetached && _ai != null
        ? TerminalAiPanel(
            task: _ai!,
            hostName: widget.session.host.name,
            onClose: _closeAi,
            onSettings: widget.onAiSettings,
            onDetach: widget.aiWindow == null
                ? null
                : () => unawaited(_detachAi()),
          )
        : null,
  );

  Widget _buildTerminal(BuildContext context) {
    final session = widget.session;
    final connected = session.status == ConnectionStatus.connected;
    final colors = Theme.of(context).colorScheme;
    final backdrop = Theme.of(context).windowBackdrop;
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
                    canForward: widget.onPortForward != null,
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
            color: backdrop.chrome(colors.surfaceContainerLowest),
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
                          if (event.buttons == kSecondaryMouseButton) {
                            _secondaryPointer = event.pointer;
                            _syncPointerInput();
                          }
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
                        onPointerCancel: (event) {
                          _linkDown = null;
                          _pressedLink = null;
                          _releaseSecondaryPointer(event);
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
                          _releaseSecondaryPointer(event);
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
                            theme: _terminalTheme(colors),
                            // Window acrylic shows through the terminal; cells
                            // with an explicit background stay opaque.
                            backgroundOpacity: backdrop.acrylic ? 0 : 1,
                            padding: const EdgeInsets.all(16),
                            onPrepareCellDecoration: _prepareLinkDecoration,
                            cellDecoration: _linkDecoration,
                            textStyle: _terminalTextStyle,
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
                              _syncPointerInput();
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

/// Keeps one SSH session's assistant alive while its terminal pane is not
/// mounted. Switching sessions unmounts the pane; the controller, the open
/// panel and a running turn stay here until that session comes back or closes.
class TerminalAiRetention {
  TerminalAiRetention(this._alive);
  final bool Function(String sessionId) _alive;
  final _slots = <String, _RetainedAi>{};

  bool keeps(String sessionId) => _alive(sessionId);

  /// The controller of [sessionId], whether or not its panel is open. Used by
  /// the workspace to mirror live run/approval state into the session list.
  AiTaskController? taskOf(String sessionId) => _slots[sessionId]?.task;

  /// Every session that owns a controller, mounted pane or not.
  Iterable<String> get ids => _slots.keys.toList();

  /// Watches [session] for a dropped connection on behalf of a controller the
  /// workspace created for a session whose pane never opened the panel. The
  /// pane takes the watch over as soon as it claims the controller.
  void watch(String sessionId, SshConnection session) =>
      _slots[sessionId]?.watch(session);

  Iterable<String> get parkedIds => [
    for (final entry in _slots.entries)
      if (entry.value.parked) entry.key,
  ];

  AiTaskController create({
    required String sessionId,
    required AiSettings Function() settings,
    required AiCommandExecutor Function() executorFactory,
    required bool Function() connected,
    required AiConversationStore? historyStore,
    required String? historyScope,
    required Future<void> Function(String model)? persistModel,
  }) {
    final existing = _slots[sessionId];
    if (existing != null) {
      retarget(
        sessionId,
        settings: settings,
        executorFactory: executorFactory,
        connected: connected,
        persistModel: persistModel,
      );
      return existing.task;
    }
    final hook = _AiHook()
      ..settings = settings
      ..executorFactory = executorFactory
      ..connected = connected
      ..persistModel = persistModel;
    final task = AiTaskController(
      settings: () => hook.settings!(),
      executorFactory: () => hook.executorFactory!(),
      connected: () => hook.connected!(),
      // Resolved per choice, so rebinding the slot (a resumed workspace or a
      // rebuilt pane) re-points persistence without recreating the task.
      persistModel: persistModel == null
          ? null
          : (model) => hook.persistModel!(model),
      historyStore: historyStore,
      historyScope: historyScope,
    );
    _slots[sessionId] = _RetainedAi(task, hook);
    return task;
  }

  /// Restores a parked assistant and points it at the pane that is showing
  /// [sessionId] again. Null when this session has never opened the panel.
  ({AiTaskController task, bool open, bool detached})? claim(
    String sessionId, {
    required AiSettings Function()? settings,
    required AiCommandExecutor Function() executorFactory,
    required bool Function() connected,
    required Future<void> Function(String model)? persistModel,
  }) {
    final slot = _slots[sessionId];
    if (slot == null) return null;
    slot.parked = false;
    slot.unwatch();
    retarget(
      sessionId,
      settings: settings,
      executorFactory: executorFactory,
      connected: connected,
      persistModel: persistModel,
    );
    return (task: slot.task, open: slot.open, detached: slot.detached);
  }

  void retarget(
    String sessionId, {
    required AiSettings Function()? settings,
    required AiCommandExecutor Function() executorFactory,
    required bool Function() connected,
    required Future<void> Function(String model)? persistModel,
  }) {
    final slot = _slots[sessionId];
    if (slot == null) return;
    if (settings != null) slot.hook.settings = settings;
    slot.hook.executorFactory = executorFactory;
    slot.hook.connected = connected;
    // A pane without a persistence hook keeps the one this slot already had.
    final persist = persistModel;
    if (persist != null) slot.hook.persistModel = persist;
  }

  void park(
    String sessionId, {
    required bool open,
    required bool detached,
    required SshConnection session,
    required AiSettings Function()? settings,
    required AiCommandExecutor Function() executorFactory,
    required bool Function() connected,
    required Future<void> Function(String model)? persistModel,
  }) {
    final slot = _slots[sessionId];
    if (slot == null) return;
    slot
      ..open = open
      ..detached = detached
      ..parked = true;
    retarget(
      sessionId,
      settings: settings,
      executorFactory: executorFactory,
      connected: connected,
      persistModel: persistModel,
    );
    slot.watch(session);
  }

  /// The detached window was docked while its pane was off screen.
  void noteDocked(String sessionId) {
    final slot = _slots[sessionId];
    if (slot == null || !slot.parked) return;
    slot
      ..open = true
      ..detached = false;
  }

  void drop(String sessionId) {
    final slot = _slots.remove(sessionId);
    if (slot == null) return;
    slot.unwatch();
    slot.task.dispose();
  }

  void dispose() {
    for (final id in _slots.keys.toList()) {
      drop(id);
    }
  }
}

class _AiHook {
  AiSettings Function()? settings;
  AiCommandExecutor Function()? executorFactory;
  bool Function()? connected;

  /// Saves an explicitly chosen model for later sessions. Null only in panes
  /// that offer no persistence (tests, previews).
  Future<void> Function(String model)? persistModel;
}

class _RetainedAi {
  _RetainedAi(this.task, this.hook);
  final AiTaskController task;
  final _AiHook hook;
  bool open = false;
  bool detached = false;
  bool parked = false;
  SshConnection? _session;

  void watch(SshConnection session) {
    if (identical(_session, session)) return;
    unwatch();
    _session = session;
    session.addListener(_onSession);
  }

  void unwatch() {
    _session?.removeListener(_onSession);
    _session = null;
  }

  void _onSession() {
    final session = _session;
    if (session != null && session.status != ConnectionStatus.connected) {
      task.stop(message: 'SSH 已断开，AI 任务已停止');
    }
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
    this.canForward = false,
  });
  final SshConnection session;
  final TerminalPaneController? controller;
  final ValueChanged<String>? onSelected;
  final bool Function()? hasSelection;
  final bool canClose;
  final bool canForward;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    clipBehavior: Theme.of(context).windowBackdrop.frosted
        ? Clip.antiAlias
        : Clip.none,
    tooltip: '终端选项',
    popUpAnimationStyle: HarborMotion.popup(context),
    onSelected: onSelected ?? controller!.selectOption,
    itemBuilder: (_) => [
      if (Theme.of(context).windowBackdrop.frosted)
        const HarborPopupMenuBackdrop<String>(),
      if (MediaQuery.sizeOf(context).width < 900) ...[
        HarborPopupMenuItem(
          value: 'copy',
          enabled: (hasSelection?.call() ?? controller?.hasSelection ?? false),
          child: const Text('复制'),
        ),
        HarborPopupMenuItem(
          value: 'paste',
          enabled: session.status == ConnectionStatus.connected,
          child: const Text('粘贴'),
        ),
      ],
      const HarborPopupMenuItem(value: 'larger', child: Text('增大字体')),
      const HarborPopupMenuItem(value: 'smaller', child: Text('缩小字体')),
      if (canForward)
        const HarborPopupMenuItem(value: 'forward', child: Text('端口转发')),
      if (canClose)
        const HarborPopupMenuItem(value: 'close', child: Text('关闭会话')),
      if (session.status == ConnectionStatus.connected)
        const HarborPopupMenuItem(value: 'disconnect', child: Text('断开连接')),
    ],
  );
}
