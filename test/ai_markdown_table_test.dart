import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/ai_markdown_style.dart';
import 'package:harbor_ssh/ui/ai_markdown_table.dart';
import 'package:harbor_ssh/ui/theme.dart';

void main() {
  testWidgets('窄列里的长标识会换行，缺列的内容仍然显示', (tester) async {
    const token = 'abcdefghijklmnopqrstuvwxyz0123456789';
    const markdown =
        '| 名称 | 状态 |\n'
        '| --- | --- |\n'
        '| gateway | `$token` |\n'
        '| 仅名称 |\n';
    tester.view.physicalSize = const Size(240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => MarkdownBody(
                data: markdown,
                selectable: true,
                fitContent: false,
                blockSyntaxes: const [AiMarkdownTableSyntax()],
                builders: {AiMarkdownTableSyntax.tag: AiMarkdownTableBuilder()},
                styleSheet: aiMarkdownStyle(Theme.of(context)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tokenText = find.byWidgetPredicate((widget) {
      if (widget is! RichText) return false;
      return widget.text.toPlainText(includePlaceholders: false) == token;
    });
    expect(tokenText, findsOneWidget);
    expect(find.text('仅名称'), findsOneWidget);

    final paragraph = tester.renderObject<RenderParagraph>(tokenText);
    expect(paragraph.text.toPlainText(includePlaceholders: false), token);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    );
    expect(boxes.length, greaterThan(1));
    for (final box in boxes) {
      expect(box.right, lessThanOrEqualTo(paragraph.size.width + 0.5));
      expect(box.left, greaterThanOrEqualTo(-0.5));
    }
    final table = tester.getRect(find.byType(AiMarkdownTable));
    final tokenRect = tester.getRect(tokenText);
    expect(tokenRect.left, greaterThanOrEqualTo(table.left));
    expect(tokenRect.right, lessThanOrEqualTo(table.right));
  });

  testWidgets('够宽时普通单词仍在同一行', (tester) async {
    const markdown = '| 说明 |\n| --- |\n| hello world |\n';
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: Builder(
              builder: (context) => MarkdownBody(
                data: markdown,
                selectable: true,
                blockSyntaxes: const [AiMarkdownTableSyntax()],
                builders: {AiMarkdownTableSyntax.tag: AiMarkdownTableBuilder()},
                styleSheet: aiMarkdownStyle(Theme.of(context)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final shown = find.byWidgetPredicate((widget) {
      if (widget is! RichText) return false;
      return widget.text.toPlainText(includePlaceholders: false) ==
          'hello world';
    });
    final paragraph = tester.renderObject<RenderParagraph>(shown);
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    );
    expect(boxes.map((box) => box.top).toSet(), hasLength(1));
  });
}
