import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

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

int _packCell(int x, int y) => (y << 16) | (x & 0xffff);

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

/// Looks up link color/underline for cells painted by [TerminalView].
class TerminalLinkStyle {
  TerminalLinkStyle(this.color);
  Color color;
  final _cells = <int, bool>{};


  void prepare(
    Buffer buffer,
    int first,
    int last, {
    CellOffset? hover,
  }) {
    _cells.clear();
    for (final link in terminalLinks(buffer, first, last)) {
      final underline = hover != null && link.contains(hover);
      for (final cell in link.cells) {
        _cells[_packCell(cell.x, cell.y)] = underline;
      }
    }
  }

  TerminalCellDecoration? decoration(int x, int y) {
    final underline = _cells[_packCell(x, y)];
    if (underline == null) return null;
    return TerminalCellDecoration(foreground: color, underline: underline);
  }
}
