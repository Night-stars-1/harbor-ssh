import 'package:flutter/gestures.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';

import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/cell_decoration.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/gesture/gesture_handler.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/scroll_handler.dart';

import 'package:xterm/src/ui/shortcut/actions.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

class TerminalView extends StatefulWidget {
  const TerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapUp,
    this.onSelectionMenuRequested,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.alwaysShowCursor = false,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
    this.onPrepareCellDecoration,
    this.cellDecoration,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Called after a touch long press finishes, with its global position.
  final ValueChanged<Offset>? onSelectionMenuRequested;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Prefered on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  /// Called once per paint with the visible line range before cells are drawn.
  final void Function(int firstLine, int lastLine)? onPrepareCellDecoration;

  /// Optional per-cell appearance override used while painting.
  final TerminalCellDecoration? Function(int x, int y)? cellDecoration;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> with WidgetsBindingObserver {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();
  final _startHandleLink = LayerLink();
  final _endHandleLink = LayerLink();
  final _toolbarLink = LayerLink();
  final _startVisible = ValueNotifier<bool>(false);
  final _endVisible = ValueNotifier<bool>(false);
  SelectionOverlay? _selectionOverlay;
  Widget Function(BuildContext, TextSelectionToolbarAnchors)? _toolbarBuilder;
  Offset? _toolbarAnchor;
  bool _selectionMenuHasSelection = false;
  bool _overlayUpdateScheduled = false;
  CellAnchor? _dragFixed;
  Offset? _dragOrigin;
  Offset? _dragEndpoint;
  bool _draggingStart = false;
  bool _handlesReversed = false;


  String? _composingText;

  late TerminalController _controller;

  late ScrollController _scrollController;
  final _horizontalController = ScrollController();
  double _horizontalExtent = 0;
  bool _applyingHorizontal = false;

  RenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as RenderTerminal;

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    _horizontalController.addListener(_onHorizontalScroll);
    _controller.addListener(_scheduleSelectionUpdate);
    widget.terminal.addListener(_scheduleSelectionUpdate);
    _scrollController.addListener(_scheduleSelectionUpdate);
    _focusNode.addListener(_onSelectionFocusChange);
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      hideSelectionToolbar(hideHandles: true);
    }
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    if (oldWidget.terminal != widget.terminal || oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode) {
      hideSelectionToolbar(hideHandles: true);
    }
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_scheduleSelectionUpdate);
      widget.terminal.addListener(_scheduleSelectionUpdate);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_onSelectionFocusChange);
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_onSelectionFocusChange);
    }
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_scheduleSelectionUpdate);
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
      _controller.addListener(_scheduleSelectionUpdate);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      _scrollController.removeListener(_scheduleSelectionUpdate);
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
      _scrollController.addListener(_scheduleSelectionUpdate);
    }
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    hideSelectionToolbar(hideHandles: true);
    _controller.removeListener(_scheduleSelectionUpdate);
    widget.terminal.removeListener(_scheduleSelectionUpdate);
    _scrollController.removeListener(_scheduleSelectionUpdate);
    _focusNode.removeListener(_onSelectionFocusChange);
    _startVisible.dispose();
    _endVisible.dispose();
    _horizontalController.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Scrollable(
      key: _scrollableKey,
      controller: _scrollController,
      viewportBuilder: (context, offset) {
        return CompositedTransformTarget(
          link: _toolbarLink,
          child: Listener(
          onPointerSignal: _onHorizontalPointer,
          child: _TerminalView(
            key: _viewportKey,
            terminal: widget.terminal,
            controller: _controller,
            offset: offset,
            padding: MediaQuery.of(context).padding,
            autoResize: widget.autoResize,
            textStyle: widget.textStyle,
            textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
            theme: widget.theme,
            focusNode: _focusNode,
            cursorType: widget.cursorType,
            alwaysShowCursor: widget.alwaysShowCursor,
            onEditableRect: _onEditableRect,
            composingText: _composingText,
            prepareCellDecoration: widget.onPrepareCellDecoration,
            cellDecoration: widget.cellDecoration,
            startHandleLink: _startHandleLink,
            endHandleLink: _endHandleLink,
            onHorizontalMetrics: _onHorizontalMetrics,
          ),
          ),
        );
      },
    );

    child = TerminalScrollGestureHandler(
      terminal: widget.terminal,
      simulateScroll: widget.simulateScroll,
      getCellOffset: (offset) => renderTerminal.getCellOffset(offset),
      getLineHeight: () => renderTerminal.lineHeight,
      child: child,
    );

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        onInsert: _onInsert,
        onDelete: () {
          _scrollToBottom();
          widget.terminal.keyInput(TerminalKey.backspace);
        },
        onComposing: _onComposing,
        onAction: (action) {
          _scrollToBottom();
          if (action == TextInputAction.done) {
            widget.terminal.keyInput(TerminalKey.enter);
          }
        },
        onKeyEvent: _handleKeyEvent,
        readOnly: widget.readOnly,
        child: child,
      );
    } else if (!widget.readOnly) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        child: child,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
      );
    }

    child = TerminalActions(
      terminal: widget.terminal,
      controller: _controller,
      child: child,
    );

    child = KeyboardVisibilty(
      onKeyboardShow: _onKeyboardShow,
      child: child,
    );

    child = TerminalGestureHandler(
      terminalView: this,
      terminalController: _controller,
      onTapUp: _onTapUp,
      onSelectionMenuRequested: widget.onSelectionMenuRequested,
      onTapDown: _onTapDown,
      onSecondaryTapDown:
          widget.onSecondaryTapDown != null ? _onSecondaryTapDown : null,
      onSecondaryTapUp:
          widget.onSecondaryTapUp != null ? _onSecondaryTapUp : null,
      readOnly: widget.readOnly,
      child: child,
    );

    child = MouseRegion(
      cursor: widget.mouseCursor,
      child: child,
    );

    child = Container(
      color: widget.theme.background.withOpacity(widget.backgroundOpacity),
      padding: widget.padding,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              supportedDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragUpdate:
                  !widget.terminal.lineWrap && _horizontalExtent > 0
                      ? (details) => _scrollHorizontally(-details.delta.dx)
                      : null,
              child: child,
            ),
          ),
          if (_horizontalExtent > 0) _horizontalBar(),
        ],
      ),
    );

    return child;
  }

  bool get selectionToolbarVisible => _selectionOverlay?.toolbarIsVisible ?? false;

  /// Shows the platform-style selection menu and, for a selection, handles.
  void showSelectionToolbar(
    Widget Function(BuildContext context, TextSelectionToolbarAnchors anchors) builder, {
    Offset? anchor,
  }) {
    hideSelectionToolbar(hideHandles: true);
    _toolbarBuilder = builder;
    _toolbarAnchor = anchor;
    final selection = _controller.selection;
    _selectionMenuHasSelection = selection != null && !selection.isCollapsed;
    if (!_selectionMenuHasSelection && anchor == null) return;
    final render = renderTerminal;
    _selectionOverlay = SelectionOverlay(
      context: context,
      startHandleType: TextSelectionHandleType.left,
      endHandleType: TextSelectionHandleType.right,
      lineHeightAtStart: render.lineHeight,
      lineHeightAtEnd: render.lineHeight,
      startHandlesVisible: _startVisible,
      endHandlesVisible: _endVisible,
      onStartHandleDragStart: (details) => _startHandleDrag(details, true),
      onEndHandleDragStart: (details) => _startHandleDrag(details, false),
      onStartHandleDragUpdate: _updateHandleDrag,
      onEndHandleDragUpdate: _updateHandleDrag,
      onStartHandleDragEnd: _endHandleDrag,
      onEndHandleDragEnd: _endHandleDrag,
      selectionEndpoints: const [],
      selectionControls: materialTextSelectionHandleControls,
      selectionDelegate: null,
      clipboardStatus: null,
      startHandleLayerLink: _startHandleLink,
      endHandleLayerLink: _endHandleLink,
      toolbarLayerLink: _toolbarLink,
    );
    _updateSelectionOverlay();
    if (_selectionMenuHasSelection) _selectionOverlay?.showHandles();
    _showToolbar();
  }

  void hideSelectionToolbar({bool hideHandles = false}) {
    _selectionOverlay?.hideToolbar();
    if (hideHandles) {
      _selectionOverlay?.dispose();
      _selectionOverlay = null;
      _toolbarBuilder = null;
      _dragFixed?.dispose();
      _dragFixed = null;
      _handlesReversed = false;
      final render = _viewportKey.currentContext?.findRenderObject();
      if (render is RenderTerminal) render.selectionHandlesReversed = false;
    }
  }

  void _onSelectionFocusChange() {
    if (!_focusNode.hasFocus) hideSelectionToolbar(hideHandles: true);
  }

  void _scheduleSelectionUpdate() {
    if (_selectionOverlay == null || _overlayUpdateScheduled) return;
    _overlayUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayUpdateScheduled = false;
      if (mounted) _updateSelectionOverlay();
    });
  }

  void _updateSelectionOverlay() {
    final overlay = _selectionOverlay;
    if (overlay == null) return;
    final selection = _controller.selection?.normalized;
    if (_selectionMenuHasSelection && (selection == null || (selection.isCollapsed && _dragFixed == null))) {
      hideSelectionToolbar(hideHandles: true);
      return;
    }
    if (selection == null || !_selectionMenuHasSelection) return;
    final render = renderTerminal;
    final start = render.selectionEndpoint(selection.begin);
    final end = render.selectionEndpoint(selection.end);
    _startVisible.value = render.selectionEndpointVisible(_handlesReversed ? selection.end : selection.begin);
    _endVisible.value = render.selectionEndpointVisible(_handlesReversed ? selection.begin : selection.end);
    overlay
      ..lineHeightAtStart = render.lineHeight
      ..lineHeightAtEnd = render.lineHeight
      ..selectionEndpoints = [
        TextSelectionPoint(start, TextDirection.ltr),
        TextSelectionPoint(end, TextDirection.ltr),
      ];
    overlay.markNeedsBuild();
  }

  void _showToolbar() {
    final overlay = _selectionOverlay;
    if (overlay == null || _toolbarBuilder == null) return;
    overlay.hideToolbar();
    overlay.showToolbar(context: _viewportKey.currentContext, contextMenuBuilder: (menuContext) {
      final selection = _controller.selection?.normalized;
      final render = renderTerminal;
      final TextSelectionToolbarAnchors anchors;
      if (_selectionMenuHasSelection && selection != null) {
        final start = render.localToGlobal(render.selectionEndpoint(selection.begin));
        final end = render.localToGlobal(render.selectionEndpoint(selection.end));
        anchors = TextSelectionToolbarAnchors(
          primaryAnchor: Offset((start.dx + end.dx) / 2, start.dy - render.lineHeight),
          secondaryAnchor: Offset((start.dx + end.dx) / 2, end.dy),
        );
      } else {
        anchors = TextSelectionToolbarAnchors(primaryAnchor: _toolbarAnchor!);
      }
      return _toolbarBuilder!(menuContext, anchors);
    });
  }

  void _startHandleDrag(DragStartDetails details, bool start) {
    final selection = _controller.selection?.normalized;
    if (selection == null) return;
    _draggingStart = start;
    _dragFixed?.dispose();
    _dragFixed = widget.terminal.buffer.createAnchorFromOffset(start ? selection.end : selection.begin);
    _dragOrigin = details.globalPosition;
    _dragEndpoint = renderTerminal.localToGlobal(renderTerminal.selectionEndpoint(start ? selection.begin : selection.end))
        .translate(0, -renderTerminal.lineHeight / 2);
    hideSelectionToolbar();
  }

  void _updateHandleDrag(DragUpdateDetails details) {
    final fixed = _dragFixed;
    if (fixed == null || !fixed.attached || _dragOrigin == null || _dragEndpoint == null) return;
    final position = renderTerminal.globalToLocal(_dragEndpoint! + details.globalPosition - _dragOrigin!);
    final scroll = _scrollableKey.currentState?.position;
    if (scroll != null) {
      final margin = renderTerminal.lineHeight;
      final delta = position.dy < margin
          ? position.dy - margin
          : position.dy > renderTerminal.size.height - margin
              ? position.dy - (renderTerminal.size.height - margin)
              : 0.0;
      if (delta != 0) {
        scroll.jumpTo((scroll.pixels + delta).clamp(scroll.minScrollExtent, scroll.maxScrollExtent));
      }
    }
    if (!widget.terminal.lineWrap) {
      final margin = renderTerminal.cellSize.width * 2;
      if (position.dx < margin) {
        _scrollHorizontally(position.dx - margin);
      } else if (position.dx > renderTerminal.size.width - margin) {
        _scrollHorizontally(position.dx - (renderTerminal.size.width - margin));
      }
    }
    final boundary = renderTerminal.getSelectionBoundary(position);
    final fixedOffset = fixed.offset;
    _handlesReversed = _draggingStart ? fixedOffset.isBefore(boundary) : boundary.isBefore(fixedOffset);
    renderTerminal.selectionHandlesReversed = _handlesReversed;
    _controller.setSelection(
      widget.terminal.buffer.createAnchorFromOffset(fixedOffset),
      widget.terminal.buffer.createAnchorFromOffset(boundary),
    );
  }

  void _endHandleDrag(DragEndDetails details) {
    _dragFixed?.dispose();
    _dragFixed = null;
    _dragOrigin = null;
    _dragEndpoint = null;
    _handlesReversed = false;
    renderTerminal.selectionHandlesReversed = false;
    _updateSelectionOverlay();
    _showToolbar();
  }

  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard();
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  Rect get cursorRect {
    return renderTerminal.cursorOffset & renderTerminal.cellSize;
  }

  Rect get globalCursorRect {
    return renderTerminal.localToGlobal(renderTerminal.cursorOffset) &
        renderTerminal.cellSize;
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapUp?.call(details, offset);
  }

  void _onTapDown(_) {
    if (_controller.selection != null) {
      _controller.clearSelection();
    } else {
      if (!widget.hardwareKeyboardOnly) {
        _customTextEditKey.currentState?.requestKeyboard();
      } else {
        _focusNode.requestFocus();
      }
    }
  }

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    final key = charToTerminalKey(text.trim());

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
  }

  void _onComposing(String? text) {
    setState(() => _composingText = text);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);

    if (key == null) {
      return KeyEventResult.ignored;
    }

    final handled = widget.terminal.keyInput(
      key,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );

    if (handled) {
      _scrollToBottom();
    }

    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onKeyboardShow() {
    if (_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  void _onEditableRect(Rect rect, Rect caretRect) {
    _scheduleSelectionUpdate();
    _customTextEditKey.currentState?.setEditableRect(rect, caretRect);
  }

  void _onHorizontalScroll() {
    if (_applyingHorizontal || !_horizontalController.hasClients) return;
    final render = _viewportKey.currentContext?.findRenderObject();
    if (render is RenderTerminal) {
      render.horizontalOffset = _horizontalController.offset;
      _scheduleSelectionUpdate();
    }
  }

  void _onHorizontalMetrics(double extent, double offset) {
    if (!mounted) return;
    final shown = widget.terminal.lineWrap ? 0.0 : extent;
    if ((shown - _horizontalExtent).abs() > 0.5) {
      setState(() => _horizontalExtent = shown);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyHorizontalTarget(offset);
      });
    } else {
      _applyHorizontalTarget(offset);
    }
  }

  void _applyHorizontalTarget(double offset) {
    if (!mounted || !_horizontalController.hasClients) return;
    final position = _horizontalController.position;
    final target =
        offset.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((_horizontalController.offset - target).abs() <= 0.5) return;
    _applyingHorizontal = true;
    _horizontalController.jumpTo(target);
    _applyingHorizontal = false;
  }

  void _onHorizontalPointer(PointerSignalEvent event) {
    if (widget.terminal.lineWrap ||
        event is! PointerScrollEvent ||
        !_horizontalController.hasClients ||
        renderTerminal.maxHorizontalExtent <= 0) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : HardwareKeyboard.instance.isShiftPressed
            ? event.scrollDelta.dy
            : 0.0;
    if (delta == 0) return;
    // The viewport receives signals before either vertical Scrollable. Claim
    // horizontal gestures even at an edge so they cannot scroll rows or send
    // alternate-screen wheel input as well.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _scrollHorizontally(delta);
      event.respond(allowPlatformDefault: false);
    });
  }

  void _scrollHorizontally(double delta) {
    if (widget.terminal.lineWrap || !_horizontalController.hasClients) return;
    final position = _horizontalController.position;
    final next = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _horizontalController.jumpTo(next);
  }

  Widget _horizontalBar() {
    return SizedBox(
      key: const ValueKey('terminal-horizontal-scrollbar'),
      height: 12,
      child: LayoutBuilder(
        builder: (context, constraints) => RawScrollbar(
          controller: _horizontalController,
          thumbVisibility: true,
          interactive: true,
          thumbColor: widget.theme.foreground.withOpacity(0.6),
          thickness: 6,
          radius: const Radius.circular(3),
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: constraints.maxWidth + _horizontalExtent,
              height: 12,
            ),
          ),
        ),
      ),
    );
  }

  void _scrollToBottom() {
    renderTerminal.resetCursorBlink();
    final position = _scrollableKey.currentState?.position;
    if (position != null) {
      position.jumpTo(position.maxScrollExtent);
    }
  }
}

class _TerminalView extends LeafRenderObjectWidget {
  const _TerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.autoResize,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.alwaysShowCursor,
    this.onEditableRect,
    this.composingText,
    this.prepareCellDecoration,
    this.cellDecoration,
    this.onHorizontalMetrics,
    required this.startHandleLink,
    required this.endHandleLink,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool autoResize;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool alwaysShowCursor;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  final void Function(int firstLine, int lastLine)? prepareCellDecoration;

  final TerminalCellDecoration? Function(int x, int y)? cellDecoration;

  final HorizontalMetricsCallback? onHorizontalMetrics;
  final LayerLink startHandleLink;
  final LayerLink endHandleLink;


  @override
  RenderTerminal createRenderObject(BuildContext context) {
    return RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      autoResize: autoResize,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      alwaysShowCursor: alwaysShowCursor,
      onEditableRect: onEditableRect,
      composingText: composingText,
      prepareCellDecoration: prepareCellDecoration,
      cellDecoration: cellDecoration,
      onHorizontalMetrics: onHorizontalMetrics,
      startHandleLink: startHandleLink,
      endHandleLink: endHandleLink,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..autoResize = autoResize
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..alwaysShowCursor = alwaysShowCursor
      ..onEditableRect = onEditableRect
      ..composingText = composingText
      ..prepareCellDecoration = prepareCellDecoration
      ..cellDecoration = cellDecoration
      ..onHorizontalMetrics = onHorizontalMetrics;
  }
}
