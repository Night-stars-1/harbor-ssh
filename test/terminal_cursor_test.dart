import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('光标闪烁，输入恢复显示，失焦停止，遵循远端隐藏指令', (tester) async {
    final terminal = Terminal();
    final focus = FocusNode();
    final key = GlobalKey<TerminalViewState>();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            key: key,
            focusNode: focus,
            autofocus: true,
          ),
        ),
      ),
    );
    await tester.pump();
    final render = key.currentState!.renderTerminal;
    final color = TerminalThemes.defaultTheme.cursor;
    final filled = paints..rect(color: color, style: PaintingStyle.fill);
    final outlined = paints..rect(color: color, style: PaintingStyle.stroke);
    final cursor = paints..rect(color: color);

    expect(render, filled);
    await tester.pump(const Duration(milliseconds: 500));
    expect(render, isNot(cursor));
    await tester.pump(const Duration(milliseconds: 500));
    expect(render, filled);
    await tester.pump(const Duration(milliseconds: 500));
    expect(render, isNot(cursor));

    // No server echo is required for typing to restore the caret.
    tester.testTextInput.enterText('  a');
    await tester.pump();
    expect(render, filled);
    await tester.pump(const Duration(milliseconds: 500));
    expect(render, isNot(cursor));

    focus.unfocus();
    await tester.pump();
    expect(render, outlined);
    await tester.pump(const Duration(milliseconds: 700));
    expect(render, outlined);

    focus.requestFocus();
    await tester.pump();
    expect(render, filled);
    terminal.write('\x1b[?25l');
    await tester.pump();
    expect(render, isNot(cursor));
    await tester.pump(const Duration(milliseconds: 700));
    expect(render, isNot(cursor));
    terminal.write('\x1b[?25h');
    await tester.pump();
    expect(render, filled);
    await tester.pump(const Duration(milliseconds: 500));
    expect(render, isNot(cursor));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
