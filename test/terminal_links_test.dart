import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/data/web_link.dart';
import 'package:harbor_ssh/ui/terminal_links.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  test('网址检测保留查询参数、平衡括号，排除尾部标点和非网页协议', () {
    final terminal = Terminal()..resize(120, 20);
    terminal.write(
      '文档 😀 (https://example.com/wiki/A_(B)).\r\n'
      'https://example.com/search?a=1&b=2#part,\r\n'
      'http://localhost:8080/path\r\n'
      'file:///tmp/example javascript:alert(1)',
    );
    final links = terminalLinks(terminal.buffer, 0, 19);
    expect(links.map((link) => link.uri.toString()), [
      'https://example.com/wiki/A_(B)',
      'https://example.com/search?a=1&b=2#part',
      'http://localhost:8080/path',
    ]);
    expect(links.first.cells.first.x, 9);
  });

  test('从换行后的部分识别完整链接，窗口缩放和覆盖文本后重新识别', () {
    final terminal = Terminal()..resize(24, 10);
    const url = 'https://example.com/very/long/path?q=value';
    terminal.write('link: $url\r\n');
    final links = terminalLinks(terminal.buffer, 1, 1);
    expect(links.single.uri.toString(), url);
    expect(links.single.cells.map((cell) => cell.y).toSet().length, 2);
    terminal.resize(60, 10);
    expect(terminalLinks(terminal.buffer, 0, 9).single.uri.toString(), url);
    terminal.write('\x1b[2J\x1b[Hplain text');
    expect(terminalLinks(terminal.buffer, 0, 9), isEmpty);
  });

  test('链接装饰替换格子颜色，悬停才加下划线，不改缓冲区', () {
    final terminal = Terminal()..resize(80, 10);
    terminal.write('Docs: https://help.ubuntu.com\r\n');
    final original = terminal.buffer.lines[0].data.toList();
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 9);
    expect(style.decoration(0, 0), isNull);
    expect(style.decoration(6, 0)?.foreground, const Color(0xff9ecaff));
    expect(style.decoration(6, 0)?.underline, isFalse);
    style.prepare(terminal.buffer, 0, 9, hover: const CellOffset(10, 0));
    expect(style.decoration(10, 0)?.underline, isTrue);
    expect(style.decoration(0, 0), isNull);
    expect(terminal.buffer.lines[0].data, original);
  });

  test('打开链接不接受非 HTTP(S) 协议', () async {
    await expectLater(
      openWebLink(Uri.parse('file:///tmp/test')),
      throwsArgumentError,
    );
  });

  testWidgets('只有 Ctrl 悬停链接时显示下划线和手形，松键或移开立即恢复', (tester) async {
    final session = SshConnection(id: 'link-hover', host: testHost)
      ..status = ConnectionStatus.connected;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    session.terminal.write('Docs: https://help.ubuntu.com\r\n');
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final linkPosition = render.localToGlobal(
      render.getOffset(const CellOffset(10, 0)) + const Offset(2, 2),
    );
    final plainPosition = render.localToGlobal(const Offset(2, 2));
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).cellDecoration,
      isNotNull,
    );
    final mouse = TestGesture(
      dispatcher: tester.sendEventToBinding,
      kind: PointerDeviceKind.mouse,
      device: 7,
    );
    await mouse.addPointer(location: plainPosition);
    await mouse.moveTo(linkPosition);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(7),
      SystemMouseCursors.text,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(7),
      SystemMouseCursors.click,
    );

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(7),
      SystemMouseCursors.text,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
    await mouse.moveTo(plainPosition);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(7),
      SystemMouseCursors.text,
    );
    await mouse.moveTo(linkPosition);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(7),
      SystemMouseCursors.click,
    );
    await mouse.removePointer();
    await tester.pumpAndSettle();

    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl 点击打开链接，普通点击不打开，滚动和重绘保留原始文本', (tester) async {
    tester.view.physicalSize = const Size(1100, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'links', host: testHost)
      ..status = ConnectionStatus.connected;
    final opened = <Uri>[];
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(
            session: session,
            onReconnect: () {},
            onOpenLink: (uri) async => opened.add(uri),
          ),
        ),
      ),
    );
    session.terminal.write('Docs: https://help.ubuntu.com\r\n');
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    Offset at(CellOffset cell) => render.localToGlobal(
      render.getOffset(cell) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2),
    );
    final link = terminalLinks(session.terminal.buffer, 0, 0).single;
    expect(link.cells.first.x, 6);
    final cell = link.cells[10];
    final original = session.terminal.buffer.lines[0].data.toList();

    await tester.tapAt(at(cell), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(at(cell), kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(opened.map((uri) => uri.toString()), ['https://help.ubuntu.com']);
    expect(session.terminal.buffer.lines[0].data, original);

    session.terminal.write(List.filled(60, 'more output\r\n').join());
    await tester.pumpAndSettle();
    state.widget.scrollController!.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(at(cell), kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(opened.length, 2);
    final controller = state.widget.controller!;
    controller.setSelection(
      session.terminal.buffer.createAnchor(6, 0),
      session.terminal.buffer.createAnchor(29, 0),
    );
    await tester.pump();
    expect(
      session.terminal.buffer.getText(controller.selection!),
      'https://help.ubuntu.com',
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
