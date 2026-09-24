import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/command_specs.dart';
import 'package:harbor_ssh/ui/terminal_completion.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

void main() {
  List<String> names(String input) =>
      completeCommandContext(input).map((entry) => entry.spec.name).toList();

  test('逐级子命令、选项、短选项和 sudo 前缀', () {
    expect(
      names('docker '),
      containsAll(['attach', 'stats', 'unpause', 'compose']),
    );
    final attach = completeCommandContext('docker att').single;
    expect(attach.spec.name, 'attach');
    expect(attach.suffix, 'ach ');
    expect(attach.completed, 'docker attach');
    expect(attach.usage, 'docker attach [选项] <容器>');
    expect(attach.spec.description, isNotEmpty);
    expect(names('docker compose u'), ['up']);
    expect(names('docker container att'), ['attach']);
    expect(names('docker-compose u'), ['up']);
    expect(names('sudo docker att'), ['attach']);
    expect(
      names('docker attach --'),
      containsAll(['--detach-keys', '--no-stdin']),
    );
    expect(names('docker run -i'), isEmpty);
    expect(
      completeCommandContext('docker run --inter').single.suffix,
      'active ',
    );
  });

  test('选项值不作为子命令，不在 shell 表达式或程序参数内猜测', () {
    expect(names('docker --context remote comp'), ['compose']);
    expect(names('docker compose -f "my compose.yml" u'), ['up']);
    expect(names('git -C "/my project" st'), ['status']);
    expect(names('git status --'), contains('--short'));
    expect(names('docker compose up --detach --'), isNot(contains('--detach')));
    for (final input in [
      'docker --context ',
      'docker compose -f ',
      'docker run --name ap',
      'docker run alpine ec',
      'docker exec app sh --',
      'git checkout mybr',
      'docker run -- ',
      'docker unknown ',
      'echo docker ',
      'docker; echo ',
      r'docker $(whoami) ',
      'docker "att',
      'docker | docker ',
      'sudo -u root docker ',
    ]) {
      expect(names(input), isEmpty, reason: input);
    }
  });

  for (final size in [const Size(1200, 700), const Size(320, 650)]) {
    testWidgets('子命令说明布局、键盘补全、Esc、热更新 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _SpecSession();
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
      session.terminal.write('root@host:~# docker ');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      final details = find.byKey(const ValueKey('completion-details'));
      expect(details, findsOneWidget);
      expect(
        find.descendant(of: details, matching: find.text('attach')),
        findsOneWidget,
      );
      final list = find.byType(ListView).last;
      expect(tester.getSize(list).width, lessThanOrEqualTo(320));
      if (size.width >= 660) {
        expect(
          tester.getTopLeft(details).dx,
          greaterThan(tester.getTopRight(list).dx),
        );
        expect(tester.getSize(find.byType(TerminalCompletionList)).width, 568);
      } else {
        expect(
          tester.getTopLeft(details).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(list).dy),
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: details, matching: find.text('create')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TerminalCompletionList), findsNothing);
      session.terminal.write('att');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, ['ach ']);
      expect(find.text('--no-stdin'), findsOneWidget);
      await tester.tap(find.text('--no-stdin'));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(output, ['ach ', '--no-stdin ']);
      expect(output.join(), isNot(contains('\r')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final size in [const Size(1200, 700), const Size(320, 650)]) {
    testWidgets('点击命令面板外收起，当前输入不反复弹出 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _SpecSession();
      addTearDown(session.dispose);
      final output = <String>[];
      session.terminal.onOutput = output.add;
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: TerminalPane(session: session, onReconnect: () {}),
          ),
        ),
      );
      session.terminal.write('root@host:~# docker ');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      final popup = find.byType(TerminalCompletionList);
      expect(popup, findsOneWidget);
      final outside = Offset(size.width - 12, size.height - 110);
      expect(tester.getRect(popup).contains(outside), isFalse);
      await tester.tapAt(outside);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(popup, findsNothing);
      expect(output, isEmpty);

      session.terminal.write('\x1b[0m');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(popup, findsNothing);
      session.terminal.write('att');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(popup, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('快速滚轮与悬停不跳底，方向键只滚动到候选可见', (tester) async {
    final session = _SpecSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    session.terminal.write('root@host:~# docker ');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    final list = find.byType(ListView).last;
    final controller = tester.widget<ListView>(list).controller!;
    final completion = tester
        .widget<TerminalCompletionList>(find.byType(TerminalCompletionList))
        .completion;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final position = tester.getBottomLeft(list) + const Offset(60, -3);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(position);
    await tester.pumpAndSettle();
    var expectedOffset = 0.0;
    for (final delta in [73.0, 180.0, 90.0, -65.0, -120.0]) {
      expectedOffset += delta;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: position,
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(expectedOffset, 0.01));
      // Moving over a partly clipped bottom row updates its description only.
      await mouse.moveTo(position + const Offset(1, 0));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(expectedOffset, 0.01));
      await mouse.moveTo(position);
      await tester.pumpAndSettle();
    }
    completion.select(0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(completion.selected, completion.entries.length - 1);
    expect(controller.offset, controller.position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(completion.selected, 0);
    expect(controller.offset, 0);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(completion.selected, 5);
    expect(controller.offset, 48);
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鼠标选择同步说明、Enter 只执行已输入文本', (tester) async {
    final session = _SpecSession();
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
    session.terminal.write('root@host:~# docker ');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('exec')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('completion-details')),
        matching: find.text('exec'),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(output, ['\r']);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _SpecSession extends SshConnection {
  _SpecSession() : super(id: 'specs', host: testHost) {
    status = ConnectionStatus.connected;
  }
  @override
  Future<void> loadCommandHistory() async {}
  @override
  Future<List<String>> listAvailableCommands() async => [];
}
