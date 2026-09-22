import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

const _scrollbarKey = ValueKey('terminal-horizontal-scrollbar');

SshConnection _connected(String id) =>
    SshConnection(id: id, host: testHost)..status = ConnectionStatus.connected;

/// 不传 [wrap] 时使用 [TerminalPane] 的默认值，覆盖默认自动换行。
Future<void> _pumpTerminal(
  WidgetTester tester,
  SshConnection session, {
  bool? wrap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: harborTheme(),
      home: Scaffold(
        body: wrap == null
            ? TerminalPane(session: session, onReconnect: () {})
            : TerminalPane(
                session: session,
                onReconnect: () {},
                terminalWrap: wrap,
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

TerminalViewState _view(WidgetTester tester) =>
    tester.state<TerminalViewState>(find.byType(TerminalView));

/// 缓冲区里有内容的行，用于观察折行结果与文本是否完整。
List<String> _contentRows(Terminal terminal) {
  final rows = <String>[];
  for (var i = 0; i < terminal.buffer.lines.length; i++) {
    final text = terminal.buffer.lines[i].getText();
    if (text.isNotEmpty) rows.add(text);
  }
  return rows;
}

ScrollController _barController(WidgetTester tester) {
  final view = tester.widget<SingleChildScrollView>(
    find.descendant(
      of: find.byKey(_scrollbarKey),
      matching: find.byType(SingleChildScrollView),
    ),
  );
  return view.controller!;
}

void main() {
  test('恢复换行时即使列宽不变也重排长行并保留输入位置', () {
    final terminal = Terminal()..resize(512, 24);
    terminal.lineWrap = false;
    terminal.write('a' * 2000);
    terminal.lineWrap = true;
    terminal.resize(512, 24);
    expect(_contentRows(terminal).map((row) => row.length), [
      512,
      512,
      512,
      464,
    ]);
    terminal.write('Z');
    expect(_contentRows(terminal).join(), '${'a' * 2000}Z');
  });

  testWidgets('关闭换行时 2000 字符保持单行，远端列宽取视口与 512 的较大值，缩放窗口不丢尾', (tester) async {
    _useSurface(tester, const Size(800, 900));
    final session = _connected('unwrap');
    addTearDown(session.dispose);
    await _pumpTerminal(tester, session, wrap: false);
    final terminal = session.terminal;
    expect(terminal.lineWrap, isFalse);

    terminal.write('a' * 2000);
    await tester.pumpAndSettle();

    final render = _view(tester).renderTerminal;
    final viewportColumns = render.size.width ~/ render.cellSize.width;
    expect(viewportColumns, lessThan(Terminal.unwrapColumns));
    // 视口比 512 列窄时仍按 512 列通知远端，长行留在一行里横向滚动。
    expect(terminal.viewWidth, Terminal.unwrapColumns);
    expect(_contentRows(terminal), ['a' * 2000]);
    expect(render.maxHorizontalExtent, greaterThan(0));

    // 横向滚到最右时，行尾最后一格仍在视口内，说明尾部没有被裁掉。
    render.horizontalOffset = render.maxHorizontalExtent;
    await tester.pumpAndSettle();
    final tail = render.getOffset(const CellOffset(1999, 0));
    expect(tail.dx, greaterThanOrEqualTo(0));
    expect(
      tail.dx + render.cellSize.width,
      lessThanOrEqualTo(render.size.width + 0.5),
    );

    // 窗口比 512 列更宽时远端列宽跟随视口，缩回后回到 512 列，两种变化都不截断行尾。
    final cell = render.cellSize.width;
    tester.view.physicalSize = Size(
      cell * (Terminal.unwrapColumns + 40) + 8,
      900,
    );
    await tester.pumpAndSettle();
    expect(terminal.viewWidth, greaterThan(Terminal.unwrapColumns));
    expect(_contentRows(terminal), ['a' * 2000]);

    tester.view.physicalSize = const Size(800, 900);
    await tester.pumpAndSettle();
    expect(terminal.viewWidth, Terminal.unwrapColumns);
    expect(_contentRows(terminal), ['a' * 2000]);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认开启换行时按视口宽度折行且不出现水平条', (tester) async {
    _useSurface(tester, const Size(800, 900));
    final session = _connected('wrap');
    addTearDown(session.dispose);
    await _pumpTerminal(tester, session);

    final terminal = session.terminal;
    expect(terminal.lineWrap, isTrue);
    final render = _view(tester).renderTerminal;
    final columns = render.size.width ~/ render.cellSize.width;
    expect(terminal.viewWidth, columns);

    terminal.write('a' * 2000);
    await tester.pumpAndSettle();

    final rows = _contentRows(terminal);
    expect(rows.length, (2000 + columns - 1) ~/ columns);
    expect(rows.join(), 'a' * 2000);
    expect(render.maxHorizontalExtent, 0);
    expect(find.byKey(_scrollbarKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭换行后出现水平条，滚轮和拖动改变水平偏移，格子对齐且光标留在视口内', (tester) async {
    _useSurface(tester, const Size(800, 900));
    final session = _connected('scroll');
    addTearDown(session.dispose);
    await _pumpTerminal(tester, session, wrap: false);
    final terminal = session.terminal;

    terminal.write('a' * 2000);
    await tester.pumpAndSettle();

    final bar = find.byKey(_scrollbarKey);
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.byType(RawScrollbar)),
      findsOneWidget,
    );
    final render = _view(tester).renderTerminal;

    // 写入超长行后光标自动跟随，停在视口内。
    final cursor = render.cursorOffset;
    expect(cursor.dx, greaterThanOrEqualTo(0));
    expect(
      cursor.dx + render.cellSize.width,
      lessThanOrEqualTo(render.size.width + 0.5),
    );

    // 最右端时指针坐标与格子对齐：行尾格子中心的点仍映射回该格。
    const tail = CellOffset(1999, 0);
    final tailCenter =
        render.getOffset(tail) +
        Offset(render.cellSize.width / 2, render.cellSize.height / 2);
    expect(tailCenter.dx, greaterThanOrEqualTo(0));
    expect(tailCenter.dx, lessThanOrEqualTo(render.size.width));
    expect(render.getCellOffset(tailCenter), tail);

    // 水平滚轮（只有 dx）把内容拉回中间，水平条控制器与渲染偏移保持一致。
    final controller = _barController(tester);
    final center = tester.getCenter(find.byType(TerminalView));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(center);
    await tester.pumpAndSettle();
    final extent = render.maxHorizontalExtent;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: center,
        scrollDelta: Offset(extent / 2 - render.horizontalOffset, 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(render.horizontalOffset, closeTo(extent / 2, 1));
    expect(controller.offset, closeTo(render.horizontalOffset, 0.5));

    // 向左拖动位于中间的滑块，内容应向行首移动。
    final beforeDrag = render.horizontalOffset;
    await tester.dragFrom(tester.getCenter(bar), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(render.horizontalOffset, lessThan(beforeDrag));
    expect(controller.offset, closeTo(render.horizontalOffset, 0.5));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('重新开启换行时按新列宽重排且不丢字符，水平条消失', (tester) async {
    _useSurface(tester, const Size(800, 900));
    final session = _connected('rewrap');
    addTearDown(session.dispose);
    await _pumpTerminal(tester, session, wrap: false);
    final terminal = session.terminal;

    terminal.write('a' * 2000);
    await tester.pumpAndSettle();
    expect(_contentRows(terminal), ['a' * 2000]);
    expect(find.byKey(_scrollbarKey), findsOneWidget);

    await _pumpTerminal(tester, session, wrap: true);
    expect(terminal.lineWrap, isTrue);

    final render = _view(tester).renderTerminal;
    final columns = render.size.width ~/ render.cellSize.width;
    expect(terminal.viewWidth, columns);
    final rows = _contentRows(terminal);
    expect(rows.length, (2000 + columns - 1) ~/ columns);
    expect(rows.join(), 'a' * 2000);
    expect(render.maxHorizontalExtent, 0);
    expect(find.byKey(_scrollbarKey), findsNothing);

    terminal.write('Z');
    await tester.pumpAndSettle();
    expect(_contentRows(terminal).join(), '${'a' * 2000}Z');

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭换行时全选整条逻辑行，复制文本包含全部 2000 字符', (tester) async {
    _useSurface(tester, const Size(800, 900));
    final terminal = Terminal()..lineWrap = false;
    final controller = TerminalController();
    final focus = FocusNode();
    addTearDown(() {
      controller.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            focusNode: focus,
            autofocus: true,
            padding: const EdgeInsets.all(16),
            textStyle: const TerminalStyle(
              fontSize: 14,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 最后一行必须超宽，否则中间行本来就会全选，无法捕获末行截断。
    terminal.write('\x1b[${terminal.viewHeight};1H');
    terminal.write('a' * 2000);
    await tester.pumpAndSettle();
    expect(_contentRows(terminal), ['a' * 2000]);

    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final selection = controller.selection;
    expect(selection, isNotNull);
    expect(selection!.begin, const CellOffset(0, 0));
    // 与复制命令同一条 buffer.getText 路径：若按视口宽度截断，这里只剩 512 个字符。
    expect(terminal.buffer.getText(selection).replaceAll('\n', ''), 'a' * 2000);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
