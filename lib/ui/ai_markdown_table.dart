import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'ai_markdown_style.dart';
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
    List<md.Element> cells(md.Element row) =>
        row.children!.whereType<md.Element>().toList();
    final header = cells(sections.first.children!.first as md.Element);
    final rows = sections
        .skip(1)
        .expand((section) => section.children!.whereType<md.Element>())
        .map(cells)
        .toList();
    return AiMarkdownTable(
      headers: header,
      rows: rows,
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
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: foreground,
      fontSize: 13,
      height: 1.5,
      fontWeight: heading ? FontWeight.w700 : FontWeight.w400,
    );
    // Render parsed inline nodes so bold, code, images and reference links keep
    // the same behavior as the rest of the reply. No raw text is flattened.
    final nodes = document.parseInline(cell.textContent);
    return MarkdownBody(
      data: 'cell',
      selectable: true,
      fitContent: false,
      blockSyntaxes: [_CellSyntax(nodes)],
      onTapLink: onTapLink,
      styleSheet: aiMarkdownStyle(theme).copyWith(
        p: style,
        textAlign: switch (cell.attributes['align']) {
          'center' => WrapAlignment.center,
          'right' => WrapAlignment.end,
          _ => WrapAlignment.start,
        },
        code: style?.copyWith(
          fontFamily: 'monospace',
          // Each cell already sits on the table row surface.
          backgroundColor: Colors.transparent,
        ),
      ),
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

/// Supplies already parsed inline content to the existing Markdown renderer.
class _CellSyntax extends md.BlockSyntax {
  _CellSyntax(this.nodes);

  final List<md.Node> nodes;

  @override
  RegExp get pattern => RegExp(r'.');

  @override
  md.Node parse(md.BlockParser parser) {
    parser.advance();
    return md.Element('p', nodes);
  }
}
