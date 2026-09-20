import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
// Use xterm's own cell painter so link glyphs retain exactly the same metrics.
// ignore: implementation_imports
import 'package:xterm/src/ui/painter.dart';

class TerminalRepaint implements Listenable {
  const TerminalRepaint(this.terminal);
  final Terminal terminal;

  @override
  void addListener(VoidCallback listener) => terminal.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      terminal.removeListener(listener);
}

class TerminalLink {
  const TerminalLink(this.uri, this.cells);

  final Uri uri;
  final List<CellOffset> cells;

  bool contains(CellOffset position) => cells.any(position.isEqual);
}

final _urlPattern = RegExp(
  r'''https?://[^\s<>"'`\x00-\x1f]+''',
  caseSensitive: false,
);

/// Detect only visible logical lines, joining terminal soft wraps. Cell mapping
/// accounts for wide characters and UTF-16 surrogate pairs before a URL.
List<TerminalLink> terminalLinks(Buffer buffer, int firstRow, int lastRow) {
  final lines = buffer.lines;
  if (lines.length == 0) return const [];
  var row = firstRow.clamp(0, lines.length - 1);
  final last = lastRow.clamp(row, lines.length - 1);
  while (row > 0 && lines[row].isWrapped) {
    row--;
  }
  final links = <TerminalLink>[];
  while (row <= last) {
    final text = StringBuffer();
    final positions = <CellOffset>[];
    do {
      final line = lines[row];
      for (var x = 0; x < line.length; x++) {
        final code = line.getCodePoint(x);
        if (code == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
        final char = code == 0 ? ' ' : String.fromCharCode(code);
        text.write(char);
        final position = CellOffset(x, row);
        for (var unit = 0; unit < char.length; unit++) {
          positions.add(position);
        }
      }
      row++;
    } while (row < lines.length && lines[row].isWrapped);
    for (final match in _urlPattern.allMatches(text.toString())) {
      var value = match.group(0)!;
      // Exclude prose punctuation but retain balanced URL path parentheses.
      while (value.isNotEmpty) {
        final end = value[value.length - 1];
        final open = {')': '(', ']': '[', '}': '{'}[end];
        if ('.,;:!?，。；：！？）】》'.contains(end) ||
            (open != null &&
                end.allMatches(value).length > open.allMatches(value).length)) {
          value = value.substring(0, value.length - 1);
        } else {
          break;
        }
      }
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        continue;
      }
      links.add(
        TerminalLink(
          uri,
          positions.sublist(match.start, match.start + value.length),
        ),
      );
    }
  }
  return links;
}

/// Decorates the rendered terminal without altering SSH output or buffer data.
class TerminalLinkPainter extends CustomPainter {
  TerminalLinkPainter({
    required this.terminalKey,
    required this.paintKey,
    required this.terminal,
    required this.controller,
    required this.color,
    this.hoverPosition,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GlobalKey<TerminalViewState> terminalKey;
  final GlobalKey paintKey;
  final Terminal terminal;
  final TerminalController controller;
  final Color color;
  final Offset? hoverPosition;

  @override
  void paint(Canvas canvas, Size size) {
    final state = terminalKey.currentState;
    final box = paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (state == null || box == null) return;
    final render = state.renderTerminal;
    final origin = box.globalToLocal(render.localToGlobal(Offset.zero));
    final first = render.getCellOffset(Offset.zero).y;
    final last = render.getCellOffset(Offset(0, render.size.height)).y;
    final hoverLocal = hoverPosition == null
        ? null
        : render.globalToLocal(hoverPosition!);
    final hoverCell =
        hoverLocal != null && (Offset.zero & render.size).contains(hoverLocal)
        ? render.getCellOffset(hoverLocal)
        : null;
    final painter = TerminalPainter(
      theme: state.widget.theme,
      textStyle: state.widget.textStyle,
      textScaler:
          state.widget.textScaler ?? MediaQuery.textScalerOf(state.context),
    );
    canvas.save();
    canvas.clipRect(origin & render.size);
    final data = CellData.empty();
    for (final link in terminalLinks(terminal.buffer, first, last)) {
      final underline = hoverCell != null && link.contains(hoverCell);
      for (final cell in link.cells.toSet()) {
        if (cell.y < first ||
            cell.y > last ||
            controller.selection?.contains(cell) == true ||
            (cell.y == terminal.buffer.absoluteCursorY &&
                cell.x == terminal.buffer.cursorX)) {
          continue;
        }
        terminal.buffer.lines[cell.y].getCellData(cell.x, data);
        final location = render.getOffset(cell);
        final offset =
            origin + Offset(location.dx, location.dy.truncateToDouble());
        final width = terminal.buffer.lines[cell.y].getWidth(cell.x);
        final background = data.flags & CellFlags.inverse != 0
            ? painter.resolveForegroundColor(data.foreground)
            : painter.resolveBackgroundColor(data.background);
        canvas.drawRect(
          offset & Size(render.cellSize.width * width, render.cellSize.height),
          Paint()..color = background,
        );
        data.foreground = CellColor.rgb | (color.toARGB32() & 0xffffff);
        data.flags =
            (data.flags &
                ~(CellFlags.inverse | CellFlags.faint | CellFlags.underline)) |
            (underline ? CellFlags.underline : 0);
        painter.paintCellForeground(canvas, offset, data);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TerminalLinkPainter oldDelegate) => true;
}
