import 'dart:async';
import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/cell_decoration.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';

import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';

typedef EditableRectCallback = void Function(Rect rect, Rect caretRect);
typedef HorizontalMetricsCallback = void Function(double extent, double offset);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
  RenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool autoResize,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool alwaysShowCursor,
    EditableRectCallback? onEditableRect,
    String? composingText,
    void Function(int firstLine, int lastLine)? prepareCellDecoration,
    TerminalCellDecoration? Function(int x, int y)? cellDecoration,
    HorizontalMetricsCallback? onHorizontalMetrics,
  })  : _terminal = terminal,
        _controller = controller,
        _offset = offset,
        _padding = padding,
        _autoResize = autoResize,
        _focusNode = focusNode,
        _cursorType = cursorType,
        _alwaysShowCursor = alwaysShowCursor,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _prepareCellDecoration = prepareCellDecoration,
        _cellDecoration = cellDecoration,
        _onHorizontalMetrics = onHorizontalMetrics,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
        );

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _appliedSize = null;
    _contentColumnsDirty = true;
    _followHorizontal = true;
    resetCursorBlink();
    markNeedsLayout();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
  }

  FocusNode _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    resetCursorBlink();
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    resetCursorBlink();
    markNeedsPaint();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    markNeedsLayout();
  }

  String? _composingText;
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    resetCursorBlink();
    markNeedsPaint();
  }

  HorizontalMetricsCallback? _onHorizontalMetrics;
  set onHorizontalMetrics(HorizontalMetricsCallback? value) {
    if (value == _onHorizontalMetrics) return;
    _onHorizontalMetrics = value;
  }

  double _horizontalOffset = 0;
  int _contentColumns = 0;
  bool _followHorizontal = true;
  bool _contentColumnsDirty = true;
  TerminalSize? _appliedSize;
  double _reportedExtent = -1;
  double _reportedOffset = -1;

  double get horizontalOffset => _horizontalOffset;

  set horizontalOffset(double value) {
    final limit = hasSize ? maxHorizontalExtent : value.abs();
    final next = value.clamp(0.0, max(0.0, limit)).toDouble();
    if ((next - _horizontalOffset).abs() < 0.5) return;
    _horizontalOffset = next;
    markNeedsPaint();
    if (attached) _notifyEditableRect();
    _reportHorizontalMetrics();
  }

  /// Pixels of content hidden to the right of the viewport. Zero while wrapping.
  double get maxHorizontalExtent {
    if (_terminal.lineWrap || !hasSize) return 0;
    final cell = _painter.cellSize.width;
    if (cell <= 0) return 0;
    final visible = max(1, size.width ~/ cell);
    return max(0, _contentColumns - visible) * cell;
  }

  void Function(int firstLine, int lastLine)? _prepareCellDecoration;
  set prepareCellDecoration(
    void Function(int firstLine, int lastLine)? value,
  ) {
    _prepareCellDecoration = value;
    markNeedsPaint();
  }

  TerminalCellDecoration? Function(int x, int y)? _cellDecoration;
  set cellDecoration(TerminalCellDecoration? Function(int x, int y)? value) {
    _cellDecoration = value;
    markNeedsPaint();
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  var _stickToBottom = true;

  Timer? _cursorBlinkTimer;
  bool _cursorBlinkVisible = true;

  /// Start each input or focus change with a visible caret. Only repaint on
  /// blink ticks: the terminal buffer and layout must remain untouched.
  void resetCursorBlink() {
    _cursorBlinkTimer?.cancel();
    _cursorBlinkTimer = null;
    _cursorBlinkVisible = true;
    if (attached &&
        _focusNode.hasFocus &&
        _terminal.cursorVisibleMode &&
        !_alwaysShowCursor &&
        !_isComposingText) {
      _cursorBlinkTimer =
          Timer.periodic(const Duration(milliseconds: 500), (_) {
        _cursorBlinkVisible = !_cursorBlinkVisible;
        markNeedsPaint();
      });
    }
    markNeedsPaint();
  }

  void _onScroll() {
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    markNeedsLayout();
    _notifyEditableRect();
  }

  void _onFocusChange() {
    resetCursorBlink();
  }

  void _onTerminalChange() {
    _contentColumnsDirty = true;
    if (_terminal.lineWrap) {
      _horizontalOffset = 0;
      _followHorizontal = false;
    } else {
      _followHorizontal = true;
    }
    resetCursorBlink();
    markNeedsLayout();
    _notifyEditableRect();
  }

  void _onControllerUpdate() {
    markNeedsLayout();
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _focusNode.addListener(_onFocusChange);
    resetCursorBlink();
  }

  @override
  void detach() {
    _cursorBlinkTimer?.cancel();
    _cursorBlinkTimer = null;
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  void reassemble() {
    super.reassemble();
    resetCursorBlink();
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();

    _updateScrollOffset();

    if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }

    _measureContentColumns();
    _horizontalOffset = _horizontalOffset.clamp(0.0, maxHorizontalExtent);
    if (_followHorizontal) {
      _followHorizontal = false;
      _revealCursor();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) _notifyEditableRect();
    });
    _reportHorizontalMetrics();
  }

  void _measureContentColumns() {
    if (!_contentColumnsDirty) return;
    _contentColumnsDirty = false;
    if (_terminal.lineWrap) {
      _contentColumns = _terminal.viewWidth;
      return;
    }
    var columns = max(_terminal.viewWidth, _terminal.buffer.cursorX + 1);
    final lines = _terminal.buffer.lines;
    for (var i = 0; i < lines.length; i++) {
      final length = lines[i].getTrimmedLength(lines[i].length);
      if (length > columns) columns = length;
    }
    _contentColumns = columns;
  }

  void _revealCursor() {
    if (!hasSize || _terminal.lineWrap) {
      _horizontalOffset = 0;
      return;
    }
    final cell = _painter.cellSize.width;
    if (cell <= 0) return;
    final cursor = _terminal.buffer.cursorX * cell;
    final visible = size.width.toDouble();
    var next = _horizontalOffset;
    if (cursor < next) {
      next = cursor;
    } else if (cursor + cell > next + visible) {
      next = max(0.0, cursor + cell - visible);
    }
    _horizontalOffset = next.clamp(0.0, maxHorizontalExtent);
  }

  void _reportHorizontalMetrics() {
    final extent = maxHorizontalExtent;
    final offset = _horizontalOffset;
    if ((extent - _reportedExtent).abs() < 0.5 &&
        (offset - _reportedOffset).abs() < 0.5) {
      return;
    }
    _reportedExtent = extent;
    _reportedOffset = offset;
    final callback = _onHorizontalMetrics;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && callback == _onHorizontalMetrics) {
        callback(maxHorizontalExtent, _horizontalOffset);
      }
    });
  }

  int _logicalColumns(int viewportColumns) {
    final columns = max(1, viewportColumns);
    if (_terminal.lineWrap) return columns;
    return max(columns, Terminal.unwrapColumns);
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  /// The distance from the top of the terminal to the top of the viewport.
  // double get _scrollOffset => _offset.pixels;
  double get _scrollOffset {
    // return _offset.pixels ~/ _painter.cellSize.height * _painter.cellSize.height;
    return _offset.pixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    final row = cellOffset.y;
    final col = cellOffset.x;
    final x = col * _painter.cellSize.width;
    final y = row * _painter.cellSize.height;
    return Offset(
      x + _padding.left - _horizontalOffset,
      y + _padding.top - _scrollOffset,
    );
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    final x = offset.dx - _padding.left + _horizontalOffset;
    final y = offset.dy - _padding.top + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    final columns = _terminal.lineWrap
        ? _terminal.viewWidth
        : max(_terminal.viewWidth, _contentColumns);
    return CellOffset(
      col.clamp(0, max(0, columns - 1)),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  void selectWord(Offset from, [Offset? to]) {
    final fromOffset = getCellOffset(from);
    final fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
    if (fromBoundary == null) return;
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromBoundary.begin),
        _terminal.buffer.createAnchorFromOffset(fromBoundary.end),
        mode: SelectionMode.line,
      );
    } else {
      final toOffset = getCellOffset(to);
      final toBoundary = _terminal.buffer.getWordBoundary(toOffset);
      if (toBoundary == null) return;
      final range = fromBoundary.merge(toBoundary);
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(range.begin),
        _terminal.buffer.createAnchorFromOffset(range.end),
        mode: SelectionMode.line,
      );
    }
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  void selectCharacters(Offset from, [Offset? to]) {
    final fromPosition = getCellOffset(from);
    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(fromPosition),
      );
    } else {
      var toPosition = getCellOffset(to);
      if (toPosition.x >= fromPosition.x) {
        toPosition = CellOffset(toPosition.x + 1, toPosition.y);
      }
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(fromPosition),
        _terminal.buffer.createAnchorFromOffset(toPosition),
      );
    }
  }

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset,
  ) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(button, buttonState, position);
  }

  void _notifyEditableRect() {
    final cursor = localToGlobal(cursorOffset);

    final rect = Rect.fromLTRB(
      cursor.dx,
      cursor.dy,
      size.width,
      cursor.dy + _painter.cellSize.height,
    );

    final caretRect = cursor & _painter.cellSize;

    _onEditableRect?.call(rect, caretRect);
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final viewportSize = TerminalSize(
      size.width ~/ _painter.cellSize.width,
      _viewportHeight ~/ _painter.cellSize.height,
    );
    final applied = TerminalSize(
      _logicalColumns(viewportSize.width),
      viewportSize.height,
    );

    if (_viewportSize == viewportSize && _appliedSize == applied) {
      return;
    }

    _viewportSize = viewportSize;
    _appliedSize = applied;
    _resizeTerminalIfNeeded();
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    final applied = _appliedSize ?? _viewportSize;
    if (!_autoResize || applied == null) {
      return;
    }
    if (applied.width == _terminal.viewWidth &&
        applied.height == _terminal.viewHeight) {
      return;
    }
    _terminal.resize(
      applied.width,
      applied.height,
      _painter.cellSize.width.round(),
      _painter.cellSize.height.round(),
    );
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  bool get _shouldShowCursor {
    return _alwaysShowCursor ||
        _isComposingText ||
        (_terminal.cursorVisibleMode &&
            (!_focusNode.hasFocus || _cursorBlinkVisible));
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    return max(_terminalHeight - _viewportHeight, 0.0);
  }

  double get _lineOffset {
    return -_scrollOffset + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get _bufferCursorOffset {
    return Offset(
      _terminal.buffer.cursorX * _painter.cellSize.width,
      _terminal.buffer.absoluteCursorY * _painter.cellSize.height + _lineOffset,
    );
  }

  Offset get cursorOffset =>
      _bufferCursorOffset.translate(-_horizontalOffset, 0);

  Size get cellSize {
    return _painter.cellSize;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.setWillChangeHint();
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(offset & size);
    if (_horizontalOffset != 0) {
      canvas.translate(-_horizontalOffset, 0);
    }

    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _scrollOffset - _padding.top;
    final lastLineOffset = _scrollOffset + size.height + _padding.bottom;

    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);

    _prepareCellDecoration?.call(effectFirstLine, effectLastLine);
    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      _painter.paintLine(
        canvas,
        offset.translate(0, (i * charHeight + _lineOffset).truncateToDouble()),
        lines[i],
        row: i,
        decoration: _cellDecoration,
      );
    }

    if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + _bufferCursorOffset);
      }

      if (_shouldShowCursor) {
        _painter.paintCursor(
          canvas,
          offset + _bufferCursorOffset,
          cursorType: _cursorType,
          hasFocus: _focusNode.hasFocus,
        );
      }
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );

    if (_controller.selection != null) {
      _paintSelection(
        canvas,
        _controller.selection!,
        effectFirstLine,
        effectLastLine,
      );
    }
    canvas.restore();
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(
      style.getTextStyle(textScaler: _painter.textScaler),
    );
    builder.addText(composingText);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(
      width: max(size.width, offset.dx + composingText.length * cellSize.width),
    ));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
  }

  void _paintSelection(
    Canvas canvas,
    BufferRange selection,
    int firstLine,
    int lastLine,
  ) {
    for (final segment in selection.toSegments()) {
      if (segment.line >= _terminal.buffer.lines.length) {
        break;
      }

      if (segment.line < firstLine) {
        continue;
      }

      if (segment.line > lastLine) {
        break;
      }

      _paintSegment(canvas, segment, _painter.theme.selection);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (var segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, segment, highlight.color);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _paintSegment(Canvas canvas, BufferSegment segment, Color color) {
    final start = segment.start ?? 0;
    var end = segment.end;
    if (end == null) {
      final line = _terminal.buffer.lines[segment.line];
      end = _terminal.lineWrap ? _terminal.viewWidth : line.length;
    }

    final startOffset = Offset(
      start * _painter.cellSize.width,
      segment.line * _painter.cellSize.height + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }
}
