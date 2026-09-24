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

/// 裸 [TerminalView]：直接暴露 [TerminalController] 与纵向滚动控制器，
/// 便于同时观察选区、水平偏移和回看缓冲的偏移。
class _BareTerminal {
  _BareTerminal(this.terminal, this.controller, this.vertical);

  final Terminal terminal;
  final TerminalController controller;
  final ScrollController vertical;
}

Future<_BareTerminal> _pumpBareTerminal(
  WidgetTester tester, {
  required bool wrap,
  ScrollBehavior? scrollBehavior,
}) async {
  final terminal = Terminal()..lineWrap = wrap;
  final controller = TerminalController();
  final vertical = ScrollController();
  final focus = FocusNode();
  addTearDown(() {
    controller.dispose();
    vertical.dispose();
    focus.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      scrollBehavior: scrollBehavior,
      home: Scaffold(
        body: TerminalView(
          terminal,
          controller: controller,
          scrollController: vertical,
          focusNode: focus,
          padding: const EdgeInsets.all(8),
          textStyle: const TerminalStyle(fontSize: 14, fontFamily: 'monospace'),
          // 只观察手势本身：不接通输入法，也不让按键进入终端。
          autofocus: false,
          readOnly: true,
          hardwareKeyboardOnly: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _BareTerminal(terminal, controller, vertical);
}

/// 终端正文里的一个点，避开内边距和底部水平条。
Offset _bodyPoint(WidgetTester tester, {double dx = 40, double dy = 40}) =>
    _view(tester).renderTerminal.localToGlobal(Offset(dx, dy));

/// 在正文上触摸横向拖动 [dx]（负数为向左拖），
/// 返回这段拖动带来的水平偏移净变化：内容应当逐像素跟随手指。
Future<double> _panBodyHorizontally(
  WidgetTester tester,
  double dx, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final render = _view(tester).renderTerminal;
  final gesture = await tester.startGesture(_bodyPoint(tester), kind: kind);
  await tester.pump();
  final before = render.horizontalOffset;
  // 先越过手势识别阈值，再走完剩下的距离，两段位移都不该被吞掉。
  await gesture.moveBy(Offset(30.0 * dx.sign, 0));
  await gesture.moveBy(Offset(dx - 30.0 * dx.sign, 0));
  await tester.pump();
  final after = render.horizontalOffset;
  await gesture.up();
  await tester.pumpAndSettle();
  return after - before;
}

void main() {
  testWidgets('拖拽选中多行时滚动，起点仍绑定原文字', (tester) async {
    _useSurface(tester, const Size(420, 300));
    final bare = await _pumpBareTerminal(tester, wrap: true);
    bare.terminal.write(
      List.generate(
        90,
        (i) => 'row-${i.toString().padLeft(3, '0')}',
      ).join('\r\n'),
    );
    await tester.pumpAndSettle();
    final render = _view(tester).renderTerminal;
    final height = render.lineHeight;
    bare.vertical.jumpTo(15 * height);
    await tester.pumpAndSettle();

    Offset point(int row, int column) => render.localToGlobal(
      render.getOffset(CellOffset(column, row)) +
          Offset(render.cellSize.width / 2, height / 2),
    );
    final start = point(20, 0);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(point(22, 5));
    await tester.pump();
    expect(bare.controller.selection!.normalized.begin.y, 20);
    expect(
      bare.terminal.buffer.getText(bare.controller.selection),
      startsWith('row-020'),
    );

    bare.vertical.jumpTo(18 * height);
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(0, 2));
    await tester.pump();
    expect(bare.controller.selection!.normalized.begin.y, 20);
    final selected = bare.terminal.buffer.getText(bare.controller.selection);
    expect(selected, startsWith('row-020'));
    expect(bare.controller.selection!.normalized.end.y, 25);
    expect(selected, contains('row-024'));

    await gesture.up();
    bare.vertical.jumpTo(23 * height);
    await tester.pumpAndSettle();
    expect(bare.terminal.buffer.getText(bare.controller.selection), selected);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按选词并滚动时起点仍绑定原单词', (tester) async {
    _useSurface(tester, const Size(420, 300));
    final bare = await _pumpBareTerminal(tester, wrap: true);
    bare.terminal.write(
      List.generate(
        90,
        (i) => 'word${i.toString().padLeft(3, '0')}',
      ).join('\r\n'),
    );
    await tester.pumpAndSettle();
    final render = _view(tester).renderTerminal;
    final height = render.lineHeight;
    bare.vertical.jumpTo(15 * height);
    await tester.pumpAndSettle();
    Offset point(int row) => render.localToGlobal(
      render.getOffset(CellOffset(2, row)) +
          Offset(render.cellSize.width / 2, height / 2),
    );

    final gesture = await tester.startGesture(
      point(20),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(point(22));
    await tester.pump();
    expect(
      bare.terminal.buffer.getText(bare.controller.selection),
      startsWith('word020'),
    );

    bare.vertical.jumpTo(18 * height);
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(0, 2));
    await tester.pump();
    expect(bare.controller.selection!.normalized.begin.y, 20);
    expect(
      bare.terminal.buffer.getText(bare.controller.selection),
      startsWith('word020'),
    );
    await gesture.up();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final alternate in [false, true]) {
    testWidgets('Shift 滚轮只横向滚动，替代屏幕=$alternate', (tester) async {
      _useSurface(tester, const Size(420, 700));
      final bare = await _pumpBareTerminal(
        tester,
        wrap: false,
        // Do not rely on Flutter's default Shift axis conversion to prevent
        // simultaneous vertical scroll; the terminal must claim the signal.
        scrollBehavior: const ScrollBehavior().copyWith(
          pointerAxisModifiers: {},
        ),
      );
      bare.terminal.write(List.generate(150, (i) => 'line $i\r\n').join());
      if (alternate) bare.terminal.write('\x1b[?1049h');
      bare.terminal.write('x' * 120);
      await tester.pumpAndSettle();
      if (!alternate) {
        bare.vertical.jumpTo(bare.vertical.position.maxScrollExtent / 2);
        await tester.pumpAndSettle();
      }
      final render = _view(tester).renderTerminal;
      render.horizontalOffset = 200;
      await tester.pumpAndSettle();
      final initialVertical = bare.vertical.offset;
      final output = <String>[];
      bare.terminal.onOutput = output.add;
      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: _bodyPoint(tester),
            scrollDelta: delta,
          ),
        );
        await tester.pumpAndSettle();
      }

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      try {
        await wheel(const Offset(0, 120));
        expect(render.horizontalOffset, closeTo(320, 0.5));
        await wheel(const Offset(0, -80));
        expect(render.horizontalOffset, closeTo(240, 0.5));
        // Some platforms already convert Shift+wheel into dx.
        await wheel(const Offset(40, 0));
        expect(render.horizontalOffset, closeTo(280, 0.5));
        await wheel(Offset(0, render.maxHorizontalExtent * 2));
        expect(render.horizontalOffset, render.maxHorizontalExtent);
        await wheel(const Offset(0, 100));
        expect(render.horizontalOffset, render.maxHorizontalExtent);
        expect(bare.vertical.offset, initialVertical);
        expect(output, isEmpty);
        expect(
          _barController(tester).offset,
          closeTo(render.horizontalOffset, 0.5),
        );
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      }
      final horizontal = render.horizontalOffset;
      await wheel(const Offset(0, 60));
      expect(render.horizontalOffset, horizontal);
      if (alternate) {
        expect(output, isNotEmpty);
      } else {
        expect(bare.vertical.offset, closeTo(initialVertical + 60, 0.5));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

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

  testWidgets('关闭换行仅滚到实际文本尾部，擦除后范围随内容收缩', (tester) async {
    _useSurface(tester, const Size(420, 700));
    final bare = await _pumpBareTerminal(tester, wrap: false);
    final render = _view(tester).renderTerminal;
    final visible = render.size.width ~/ render.cellSize.width;
    expect(bare.terminal.viewWidth, Terminal.unwrapColumns);
    expect(render.maxHorizontalExtent, 0);
    expect(find.byKey(_scrollbarKey), findsNothing);

    bare.terminal.write('short');
    await tester.pumpAndSettle();
    expect(render.maxHorizontalExtent, 0);
    expect(find.byKey(_scrollbarKey), findsNothing);

    bare.terminal.write('\r${'x' * (visible + 15)}');
    await tester.pumpAndSettle();
    expect(
      render.maxHorizontalExtent,
      closeTo(15 * render.cellSize.width, 0.5),
    );
    expect(find.byKey(_scrollbarKey), findsOneWidget);
    render.horizontalOffset = render.maxHorizontalExtent;
    await tester.pumpAndSettle();
    final finalCell = render.getOffset(CellOffset(visible + 14, 0));
    expect(finalCell.dx, greaterThanOrEqualTo(0));
    expect(
      finalCell.dx + render.cellSize.width,
      lessThanOrEqualTo(render.size.width + 0.5),
    );

    bare.terminal.write('\r\x1b[2K');
    await tester.pumpAndSettle();
    expect(render.maxHorizontalExtent, 0);
    expect(render.horizontalOffset, 0);
    expect(find.byKey(_scrollbarKey), findsNothing);
    expect(bare.terminal.viewWidth, Terminal.unwrapColumns);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
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

  testWidgets('关闭换行后出现水平条，滚轮和拖动改变水平偏移，格子对齐', (tester) async {
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
    // 与复制命令同一条 buffer.getText 路径：若按视口宽度截断，这里只剩 512 个字符。
    expect(
      terminal.buffer.getText(selection!).replaceAll('\n', ''),
      'a' * 2000,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭换行时正文触摸横拖平移内容，偏移夹在 0 与最大水平偏移之间', (tester) async {
    _useSurface(tester, const Size(420, 700));
    final bare = await _pumpBareTerminal(tester, wrap: false);
    bare.terminal.write('a' * 2000);
    await tester.pumpAndSettle();

    final render = _view(tester).renderTerminal;
    final max = render.maxHorizontalExtent;
    expect(max, greaterThan(0));
    // 从中间位置出发，两个方向都还有可拖动的距离。
    render.horizontalOffset = max / 2;
    await tester.pumpAndSettle();
    final bar = _barController(tester);
    expect(bar.offset, closeTo(max / 2, 0.5));
    final verticalBefore = bare.vertical.offset;

    // 手指向左拖，内容跟着手指走，纵向滚动和选区不受影响。
    expect(await _panBodyHorizontally(tester, -240), closeTo(240, 0.5));
    expect(render.horizontalOffset, closeTo(max / 2 + 240, 0.5));
    expect(bar.offset, closeTo(render.horizontalOffset, 0.5));
    expect(bare.controller.selection, isNull);
    expect(bare.vertical.offset, verticalBefore);

    // 手指向右拖回。
    expect(await _panBodyHorizontally(tester, 100), closeTo(-100, 0.5));
    expect(render.horizontalOffset, closeTo(max / 2 + 140, 0.5));

    // 拖到两端都被夹在 0 与最大偏移之间，不会越界。
    await _panBodyHorizontally(tester, -(max + 400));
    expect(render.horizontalOffset, closeTo(max, 0.5));
    await _panBodyHorizontally(tester, max + 400);
    expect(render.horizontalOffset, 0);
    await _panBodyHorizontally(tester, 200);
    expect(render.horizontalOffset, 0);

    expect(bare.controller.selection, isNull);
    expect(bare.vertical.offset, verticalBefore);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认换行时正文触摸横拖不平移，也不出现水平条', (tester) async {
    _useSurface(tester, const Size(420, 700));
    final bare = await _pumpBareTerminal(tester, wrap: true);
    bare.terminal.write('a' * 2000);
    await tester.pumpAndSettle();

    final render = _view(tester).renderTerminal;
    expect(bare.terminal.lineWrap, isTrue);
    expect(render.maxHorizontalExtent, 0);
    expect(find.byKey(_scrollbarKey), findsNothing);

    expect(await _panBodyHorizontally(tester, -240), 0);
    expect(await _panBodyHorizontally(tester, 240), 0);
    expect(render.horizontalOffset, 0);
    expect(bare.controller.selection, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭换行时正文纵向触摸拖动仍能回看历史缓冲，水平偏移不变', (tester) async {
    _useSurface(tester, const Size(420, 700));
    final bare = await _pumpBareTerminal(tester, wrap: false);
    for (var i = 0; i < 200; i++) {
      bare.terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();

    final render = _view(tester).renderTerminal;
    final maxScroll = bare.vertical.position.maxScrollExtent;
    expect(maxScroll, greaterThan(0));
    // 放到缓冲中间，纵向两个方向都还有空间。
    bare.vertical.jumpTo(maxScroll / 2);
    await tester.pump();
    final horizontalBefore = render.horizontalOffset;
    expect(horizontalBefore, 0);

    final gesture = await tester.startGesture(
      _bodyPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(0, 60)); // 越过纵向手势识别阈值
    await tester.pump();
    final before = bare.vertical.offset;
    await gesture.moveBy(const Offset(0, 120)); // 手指向下，回看更早的输出
    await tester.pump();
    expect(before - bare.vertical.offset, closeTo(120, 1));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(bare.vertical.offset, lessThan(before));
    expect(bare.vertical.offset, greaterThanOrEqualTo(0));
    expect(bare.vertical.offset, lessThan(maxScroll));
    expect(render.horizontalOffset, horizontalBefore);
    expect(bare.controller.selection, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('触摸长按与鼠标拖动仍然选择正文文本，不会横向平移', (tester) async {
    _useSurface(tester, const Size(420, 700));
    final bare = await _pumpBareTerminal(tester, wrap: false);
    // 每一行都是同一个长词，任意可见位置都落在词内。
    for (var i = 0; i < 6; i++) {
      bare.terminal.write('w' * 2000 + '\r\n');
    }
    await tester.pumpAndSettle();

    final render = _view(tester).renderTerminal;
    final max = render.maxHorizontalExtent;
    expect(max, greaterThan(0));
    render.horizontalOffset = max / 2;
    await tester.pumpAndSettle();
    final horizontalBefore = render.horizontalOffset;
    expect(horizontalBefore, greaterThan(0));

    // 触摸长按后继续拖动：仍然按词选择，不横向平移。
    final press = await tester.startGesture(_bodyPoint(tester));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    final word = bare.controller.selection;
    expect(word, isNotNull);
    expect(bare.terminal.buffer.getText(word!), contains('w'));
    await press.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(bare.controller.selection, isNotNull);
    expect(render.horizontalOffset, horizontalBefore);
    await press.up();
    await tester.pumpAndSettle();

    // 鼠标拖动仍然是字符选择，同样不横向平移。
    bare.controller.clearSelection();
    await tester.pump();
    final mouse = await tester.startGesture(
      _bodyPoint(tester),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(140, 0));
    await tester.pump();
    final chars = bare.controller.selection;
    expect(chars, isNotNull);
    final text = bare.terminal.buffer.getText(chars!);
    expect(text, isNotEmpty);
    expect(text.replaceAll('w', ''), isEmpty);
    expect(render.horizontalOffset, horizontalBefore);
    await mouse.up();
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
