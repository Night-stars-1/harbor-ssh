import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'theme.dart';

/// Retains Markdown's table parsing, but bypasses its intrinsic-width renderer.
/// The original document also retains reference-link definitions for cells.
class AiMarkdownTableSyntax extends md.TableSyntax {
  const AiMarkdownTableSyntax();

  static const tag = 'harbor-table';

  @override
  md.Node? parse(md.BlockParser parser) {
    final table = super.parse(parser);
    return table is md.Element ? _TableElement(table, parser.document) : table;
  }
}

class _TableElement extends md.Element {
  _TableElement(this.table, this.document)
    : super(AiMarkdownTableSyntax.tag, []);

  final md.Element table;
  final md.Document document;
}

class AiMarkdownTableBuilder extends MarkdownElementBuilder {
  AiMarkdownTableBuilder({this.onTapLink});

  final MarkdownTapLinkCallback? onTapLink;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final source = element as _TableElement;
    final sections = source.table.children!.whereType<md.Element>().toList();
    if (sections.isEmpty) return const SizedBox.shrink();
    List<md.Element> cells(md.Element row) =>
        row.children?.whereType<md.Element>().toList() ?? const [];
    final header = cells(sections.first.children!.first as md.Element);
    final rows = sections
        .skip(1)
        .expand((section) => section.children!.whereType<md.Element>())
        .map(cells)
        .toList();
    final columns = [
      header.length,
      for (final row in rows) row.length,
    ].fold(0, (left, right) => left > right ? left : right);
    if (columns == 0) return const SizedBox.shrink();
    md.Element blank() => md.Element('td', [md.UnparsedContent('')]);
    List<md.Element> pad(List<md.Element> row) => [
      ...row,
      for (var i = row.length; i < columns; i++) blank(),
    ];
    return AiMarkdownTable(
      headers: pad(header),
      rows: [for (final row in rows) pad(row)],
      document: source.document,
      onTapLink: onTapLink,
    );
  }
}

class AiMarkdownTable extends StatelessWidget {
  const AiMarkdownTable({
    super.key,
    required this.headers,
    required this.rows,
    required this.document,
    this.onTapLink,
  });

  final List<md.Element> headers;
  final List<List<md.Element>> rows;
  final md.Document document;
  final MarkdownTapLinkCallback? onTapLink;

  Widget _cell(BuildContext context, md.Element cell, {bool heading = false}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = heading ? colors.onSecondaryContainer : colors.onSurface;
    final style =
        theme.textTheme.bodyMedium?.copyWith(
          color: foreground,
          fontSize: 13,
          height: 1.5,
          fontWeight: heading ? FontWeight.w700 : FontWeight.w400,
        ) ??
        TextStyle(
          color: foreground,
          fontSize: 13,
          height: 1.5,
          fontWeight: heading ? FontWeight.w700 : FontWeight.w400,
        );
    return _CellText(
      nodes: document.parseInline(cell.textContent),
      style: style,
      align: switch (cell.attributes['align']) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.start,
      },
      onTapLink: onTapLink,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 480;
        final padding = EdgeInsets.symmetric(
          horizontal: compact ? 10 : 16,
          vertical: compact ? 12 : 14,
        );
        final commandColumn =
            headers.length == 2 &&
            rows.any(
              (row) => document
                  .parseInline(row.first.textContent)
                  .any((node) => node is md.Element && node.tag == 'code'),
            );
        final separator = BorderSide(
          color: colors.outlineVariant.withValues(alpha: 0.65),
        );
        TableRow tableRow(
          List<md.Element> cells, {
          bool heading = false,
          int index = 0,
        }) => TableRow(
          decoration: BoxDecoration(
            color: heading
                ? colors.secondaryContainer
                : index.isEven
                ? colors.surfaceContainerLow
                : colors.surfaceContainer,
          ),
          children: [
            for (final cell in cells)
              Padding(
                padding: padding,
                child: _cell(context, cell, heading: heading),
              ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: colors.surfaceContainerLow,
            shape: HarborShapes.superellipse(),
            clipBehavior: Clip.antiAlias,
            child: Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: commandColumn
                  ? const {0: FlexColumnWidth(1.85), 1: FlexColumnWidth()}
                  : const {},
              border: TableBorder(
                horizontalInside: separator,
                verticalInside: separator,
              ),
              children: [
                tableRow(headers, heading: true),
                for (var row = 0; row < rows.length; row++)
                  tableRow(rows[row], index: row),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One table cell. Long tokens can break anywhere so a narrow column cannot
/// clip them, while a normal word still stays on one line when it fits.
/// Break opportunities are placeholders, not characters, so copying the cell
/// does not insert them into the command.
class _CellText extends StatefulWidget {
  const _CellText({
    required this.nodes,
    required this.style,
    required this.align,
    this.onTapLink,
  });

  final List<md.Node> nodes;
  final TextStyle style;
  final TextAlign align;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  State<_CellText> createState() => _CellTextState();
}

class _CellTextState extends State<_CellText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _link(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onTapLink?.call(text, href, title);
    _recognizers.add(recognizer);
    return recognizer;
  }

  InlineSpan _nodes(List<md.Node> nodes, TextStyle style) => TextSpan(
    style: style,
    children: [for (final node in nodes) _node(node, style)],
  );

  InlineSpan _node(md.Node node, TextStyle style) {
    if (node is md.Text) return _breakable(node.text, style);
    if (node is! md.Element) return TextSpan(text: '', style: style);
    final children = node.children ?? const <md.Node>[];
    return switch (node.tag) {
      'strong' => _nodes(children, style.copyWith(fontWeight: FontWeight.w700)),
      'em' => _nodes(children, style.copyWith(fontStyle: FontStyle.italic)),
      'del' => _nodes(
        children,
        style.copyWith(decoration: TextDecoration.lineThrough),
      ),
      'code' => _breakable(
        node.textContent,
        style.copyWith(fontFamily: 'monospace'),
      ),
      'br' => TextSpan(text: '\n', style: style),
      'a' => _linkSpan(node, children, style),
      'img' => _breakable(
        node.attributes['alt']?.isNotEmpty == true
            ? node.attributes['alt']!
            : node.attributes['src'] ?? '',
        style,
      ),
      _ => _nodes(children, style),
    };
  }

  InlineSpan _linkSpan(
    md.Element node,
    List<md.Node> children,
    TextStyle style,
  ) {
    final link = style.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return TextSpan(
      style: link,
      children: [for (final child in children) _node(child, link)],
      recognizer: widget.onTapLink == null
          ? null
          : _link(
              node.textContent,
              node.attributes['href'],
              node.attributes['title'] ?? '',
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    return SelectionArea(
      child: Text.rich(
        _nodes(widget.nodes, widget.style),
        style: widget.style,
        textAlign: widget.align,
      ),
    );
  }
}

const _breakOpportunity = WidgetSpan(
  alignment: PlaceholderAlignment.baseline,
  baseline: TextBaseline.alphabetic,
  child: SizedBox.shrink(),
);

/// Allows a break after [rune] without inserting a visible character.
bool _breaksAfter(int rune) {
  if (rune <= 0x20 || '/-_.:?&=,;|'.codeUnits.contains(rune)) return true;
  return (rune >= 0x2E80 && rune <= 0x9FFF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFF00 && rune <= 0xFFEF);
}

/// Keeps spaces, punctuation and CJK intact, and only offers a break inside a
/// run that the line breaker would otherwise treat as one unbreakable token.
InlineSpan _breakable(String text, TextStyle style) {
  if (text.isEmpty) return TextSpan(text: '', style: style);
  final children = <InlineSpan>[];
  final buffer = StringBuffer();
  var last = -1;
  var offerBreak = false;
  void flush() {
    if (buffer.isEmpty) return;
    if (offerBreak) children.add(_breakOpportunity);
    children.add(TextSpan(text: buffer.toString(), style: style));
    buffer.clear();
    offerBreak = false;
  }

  for (final rune in text.runes) {
    if (buffer.isNotEmpty && !_breaksAfter(last) && !_breaksAfter(rune)) {
      flush();
      offerBreak = true;
    }
    buffer.writeCharCode(rune);
    last = rune;
    if (_breaksAfter(rune)) flush();
  }
  flush();
  if (children.length == 1) return children.single;
  return TextSpan(style: style, children: children);
}
