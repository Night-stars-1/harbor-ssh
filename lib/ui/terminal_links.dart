import 'dart:typed_data';

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

const _maxCachedLines = 256;
const _maxCachedCells = 1 << 20;

int _packCell(int x, int y) => (y << 32) | (x & 0xffffffff);

/// Detect only visible logical lines, joining terminal soft wraps. Cell mapping
/// accounts for wide characters and UTF-16 surrogate pairs before a URL.
List<TerminalLink> terminalLinks(Buffer buffer, int firstRow, int lastRow) =>
    _LinkCache().links(buffer, firstRow, lastRow);

/// Looks up link color/underline for cells painted by [TerminalView].
///
/// Detection is cached per visible logical line. A logical line is only
/// re-scanned when its physical lines, soft-wrap edges, row positions or cell
/// contents change; repainting, hovering and color changes reuse the previous
/// match results.
class TerminalLinkStyle {
  TerminalLinkStyle(this._color);

  Color _color;

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    _decorations.clear();
  }

  final _cache = _LinkCache();
  final _cells = <int, TerminalLink>{};
  final _decorations = <TerminalLink, _LinkDecorations>{};

  TerminalLink? _hovered;
  Buffer? _activeBuffer;
  int? _activeFirst;
  int? _activeLast;
  List<_LogicalLine>? _activeLines;
  List<List<TerminalLink>>? _activeLinks;

  void prepare(Buffer buffer, int first, int last, {CellOffset? hover}) {
    final lines = buffer.lines;
    if (lines.length == 0) {
      _reset();
      return;
    }
    var firstRow = first.clamp(0, lines.length - 1);
    final lastRow = last.clamp(firstRow, lines.length - 1);
    // Start from the beginning of the logical line that contains [firstRow].
    while (firstRow > 0 && lines[firstRow].isWrapped) {
      firstRow--;
    }

    final activeLines = <_LogicalLine>[];
    final activeLinks = <List<TerminalLink>>[];
    var row = firstRow;
    while (row <= lastRow && row < lines.length) {
      final slice = _cache.lineAt(buffer, row);
      activeLines.add(slice.line);
      activeLinks.add(slice.links);
      row += slice.line.rowCount;
    }

    final unchanged =
        identical(buffer, _activeBuffer) &&
        firstRow == _activeFirst &&
        lastRow == _activeLast &&
        _sameActivity(activeLines, activeLinks);
    if (!unchanged) {
      _activeBuffer = buffer;
      _activeFirst = firstRow;
      _activeLast = lastRow;
      _activeLines = activeLines;
      _activeLinks = activeLinks;
      _cells.clear();
      _decorations.clear();
      for (final links in activeLinks) {
        for (final link in links) {
          for (final cell in link.cells) {
            if (cell.y < firstRow || cell.y > lastRow) continue;
            _cells[_packCell(cell.x, cell.y)] = link;
          }
        }
      }
    }

    _hovered = _hoveredLink(activeLinks, hover);
  }

  /// A link is underlined as a whole even when the hover falls on a part of it
  /// outside the painted row range. Use the painted cell index first, then fall
  /// back to the complete link list.
  TerminalLink? _hoveredLink(
    List<List<TerminalLink>> activeLinks,
    CellOffset? hover,
  ) {
    if (hover == null) return null;
    final indexed = _cells[_packCell(hover.x, hover.y)];
    if (indexed != null) return indexed;
    for (final links in activeLinks) {
      for (final link in links) {
        if (link.contains(hover)) return link;
      }
    }
    return null;
  }

  /// Returns the link covering [position], using the same cached detection as
  /// [prepare]. Safe to call between paints: it never clears painted cells.
  Uri? linkAt(Buffer buffer, CellOffset position) {
    final lines = buffer.lines;
    if (lines.length == 0 ||
        position.y < 0 ||
        position.y >= lines.length ||
        position.x < 0) {
      return null;
    }
    final slice = _cache.lineAt(buffer, position.y);
    for (final link in slice.links) {
      if (link.contains(position)) return link.uri;
    }
    return null;
  }

  TerminalCellDecoration? decoration(int x, int y) {
    final link = _cells[_packCell(x, y)];
    if (link == null) return null;
    var decorations = _decorations[link];
    if (decorations == null) {
      decorations = _LinkDecorations(_color);
      _decorations[link] = decorations;
    }
    return identical(link, _hovered) ? decorations.hovered : decorations.normal;
  }

  bool _sameActivity(List<_LogicalLine> lines, List<List<TerminalLink>> links) {
    final previousLines = _activeLines;
    final previousLinks = _activeLinks;
    if (previousLines == null || previousLinks == null) return false;
    if (lines.length != previousLines.length) return false;
    for (var i = 0; i < lines.length; i++) {
      if (!identical(lines[i], previousLines[i]) ||
          !identical(links[i], previousLinks[i])) {
        return false;
      }
    }
    return true;
  }

  void _reset() {
    _cells.clear();
    _decorations.clear();
    _hovered = null;
    _activeBuffer = null;
    _activeFirst = null;
    _activeLast = null;
    _activeLines = null;
    _activeLinks = null;
  }
}

class _LinkDecorations {
  _LinkDecorations(Color color)
    : normal = TerminalCellDecoration(foreground: color),
      hovered = TerminalCellDecoration(foreground: color, underline: true);

  final TerminalCellDecoration normal;
  final TerminalCellDecoration hovered;
}

/// One matched URL in logical-line-local coordinates.
class _LinkSpan {
  const _LinkSpan(this.uri, this.cells);

  final Uri uri;

  /// Packed `(rowOffset << 32) | x`, one entry per UTF-16 code unit. The low
  /// 32 bits hold the cell column so unwrapped lines beyond 65535 columns stay
  /// addressable.
  final List<int> cells;
}

class _LineSnapshot {
  _LineSnapshot(this.line, this.contents) : isWrapped = line.isWrapped;

  final BufferLine line;
  final bool isWrapped;
  final Uint32List contents;

  bool matches(BufferLine current) {
    if (!identical(line, current)) return false;
    if (isWrapped != current.isWrapped) return false;
    if (contents.length != current.length) return false;
    for (var x = 0; x < contents.length; x++) {
      if (contents[x] != current.getContent(x)) return false;
    }
    return true;
  }
}

/// Parsed text and matches for one logical line. Positions stay relative to the
/// logical line so a scroll only rebuilds [CellOffset]s, not text or regex
/// results.
class _LogicalLine {
  _LogicalLine(this.rows, this.spans, this.cellCount);

  final List<_LineSnapshot> rows;
  final List<_LinkSpan> spans;

  /// Total number of cell contents snapshotted across [rows].
  final int cellCount;

  List<TerminalLink>? _links;
  int _linksStartRow = -1;

  int get rowCount => rows.length;

  bool matches(Buffer buffer, int start, int end) {
    if (rows.length != end - start + 1) return false;
    final lines = buffer.lines;
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].matches(lines[start + i])) return false;
    }
    return true;
  }

  List<TerminalLink> linksAt(int startRow) {
    final cached = _links;
    if (cached != null && _linksStartRow == startRow) return cached;
    _linksStartRow = startRow;
    final links = List<TerminalLink>.generate(spans.length, (index) {
      final span = spans[index];
      final cells = List<CellOffset>.generate(span.cells.length, (cell) {
        final packed = span.cells[cell];
        return CellOffset(packed & 0xffffffff, startRow + (packed >> 32));
      });
      return TerminalLink(span.uri, cells);
    }, growable: false);
    _links = links;
    return links;
  }
}

class _LineSlice {
  const _LineSlice(this.line, this.links);

  final _LogicalLine line;
  final List<TerminalLink> links;
}

/// Bounded cache of parsed logical lines. Line identity, soft-wrap topology,
/// row positions and cell contents are verified before reuse, so in-place
/// overwrites, reflow, scrollback shifts and buffer switches never reuse stale
/// matches. Only a bounded number of logical lines are retained.
class _LinkCache {
  Buffer? _buffer;
  final _entries = <BufferLine, _LogicalLine>{};
  var _cachedCells = 0;

  List<TerminalLink> links(Buffer buffer, int firstRow, int lastRow) {
    final lines = buffer.lines;
    if (lines.length == 0) return const [];
    _bind(buffer);
    final first = firstRow.clamp(0, lines.length - 1);
    final last = lastRow.clamp(first, lines.length - 1);
    var row = first;
    while (row > 0 && lines[row].isWrapped) {
      row--;
    }
    final links = <TerminalLink>[];
    while (row <= last && row < lines.length) {
      final slice = lineAt(buffer, row);
      links.addAll(slice.links);
      row += slice.line.rowCount;
    }
    return links;
  }

  _LineSlice lineAt(Buffer buffer, int row) {
    _bind(buffer);
    final lines = buffer.lines;
    var start = row;
    while (start > 0 && lines[start].isWrapped) {
      start--;
    }
    var end = start;
    while (end + 1 < lines.length && lines[end + 1].isWrapped) {
      end++;
    }
    final first = lines[start];
    final cached = _entries.remove(first);
    if (cached != null) {
      if (cached.matches(buffer, start, end)) {
        _entries[first] = cached;
        _trim();
        return _LineSlice(cached, cached.linksAt(start));
      }
      _cachedCells -= cached.cellCount;
    }
    final built = _build(buffer, start, end);
    _entries[first] = built;
    _cachedCells += built.cellCount;
    _trim();
    return _LineSlice(built, built.linksAt(start));
  }

  void _bind(Buffer buffer) {
    if (identical(_buffer, buffer)) return;
    _buffer = buffer;
    _entries.clear();
    _cachedCells = 0;
  }

  void _trim() {
    while (_entries.length > _maxCachedLines) {
      _removeOldest();
    }
    // Soft-wrapped output can leave many overlapping full-buffer snapshots
    // behind as the ring advances. Keep the total snapshot size bounded too,
    // but allow a single oversized logical line to stay cached alone.
    while (_cachedCells > _maxCachedCells && _entries.length > 1) {
      _removeOldest();
    }
  }

  void _removeOldest() {
    final removed = _entries.remove(_entries.keys.first);
    if (removed != null) _cachedCells -= removed.cellCount;
  }

  _LogicalLine _build(Buffer buffer, int start, int end) {
    final lines = buffer.lines;
    final snapshots = <_LineSnapshot>[];
    final text = StringBuffer();
    final positions = <int>[];
    var cellCount = 0;

    for (var row = start; row <= end; row++) {
      final line = lines[row];
      final length = line.length;
      cellCount += length;
      final contents = Uint32List(length);
      final rowOffset = row - start;
      for (var x = 0; x < length; x++) {
        final content = line.getContent(x);
        contents[x] = content;
        final code = content & CellContent.codepointMask;
        if (code == 0 && x > 0 && line.getWidth(x - 1) == 2) continue;
        final char = code == 0 ? ' ' : String.fromCharCode(code);
        text.write(char);
        final packed = (rowOffset << 32) | (x & 0xffffffff);
        for (var unit = 0; unit < char.length; unit++) {
          positions.add(packed);
        }
      }
      snapshots.add(_LineSnapshot(line, contents));
    }

    final value = text.toString();
    final spans = <_LinkSpan>[];
    for (final match in _urlPattern.allMatches(value)) {
      var link = match.group(0)!;
      // Exclude prose punctuation but retain balanced URL path parentheses.
      while (link.isNotEmpty) {
        final end = link[link.length - 1];
        final open = {')': '(', ']': '[', '}': '{'}[end];
        if ('.,;:!?，。；：！？）】》'.contains(end) ||
            (open != null &&
                end.allMatches(link).length > open.allMatches(link).length)) {
          link = link.substring(0, link.length - 1);
        } else {
          break;
        }
      }
      final uri = Uri.tryParse(link);
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        continue;
      }
      spans.add(
        _LinkSpan(
          uri,
          positions.sublist(match.start, match.start + link.length),
        ),
      );
    }

    return _LogicalLine(snapshots, spans, cellCount);
  }
}
