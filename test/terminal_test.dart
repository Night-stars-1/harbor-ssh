import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  testWidgets('终端绑定当前窗口，普通文本和输入法提交内容发送到远端', (tester) async {
    final session = SshConnection(id: 'text-input', host: testHost)
      ..status = ConnectionStatus.connected;
    final output = <String>[];
    session.terminal.onOutput = output.add;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final attachments = tester.testTextInput.log.where(
      (call) => call.method == 'TextInput.setClient',
    );
    expect(attachments, isNotEmpty);
    expect(
      (attachments.last.arguments as List)[1]['viewId'],
      tester.view.viewId,
    );
    tester.testTextInput.enterText('  echo hello');
    await tester.pump();
    expect(output.join(), 'echo hello');
    output.clear();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  zhongwen',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 2, end: 10),
      ),
    );
    await tester.pump();
    expect(output, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  中文',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    expect(output.join(), '中文');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(output.join(), '中文\r');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('右键有选区直接复制，无选区直接粘贴，不弹菜单', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'context-menu', host: testHost)
      ..status = ConnectionStatus.connected;
    session.terminal.write('hello world');
    final output = <String>[];
    session.terminal.onOutput = output.add;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': 'whoami'};
        return null;
      },
    );
    addTearDown(() {
      session.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('复制选中内容'), findsNothing);
    expect(find.byTooltip('粘贴'), findsNothing);
    final terminal = find.byType(TerminalView);
    await tester.tap(terminal, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(output.join(), 'whoami');
    final controller = tester.widget<TerminalView>(terminal).controller!;
    controller.setSelection(
      session.terminal.buffer.createAnchor(0, 0),
      session.terminal.buffer.createAnchor(5, 0),
    );
    await tester.pump();
    await tester.tap(terminal, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(copied, 'hello');
    expect(output.join(), 'whoami');
    expect(controller.selection, isNull);
    await tester.tap(terminal, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(output.join(), 'whoamiwhoami');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('screen 开启鼠标上报后仍可右键复制选中的文字', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'screen-copy', host: testHost)
      ..status = ConnectionStatus.connected;
    session.terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006hscreen text');
    final sent = <String>[];
    session.terminal.onOutput = sent.add;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
        }
        if (call.method == 'Clipboard.getData') return {'text': 'pwd'};
        return null;
      },
    );
    addTearDown(() {
      session.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final terminal = find.byType(TerminalView);
    final controller = tester.widget<TerminalView>(terminal).controller!;
    final render = tester.state<TerminalViewState>(terminal).renderTerminal;
    Offset point(int column) => render.localToGlobal(
      render.getOffset(CellOffset(column, 0)) +
          Offset(render.cellSize.width / 2, render.lineHeight / 2),
    );
    final drag = await tester.startGesture(
      point(0),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(point(5));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(session.terminal.buffer.getText(controller.selection), 'screen');
    await tester.tapAt(point(2), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(copied, 'screen');
    expect(sent, isEmpty);
    expect(controller.selection, isNull);
    await tester.tapAt(point(2), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(sent.join(), 'pwd');
    await tester.tapAt(point(2));
    await tester.pumpAndSettle();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 10));
    expect(sent.length, greaterThan(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('screen 滚动后保留可见行的选区锚点', () {
    final terminal = Terminal()..resize(20, 4);
    final controller = TerminalController();
    terminal.write('\x1b[?1049hrow0\r\nrow1\r\nrow2\r\nrow3');
    controller.setSelection(
      terminal.buffer.createAnchor(0, 1),
      terminal.buffer.createAnchor(4, 1),
    );
    expect(terminal.buffer.getText(controller.selection), 'row1');

    terminal.write('\r\nrow4');
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection), 'row1');

    terminal.write('\x1b[1;1H\x1bM');
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection), 'row1');

    terminal.write('\x1b[1;1H\x1b[M');
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection), 'row1');
  });

  testWidgets('Ctrl+A/C 发送到远端，Ctrl+V 多行粘贴需要检查', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'keyboard', host: testHost)
      ..status = ConnectionStatus.connected;
    final output = <String>[];
    session.terminal.onOutput = output.add;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'echo one\necho two'};
        }
        return null;
      },
    );
    addTearDown(() {
      session.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Esc'), findsNothing);
    expect(find.text('Ctrl C'), findsNothing);
    expect(find.text(testHost.name), findsOneWidget);
    expect(find.textContaining(testHost.destination), findsNothing);
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(output, contains('\x01'));
    expect(output, contains('\x03'));
    expect(find.text('粘贴多行内容？'), findsOneWidget);
    expect(output.join(), isNot(contains('echo one')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(output.join(), isNot(contains('echo one')));
    output.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('粘贴多行内容？'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('粘贴多行内容？'), findsNothing);
    expect(output.join(), 'echo one\necho two');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Android 长按拖选复制，空白粘贴及多行确认', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    const menu = MethodChannel('dev.harborssh/terminal_context_menu');
    final requests = <Map<dynamic, dynamic>>[];
    final replies = <Completer<String?>>[];
    String clipboard = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menu, (call) {
      if (call.method == 'show') {
        requests.add(call.arguments as Map);
        final reply = Completer<String?>();
        replies.add(reply);
        return reply.future;
      }
      return Future.value();
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = call.arguments['text'];
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      },
    );
    final session = SshConnection(id: 'android-menu', host: testHost)
      ..status = ConnectionStatus.connected;
    final output = <String>[];
    session.terminal.onOutput = output.add;
    session.terminal.write('hello world');
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menu, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      session.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: harborTheme(), home: Scaffold(
      body: TerminalPane(session: session, onReconnect: () {}),
    )));
    await tester.pumpAndSettle();
    final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    Offset point(int x, int y) => render.localToGlobal(
      render.getOffset(CellOffset(x, y)) + render.cellSize.center(Offset.zero),
    );
    final gesture = await tester.startGesture(point(1, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(point(8, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(requests.last['canCopy'], isTrue);
    final controller = tester.widget<TerminalView>(find.byType(TerminalView)).controller!;
    final selected = session.terminal.buffer.getText(controller.selection);
    expect(selected, contains('hello'));
    expect(selected, contains('world'));
    replies.last.complete('copy');
    await tester.pumpAndSettle();
    expect(clipboard, selected);
    expect(controller.selection, isNull);

    clipboard = 'echo one\necho two';
    session.terminal.write('\x1b[?2004h');
    for (final confirm in [false, true]) {
      await tester.longPressAt(point(30, 2));
      await tester.pump();
      expect(requests.last['canPaste'], isTrue);
      replies.last.complete('paste');
      await tester.pumpAndSettle();
      expect(find.text('粘贴多行内容？'), findsOneWidget);
      await tester.tap(find.text(confirm ? '粘贴' : '取消').last);
      await tester.pumpAndSettle();
      if (!confirm) expect(output, isEmpty);
    }
    expect(output.join(), '\x1b[200~echo one\necho two\x1b[201~');
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Android 断线复制并丢弃切换或销毁后的菜单结果', (tester) async {
    const menu = MethodChannel('dev.harborssh/terminal_context_menu');
    final requests = <Map<dynamic, dynamic>>[];
    final replies = <Completer<String?>>[];
    var clipboard = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menu, (call) {
      if (call.method == 'show') {
        requests.add(call.arguments as Map);
        final reply = Completer<String?>();
        replies.add(reply);
        return reply.future;
      }
      return Future.value();
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = call.arguments['text'];
      if (call.method == 'Clipboard.getData') return {'text': 'unsafe'};
      return null;
    });
    final first = SshConnection(id: 'old', host: testHost)
      ..status = ConnectionStatus.closed;
    final second = SshConnection(id: 'new', host: testHost)..status = ConnectionStatus.connected;
    first.terminal.write('hello world');
    second.terminal.write('second');
    final output = <String>[];
    second.terminal.onOutput = output.add;
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menu, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      first.dispose();
      second.dispose();
    });
    Widget pane(SshConnection session) => MaterialApp(theme: harborTheme(), home: Scaffold(
      body: TerminalPane(session: session, onReconnect: () {}),
    ));
    await tester.pumpWidget(pane(first));
    await tester.pumpAndSettle();
    Offset point() {
      final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
      return render.localToGlobal(render.getOffset(CellOffset(1, 0)) + render.cellSize.center(Offset.zero));
    }
    await tester.longPressAt(point());
    await tester.pump();
    expect(requests.last['canCopy'], isTrue);
    expect(requests.last['canPaste'], isFalse);
    replies.last.complete('copy');
    await tester.pumpAndSettle();
    expect(clipboard, contains('hello'));
    await tester.longPressAt(point());
    await tester.pump();
    final stale = replies.last;
    await tester.pumpWidget(pane(second));
    await tester.pump();
    stale.complete('paste');
    await tester.pump();
    expect(output, isEmpty);
    await tester.longPressAt(point());
    await tester.pump();
    final disposed = replies.last;
    await tester.pumpWidget(const SizedBox.shrink());
    disposed.complete('paste');
    await tester.pump();
    expect(output, isEmpty);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
  testWidgets('桌面长按不调用 Android 系统菜单', (tester) async {
    const menu = MethodChannel('dev.harborssh/terminal_context_menu');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menu, (call) async {
      calls.add(call);
      return null;
    });
    final session = SshConnection(id: 'desktop-menu', host: testHost)
      ..status = ConnectionStatus.connected;
    session.terminal.write('desktop');
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(menu, null);
      session.dispose();
    });
    await tester.pumpWidget(MaterialApp(theme: harborTheme(), home: Scaffold(
      body: TerminalPane(session: session, onReconnect: () {}),
    )));
    await tester.pumpAndSettle();
    final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
    await tester.longPressAt(render.localToGlobal(
      render.getOffset(CellOffset(1, 0)) + render.cellSize.center(Offset.zero),
    ));
    await tester.pump();
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));
}
