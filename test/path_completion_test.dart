import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/path_completion.dart';
import 'package:harbor_ssh/ui/terminal_completion.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  PathCompletionRequest? parse(String text, {int width = 100}) {
    final terminal = Terminal()
      ..resize(width, 20)
      ..write(text);
    return readPathCompletion(terminal);
  }

  test('cd 从当前提示符解析目录，支持相对路径、换行、引号和转义空格', () {
    expect(parse('root@host:~# cd ', width: 16)!.prefix, '');
    final empty = parse('root@host:~# cd ')!;
    expect(empty.directory, '~');
    expect(empty.directoriesOnly, isTrue);
    expect(empty.prefix, '');
    final nested = parse(
      'root@host:/srv/project# cd ../my\\ dir/do',
      width: 24,
    )!;
    expect(nested.directory, '/srv/project/../my dir/');
    expect(nested.prefix, 'do');
    expect(parse('root@host:/srv# cd /var/lo')!.directory, '/var/');
    expect(parse('root@host:/srv# cd ~/Do')!.directory, '~/');
    expect(parse('root@host:/srv# cd "my dir/fo')!.quote, '"');
    expect(parse('root@host:/srv# cat re')!.directoriesOnly, isFalse);
    expect(parse('root@host:/srv# ls /tmp/fi')!.directory, '/tmp/');
  });

  test('补全只插入经过转义的剩余文本，不执行命令', () {
    const entry = RemotePathEntry('my dir;\$(touch x)', isDirectory: true);
    expect(
      parse('root@host:~# cd my')!.suffix(entry),
      r'\ dir\;\$\(touch\ x\)/',
    );
    expect(parse('root@host:~# cd "my')!.suffix(entry), r' dir;\$(touch x)/');
    expect(
      parse('root@host:~# cd ')!
          .suffix(const RemotePathEntry('文档😀', isDirectory: true)),
      r'\文\档\😀/',
    );
    expect(
      parse("root@host:~# cd 'a")!
          .suffix(const RemotePathEntry("a'b", isDirectory: true)),
      "'\\''b/",
    );
  });

  test('不在普通输出、未知目录、复合命令或光标中间猜测候选', () {
    for (final text in [
      'some output cd ',
      r'$ cd ',
      'root@host:~# cd a;ls ',
      'root@host:~# cd \$(pwd)/',
      'root@host:~# cd -',
      'root@host:~# cd a b',
      'root@host:~# cd ab\x1b[D',
    ]) {
      expect(parse(text), isNull, reason: text);
    }
    final terminal = Terminal()..write('\x1b[?1049hroot@host:~# cd ');
    expect(readPathCompletion(terminal), isNull);
  });

  for (final size in [const Size(1200, 700), const Size(320, 500)]) {
    testWidgets('自动列出目录、筛选并用 Tab 或点击补全 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _PathSession();
      final output = <String>[];
      session.terminal.onOutput = (text) {
        output.add(text);
        session.terminal.write(text);
      };
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: TerminalPane(session: session, onReconnect: () {}),
          ),
        ),
      );
      session.terminal.write('root@host:~# cd ');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('docs/'), findsOneWidget);
      expect(find.text('my dir/'), findsOneWidget);
      expect(find.text('readme.txt'), findsNothing);
      expect(find.text('.ssh/'), findsNothing);
      expect(session.directories, ['~']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, [r'my\ dir/']);
      expect(output.join(), isNot(contains('\r')));
      expect(session.directories.last, '~/my dir/');
      expect(find.text('child/'), findsOneWidget);
      await tester.tap(find.text('child/'));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output.last, 'child/');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Esc 收起，不使用迟到的目录结果，Enter 仍发送到终端', (tester) async {
    final session = _PathSession();
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
    session.terminal.write('root@host:~# cd ');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(TerminalCompletionList), findsNothing);
    expect(output, isEmpty);
    session.terminal.write('d');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('docs/'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(output, ['\r']);
    expect(find.byType(TerminalCompletionList), findsNothing);
    final pending = Completer<List<RemotePathEntry>>();
    session.pending = pending;
    session.terminal.write('\r\nroot@host:/new# cd ');
    await tester.pump(const Duration(milliseconds: 200));
    session.terminal.write('\r\nroot@host:/new# echo done\r\n');
    pending.complete([const RemotePathEntry('late', isDirectory: true)]);
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('late/'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _PathSession extends SshConnection {
  _PathSession() : super(id: 'completion', host: testHost) {
    status = ConnectionStatus.connected;
  }
  final directories = <String>[];
  Completer<List<RemotePathEntry>>? pending;
  @override
  Future<List<RemotePathEntry>> listDirectory(String path) async {
    directories.add(path);
    if (pending != null) return pending!.future;
    if (path.endsWith('/my dir/')) {
      return [const RemotePathEntry('child', isDirectory: true)];
    }
    if (path != '~') return [];
    return const [
      RemotePathEntry('docs', isDirectory: true),
      RemotePathEntry('my dir', isDirectory: true),
      RemotePathEntry('readme.txt', isDirectory: false),
      RemotePathEntry('.ssh', isDirectory: true),
    ];
  }
}
