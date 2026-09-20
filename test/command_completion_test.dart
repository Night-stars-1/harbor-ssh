import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/remote_commands.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/terminal_completion.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

void main() {
  test('只接受查询结果中的命令名，忽略启动输出、重复项和 shell 控制字符', () {
    expect(
      parseRemoteCommands(
        'banner\n__HARBOR_COMMANDS_BEGIN__\n'
        'git\ndocker-compose\ndocker\ngit\nbad;command\na b\n'
        '\x1b[31mred\n__HARBOR_COMMANDS_END__\nafter\n',
      ),
      ['docker', 'docker-compose', 'git'],
    );
    expect(parseRemoteCommands('docker\ngit\n'), isEmpty);
    expect(parseRemoteCommands('__HARBOR_COMMANDS_BEGIN__\ndocker\n'), isEmpty);
    expect(isCommandNamePrefix('do'), isTrue);
    for (final input in ['docker ps', 'do;echo', r'$(whoami)', './do', '']) {
      expect(isCommandNamePrefix(input), isFalse);
    }
  });

  for (final width in [1200.0, 320.0]) {
    testWidgets('可用命令和历史共同显示、去重，Tab 或点击只填入 $width', (tester) async {
      tester.view.physicalSize = Size(width, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _CommandSession();
      addTearDown(session.dispose);
      final output = <String>[];
      session.terminal.onOutput = (data) {
        output.add(data);
        session.inputGeneration.value++;
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
      session.terminal.write('root@host:~# do');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('docker'), findsOneWidget);
      expect(find.text('docker-compose'), findsOneWidget);
      expect(find.text('docker ps'), findsOneWidget);
      expect(find.text('命令'), findsNWidgets(2));
      expect(find.text('历史'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, ['cker']);
      expect(find.text('docker ps'), findsOneWidget);
      await tester.tap(find.text('docker ps'));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, ['cker', ' ps']);
      expect(find.byType(TerminalCompletionList), findsNothing);
      expect(output.join(), isNot(contains('\r')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('命令结果延迟时历史立即可用，Esc 和新输入使旧查询失效', (tester) async {
    final session = _CommandSession()..pending = Completer<List<String>>();
    addTearDown(session.dispose);
    final completion = TerminalCompletion(session);
    addTearDown(completion.dispose);
    session.terminal.write('root@host:~# do');
    await tester.pump(const Duration(milliseconds: 200));
    expect(completion.entries.map((entry) => entry.label), [
      'docker ps',
      'docker',
    ]);
    completion.dismiss();
    session.pending!.complete(['docker', 'docker-compose']);
    await tester.pump(const Duration(milliseconds: 200));
    expect(completion.entries, isEmpty);
    session.terminal.write('z');
    await tester.pump(const Duration(milliseconds: 200));
    expect(completion.entries, isEmpty);
    session.terminal.write('\r\nroot@host:~# do');
    await tester.pump(const Duration(milliseconds: 200));
    expect(completion.entries.first.label, 'docker');
    session.inputGeneration.value++;
    expect(completion.entries, isEmpty);
    expect(completion.accept(), isFalse);
  });

  testWidgets('禁用 exec 时历史仍可用，命令参数不触发命令名查询', (tester) async {
    final session = _CommandSession()..rejectQuery = true;
    addTearDown(session.dispose);
    final completion = TerminalCompletion(session);
    addTearDown(completion.dispose);
    session.terminal.write('root@host:~# do');
    await tester.pump(const Duration(milliseconds: 200));
    expect(completion.entries.map((entry) => entry.label), [
      'docker ps',
      'docker',
    ]);
    expect(session.queries, 1);
    session.terminal.write('cker ');
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.queries, 1);
    expect(completion.entries.any((entry) => entry.label == 'ps'), isTrue);
    session.terminal.write('\r\nPassword: do');
    await tester.pump(const Duration(milliseconds: 200));
    expect(completion.entries, isEmpty);
    expect(session.queries, 1);
  });
}

class _CommandSession extends SshConnection {
  _CommandSession() : super(id: 'commands', host: testHost) {
    status = ConnectionStatus.connected;
    commandHistory.mergeOlder(['docker', 'docker ps']);
  }
  int queries = 0;
  bool rejectQuery = false;
  Completer<List<String>>? pending;
  @override
  Future<void> loadCommandHistory() async {}
  @override
  Future<List<String>> listAvailableCommands() async {
    queries++;
    if (rejectQuery) throw StateError('exec disabled');
    if (pending != null) return pending!.future;
    return ['docker-compose', 'docker', 'docker', 'git', 'bad;command'];
  }
}
