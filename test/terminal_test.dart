import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
