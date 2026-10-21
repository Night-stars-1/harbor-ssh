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

  test('宽字符与软换行链接的命中、悬停和颜色更新保持一致', () {
    final terminal = Terminal()..resize(18, 8);
    terminal.write('前😀 https://example.com/宽字符\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 7);
    final link = terminalLinks(terminal.buffer, 0, 7).single;
    expect(link.cells.map((cell) => cell.y).toSet().length, 2);
    expect(style.linkAt(terminal.buffer, link.cells.first), link.uri);
    expect(
      style.linkAt(
        terminal.buffer,
        CellOffset(link.cells.first.x - 1, link.cells.first.y),
      ),
      isNull,
    );
    final middle = link.cells[link.cells.length ~/ 2];
    expect(style.decoration(middle.x, middle.y)?.underline, isFalse);
    expect(
      style.decoration(middle.x, middle.y)?.foreground,
      const Color(0xff9ecaff),
    );

    style.prepare(terminal.buffer, 0, 7, hover: middle);
    expect(
      style.decoration(link.cells.first.x, link.cells.first.y)?.underline,
      isTrue,
    );
    expect(style.decoration(middle.x, middle.y)?.underline, isTrue);

    style.color = const Color(0xffff5252);
    expect(
      style.decoration(middle.x, middle.y)?.foreground,
      const Color(0xffff5252),
    );
    expect(style.decoration(middle.x, middle.y)?.underline, isTrue);

    style.prepare(terminal.buffer, 0, 7);
    expect(style.decoration(middle.x, middle.y)?.underline, isFalse);
    style.prepare(terminal.buffer, 0, 7, hover: middle);
    expect(style.decoration(middle.x, middle.y)?.underline, isTrue);
    expect(style.linkAt(terminal.buffer, middle), link.uri);
  });

  test('不换行超长行 65536 列之后的链接可命中且可悬停', () {
    final terminal = Terminal()..resize(80, 3);
    terminal.lineWrap = false;
    const prefix = 66000;
    const url = 'https://example.com/beyond-16-bit';
    terminal.write(String.fromCharCodes(List.filled(prefix, 0x61)));
    terminal.write(' $url');
    final buffer = terminal.buffer;
    final link = terminalLinks(buffer, 0, 0).single;
    expect(link.uri.toString(), url);
    expect(link.cells.first.x, prefix + 1);
    expect(link.cells.first.x, greaterThanOrEqualTo(1 << 16));

    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(buffer, 0, 0);
    expect(
      style.decoration(link.cells.first.x, 0)?.foreground,
      const Color(0xff9ecaff),
    );
    expect(style.decoration(link.cells.first.x - 1, 0), isNull);
    expect(style.linkAt(buffer, link.cells.first), link.uri);

    final last = link.cells.last;
    style.prepare(buffer, 0, 0, hover: last);
    expect(style.decoration(last.x, last.y)?.underline, isTrue);
    expect(style.decoration(link.cells.first.x, 0)?.underline, isTrue);
  });

  test('悬停点在链接跨出可见区的部分时可见格子仍整条加下划线', () {
    final terminal = Terminal()..resize(24, 6);
    terminal.write('https://example.com/very/long/path/target\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    final link = terminalLinks(terminal.buffer, 0, 5).single;
    final first = link.cells.first;
    final outside = link.cells.firstWhere((cell) => cell.y > 0);
    style.prepare(terminal.buffer, 0, 0, hover: outside);
    expect(style.decoration(first.x, first.y)?.underline, isTrue);
    expect(style.linkAt(terminal.buffer, outside), link.uri);
    style.prepare(terminal.buffer, 0, 0);
    expect(style.decoration(first.x, first.y)?.underline, isFalse);
  });

  test('小回滚缓冲持续软换行输出后旧链接清除、新链接仍可命中', () {
    final terminal = Terminal(maxLines: 24)..resize(16, 4);
    terminal.write('https://example.com/tracked ');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 3);
    final old = terminalLinks(terminal.buffer, 0, 3).single;
    final oldCell = old.cells.first;
    expect(style.linkAt(terminal.buffer, oldCell), old.uri);

    terminal.write(List.filled(40, 'abcdefghijklmnop').join());
    expect(terminal.buffer.height, 24);
    style.prepare(terminal.buffer, 0, 23);
    expect(terminalLinks(terminal.buffer, 0, 23), isEmpty);
    expect(style.linkAt(terminal.buffer, oldCell), isNull);
    expect(style.decoration(oldCell.x, oldCell.y), isNull);

    terminal.write(' https://example.com/fresh');
    style.prepare(terminal.buffer, 0, 23);
    final fresh = terminalLinks(terminal.buffer, 0, 23).single;
    expect(fresh.uri.toString(), 'https://example.com/fresh');
    final freshCell = fresh.cells.first;
    style.prepare(terminal.buffer, 0, 23, hover: freshCell);
    expect(style.decoration(freshCell.x, freshCell.y)?.underline, isTrue);
    expect(style.linkAt(terminal.buffer, freshCell), fresh.uri);
  });

  test('跨出可见区的软换行链接仍可悬停和命中', () {
    final terminal = Terminal()..resize(24, 8);
    terminal.write('prefix https://example.com/a/very/long/target\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    final link = terminalLinks(terminal.buffer, 0, 7).single;
    final lastRow = link.cells
        .map((cell) => cell.y)
        .reduce((a, b) => a > b ? a : b);
    expect(lastRow, greaterThan(0));
    final cell = link.cells.firstWhere((cell) => cell.y == lastRow);

    style.prepare(terminal.buffer, lastRow, lastRow);
    expect(style.decoration(cell.x, cell.y)?.underline, isFalse);
    style.prepare(terminal.buffer, lastRow, lastRow, hover: cell);
    expect(style.decoration(cell.x, cell.y)?.underline, isTrue);
    expect(style.linkAt(terminal.buffer, cell), link.uri);
  });

  test('原地覆写和清屏后悬停装饰与命中立即失效', () {
    final terminal = Terminal()..resize(60, 6);
    terminal.write('Docs: https://one.example/path\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 5);
    final link = terminalLinks(terminal.buffer, 0, 5).single;
    final cell = link.cells[4];
    style.prepare(terminal.buffer, 0, 5, hover: cell);
    expect(style.decoration(cell.x, cell.y)?.underline, isTrue);
    expect(style.linkAt(terminal.buffer, cell), link.uri);

    terminal.write('\x1b[1;1H\x1b[2Kplain text');
    style.prepare(terminal.buffer, 0, 5, hover: cell);
    expect(style.decoration(cell.x, cell.y), isNull);
    expect(style.linkAt(terminal.buffer, cell), isNull);
    expect(terminalLinks(terminal.buffer, 0, 5), isEmpty);

    terminal.write('\x1b[2J\x1b[Hhttps://two.example/other');
    style.prepare(terminal.buffer, 0, 5);
    final next = terminalLinks(terminal.buffer, 0, 5).single;
    expect(next.uri.toString(), 'https://two.example/other');
    expect(style.linkAt(terminal.buffer, next.cells.first), next.uri);
  });

  test('窗口缩放重排后链接位置与命中同步更新', () {
    final terminal = Terminal()..resize(20, 6);
    terminal.write('link: https://example.com/some/long/path\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 5);
    final before = terminalLinks(terminal.buffer, 0, 5).single;
    expect(before.cells.map((cell) => cell.y).toSet().length, greaterThan(1));

    terminal.resize(70, 6);
    style.prepare(terminal.buffer, 0, 5);
    final after = terminalLinks(terminal.buffer, 0, 5).single;
    expect(after.uri, before.uri);
    expect(after.cells.map((cell) => cell.y).toSet().length, 1);
    final cell = after.cells.last;
    style.prepare(terminal.buffer, 0, 5, hover: cell);
    expect(style.decoration(cell.x, cell.y)?.underline, isTrue);
    expect(style.linkAt(terminal.buffer, cell), after.uri);
  });

  test('切换备用屏幕后只识别当前缓冲区链接', () {
    final terminal = Terminal()..resize(60, 6);
    terminal.write('main https://main.example/a\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 5);
    final mainLink = terminalLinks(terminal.buffer, 0, 5).single;
    expect(style.linkAt(terminal.buffer, mainLink.cells.first), mainLink.uri);

    terminal.write('\x1b[?1049h\x1b[2J\x1b[Halt https://alt.example/b');
    style.prepare(terminal.buffer, 0, 5);
    final altLink = terminalLinks(terminal.buffer, 0, 5).single;
    expect(altLink.uri.toString(), 'https://alt.example/b');
    expect(style.linkAt(terminal.buffer, altLink.cells.first), altLink.uri);
    expect(style.linkAt(terminal.buffer, const CellOffset(0, 0)), isNull);
    style.prepare(terminal.buffer, 0, 5, hover: altLink.cells.first);
    expect(
      style.decoration(altLink.cells.first.x, altLink.cells.first.y)?.underline,
      isTrue,
    );

    terminal.write('\x1b[?1049l');
    style.prepare(terminal.buffer, 0, 5);
    expect(
      terminalLinks(terminal.buffer, 0, 5).single.uri.toString(),
      'https://main.example/a',
    );
    expect(style.linkAt(terminal.buffer, mainLink.cells.first), mainLink.uri);
    expect(
      style.decoration(altLink.cells.first.x, altLink.cells.first.y),
      isNull,
    );
  });

  test('回滚环形移位后旧坐标不会误命中，新输出重新识别', () {
    final terminal = Terminal(maxLines: 24)..resize(50, 5);
    terminal.write('top\r\nhttps://example.com/tracked\r\n');
    final style = TerminalLinkStyle(const Color(0xff9ecaff));
    style.prepare(terminal.buffer, 0, 4);
    final link = terminalLinks(terminal.buffer, 0, 4).single;
    final oldCell = link.cells.first;

    terminal.write(List.filled(40, 'filler line\r\n').join());
    style.prepare(terminal.buffer, 0, terminal.buffer.height - 1);
    expect(
      terminalLinks(terminal.buffer, 0, terminal.buffer.height - 1),
      isEmpty,
    );
    expect(style.linkAt(terminal.buffer, oldCell), isNull);

    terminal.write('again https://example.com/again');
    style.prepare(terminal.buffer, 0, terminal.buffer.height - 1);
    final again = terminalLinks(
      terminal.buffer,
      0,
      terminal.buffer.height - 1,
    ).single;
    expect(again.uri.toString(), 'https://example.com/again');
    expect(style.linkAt(terminal.buffer, again.cells.first), again.uri);
  });

  testWidgets('悬停中内容覆写后链接下划线与手形立即消失', (tester) async {
    final session = SshConnection(id: 'link-overwrite', host: testHost)
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
    final mouse = TestGesture(
      dispatcher: tester.sendEventToBinding,
      kind: PointerDeviceKind.mouse,
      device: 9,
    );
    await mouse.addPointer(location: linkPosition);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(9),
      SystemMouseCursors.click,
    );

    session.terminal.write('\x1b[1;1H\x1b[2Kplain text');
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(9),
      SystemMouseCursors.text,
    );

    session.terminal.write('\x1b[2J\x1b[Hhttps://help.ubuntu.com');
    await tester.pumpAndSettle();
    await mouse.moveTo(
      render.localToGlobal(
        render.getOffset(const CellOffset(10, 0)) + const Offset(2, 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(9),
      SystemMouseCursors.click,
    );

    await mouse.removePointer();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
