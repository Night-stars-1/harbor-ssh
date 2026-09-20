import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/command_history.dart';
import 'package:harbor_ssh/domain/path_completion.dart';
import 'package:harbor_ssh/ui/terminal_completion.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  test('Bash 和 Zsh 历史去掉时间戳、多行和控制字符', () {
    expect(parseCommandHistory('git status\ngit log\n secret\nbad\x1b[31m\n'), [
      'git status',
      'git log',
    ]);
    expect(
      parseCommandHistory(
        '#1700000000\ngit status\n#1700000001\necho one\necho two\n#1700000002\ngit log\n',
      ),
      ['git status', 'git log'],
    );
    expect(
      parseCommandHistory(
        ': 1700000000:0;docker ps\n: 1700000001:0;echo a\\\nb\n: 1700000002:3;docker logs app\n',
        zsh: true,
      ),
      ['docker ps', 'docker logs app'],
    );
    expect(parseCommandHistory('echo a\\\nb\ngit status\n'), ['git status']);
  });

  test('合并历史去重、最近优先、会话隔离和数量限制', () {
    final history = CommandHistory(Terminal());
    addTearDown(history.dispose);
    history.add('git status');
    history.mergeOlder(['git status', 'git log', 'git diff']);
    expect(history.matching('git'), ['git status', 'git diff', 'git log']);
    expect(history.matching('git status'), isEmpty);
    expect(history.matching(''), isEmpty);
    final other = CommandHistory(Terminal());
    addTearDown(other.dispose);
    expect(other.matching('git'), isEmpty);
    for (var i = 0; i < 600; i++) {
      history.add('echo $i');
    }
    expect(history.matching('git'), isEmpty);
    expect(history.matching('echo'), hasLength(100));
    expect(history.matching('echo').first, 'echo 599');
  });

  test('等待完整远端回显后记录命令，支持软换行并忽略密码和取消输入', () {
    final terminal = Terminal()..resize(24, 12);
    final history = CommandHistory(terminal);
    addTearDown(history.dispose);
    terminal.write('root@host:~# git st');
    history.observeInput('\r');
    expect(history.matching('git'), isEmpty);
    terminal.write('atus --short');
    expect(history.matching('git'), isEmpty);
    terminal.write('\r\nroot@host:~# ');
    expect(history.matching('git'), ['git status --short']);
    terminal.write('git diff');
    history.observeInput('\r');
    history.observeInput('\x03');
    terminal.write('^C\r\nPassword: ');
    history.observeInput('\r');
    terminal.write('\r\n');
    expect(history.matching('git'), ['git status --short']);
    terminal.write('\x1b[?1049hroot@host:~# git log');
    history.observeInput('\r');
    terminal.write('\r\n\x1b[?1049l');
    expect(history.matching('git'), ['git status --short']);
  });

  for (final width in [1200.0, 320.0]) {
    testWidgets('历史悬浮窗支持筛选、方向键、Tab 和点击，路径优先 $width', (tester) async {
      tester.view.physicalSize = Size(width, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _HistorySession();
      addTearDown(session.dispose);
      final output = <String>[];
      session.terminal.onOutput = (data) {
        session.commandHistory.observeInput(data);
        session.inputGeneration.value++;
        output.add(data);
        session.terminal.write(data);
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: TerminalPane(session: session, onReconnect: () {}),
          ),
        ),
      );
      session.terminal.write('root@host:~# git');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('git status'), findsOneWidget);
      expect(find.text('git log'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsNWidgets(2));
      tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('git status'), findsOneWidget);
      expect(session.status, ConnectionStatus.connected);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, [' log']);
      expect(find.byType(TerminalCompletionList), findsNothing);
      session.terminal.write('\r\nroot@host:~# git st');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('git log'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('status'),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, [' log', 'atus ']);
      expect(output.join(), isNot(contains('\r')));
      session.terminal.write('\r\nroot@host:~# cd ');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('docs/'), findsOneWidget);
      expect(find.text('cd old-directory'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('历史迟到不覆盖新输入，Esc 收起，Enter 仍执行已输入的命令', (tester) async {
    final session = _HistorySession()..pending = Completer<void>();
    addTearDown(session.dispose);
    final output = <String>[];
    session.terminal.onOutput = output.add;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    session.terminal.write('root@host:~# git');
    await tester.pump(const Duration(milliseconds: 200));
    session.terminal.write('x');
    session.pending!.complete();
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byType(TerminalCompletionList), findsNothing);
    session.terminal.write('\r\nroot@host:~# git');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byType(TerminalCompletionList), findsNothing);
    session.terminal.write(' ');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    final popup = tester.widget<TerminalCompletionList>(
      find.byType(TerminalCompletionList),
    );
    expect(
      popup.completion.entries.any((entry) => entry.label == 'status'),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(output, ['\r']);
    expect(find.byType(TerminalCompletionList), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _HistorySession extends SshConnection {
  _HistorySession() : super(id: 'history', host: testHost) {
    status = ConnectionStatus.connected;
    commandHistory.mergeOlder(['git log', 'git status', 'cd old-directory']);
  }
  Completer<void>? pending;
  @override
  Future<void> loadCommandHistory() async {
    if (pending != null) await pending!.future;
  }

  @override
  Future<List<RemotePathEntry>> listDirectory(String path) async => const [
    RemotePathEntry('docs', isDirectory: true),
  ];
}
