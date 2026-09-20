import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/terminal_workspace.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  testWidgets('六个分屏保持最小宽度，可滚动定位并关闭空面板', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sessions = [for (var i = 0; i < 6; i++) _Session('many-$i')];
    for (final session in sessions) {
      addTearDown(session.dispose);
    }
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, sessions: sessions));
    await tester.pumpAndSettle();
    Future<void> action(int side, String name) async {
      final menu = find.byKey(ValueKey('terminal-split-menu-$side'));
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    for (var side = 0; side < 5; side++) {
      await action(side, '左右分屏');
    }
    expect(find.byType(TerminalView), findsNWidgets(6));
    for (var side = 0; side < 6; side++) {
      expect(
        tester.getSize(find.byKey(ValueKey('terminal-region-$side'))).width,
        greaterThanOrEqualTo(240),
      );
    }
    expect(
      find.byKey(const ValueKey('terminal-split-menu-5')).hitTestable(),
      findsOneWidget,
    );
    await action(5, '上下分屏');
    expect(find.text('选择会话'), findsOneWidget);
    await action(6, '关闭此分屏');
    expect(find.text('选择会话'), findsNothing);
    expect(find.byType(TerminalView), findsNWidgets(6));
    await action(0, '取消分屏');
    expect(find.byType(TerminalView), findsOneWidget);
    expect(key.currentState!.sessions, hasLength(6));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('多终端嵌套分屏独立调整，关闭面板保留连接与终端状态', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sessions = [for (var i = 0; i < 4; i++) _Session('session-$i')];
    for (final session in sessions) {
      addTearDown(session.dispose);
    }
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, sessions: sessions));
    await tester.pumpAndSettle();
    Finder terminal(int index) => find.byWidgetPredicate(
      (widget) =>
          widget is TerminalView && widget.terminal == sessions[index].terminal,
    );
    Finder region(int side) => find.byKey(ValueKey('terminal-region-$side'));
    final firstState = tester.state(terminal(0));
    Future<void> action(int side, String name) async {
      await tester.tap(find.byKey(ValueKey('terminal-split-menu-$side')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    await action(0, '左右分屏');
    final secondState = tester.state(terminal(1));
    await action(1, '上下分屏');
    expect(find.byType(TerminalView), findsNWidgets(3));
    expect(
      tester.getRect(region(0)).right,
      lessThan(tester.getRect(region(1)).left),
    );
    expect(
      tester.getRect(region(1)).bottom,
      lessThan(tester.getRect(region(2)).top),
    );
    await action(0, '上下分屏');
    expect(find.byType(TerminalView), findsNWidgets(4));
    expect(
      tester.getRect(region(0)).bottom,
      lessThan(tester.getRect(region(3)).top),
    );
    expect(tester.state(terminal(0)), same(firstState));
    expect(tester.state(terminal(1)), same(secondState));
    expect(
      find.byKey(const ValueKey('terminal-session-picker-0')),
      findsNothing,
    );
    final rightBefore = tester.getRect(region(1));
    final leftBefore = tester.getRect(region(0));
    await tester.drag(
      find.byKey(const ValueKey('terminal-split-handle-2')),
      const Offset(0, 60),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(region(0)).height, greaterThan(leftBefore.height));
    expect(tester.getRect(region(1)), rightBefore);
    await tester.drag(
      find.byKey(const ValueKey('terminal-split-handle-0')),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(region(0)).width, greaterThan(leftBefore.width));
    await tester.tap(terminal(2));
    await tester.pumpAndSettle();
    tester.testTextInput.enterText('  only-third');
    await tester.pump();
    expect(sessions[2].input.join(), 'only-third');
    for (final i in [0, 1, 3]) {
      expect(sessions[i].input, isEmpty);
    }
    final thirdState = tester.state(terminal(2));
    tester.view.physicalSize = const Size(390, 700);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.state(terminal(2)), same(thirdState));
    tester.testTextInput.enterText('  mobile');
    await tester.pump();
    expect(sessions[2].input.join(), 'only-thirdmobile');
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsNWidgets(4));
    expect(tester.state(terminal(0)), same(firstState));
    expect(tester.state(terminal(1)), same(secondState));
    expect(tester.state(terminal(2)), same(thirdState));
    sessions[3].status = ConnectionStatus.failed;
    sessions[3].error = 'Connection failed. ' * 40;
    key.currentState!.refresh();
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('terminal-split-handle-2')),
      const Offset(0, 2000),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await action(3, '关闭此分屏');
    expect(find.byType(TerminalView), findsNWidgets(3));
    expect(
      tester.getRect(region(0)).height,
      greaterThan(tester.getRect(region(1)).height),
    );
    expect(tester.state(terminal(0)), same(firstState));
    expect(key.currentState!.sessions, hasLength(4));
    key.currentState!.remove(sessions[1]);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsNWidgets(2));
    expect(tester.state(terminal(2)), same(thirdState));
    await action(2, '取消分屏');
    expect(find.byType(TerminalView), findsOneWidget);
    expect(tester.state(terminal(2)), same(thirdState));
    expect(sessions[0].status, ConnectionStatus.connected);
    expect(sessions[2].status, ConnectionStatus.connected);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('单会话分屏可新建连接，外部选择切换目标区域，窗口缩小再放大恢复分屏', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = _Session('first');
    addTearDown(first.dispose);
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, sessions: [first]));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-split-menu-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左右分屏'));
    await tester.pumpAndSettle();
    expect(find.text('选择会话'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-session-picker-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建 · ${testHost.name}'));
    await tester.pumpAndSettle();
    final second = key.currentState!.active;
    addTearDown(second.dispose);
    expect(second, isNot(first));
    expect(find.byType(TerminalView), findsNWidgets(2));
    final third = _Session('third');
    addTearDown(third.dispose);
    key.currentState!.add(third);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TerminalView && widget.terminal == third.terminal,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TerminalView && widget.terminal == first.terminal,
      ),
      findsOneWidget,
    );
    tester.view.physicalSize = const Size(390, 700);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-split-handle-0')), findsNothing);
    expect(find.byKey(const ValueKey('terminal-split-menu-0')), findsNothing);
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsNWidgets(2));
    key.currentState!.remove(third);
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-split-handle-0')), findsNothing);
    expect(first.status, ConnectionStatus.connected);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Session extends SshConnection {
  _Session(String id) : super(id: id, host: testHost) {
    status = ConnectionStatus.connected;
    terminal.write('$id output\r\n');
    terminal.onOutput = input.add;
  }
  final input = <String>[];
}

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.sessions});
  final List<_Session> sessions;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final sessions = [...widget.sessions];
  late _Session active = sessions.first;
  final controller = TerminalPaneController();
  void refresh() => setState(() {});
  void add(_Session session) => setState(() {
    sessions.add(session);
    active = session;
  });
  void remove(SshConnection session) => setState(() {
    sessions.remove(session);
    active = sessions.first;
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: harborTheme(),
    home: Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => TerminalWorkspace(
          sessions: sessions,
          activeSession: active,
          hosts: [testHost],
          desktop: constraints.maxWidth >= 900,
          visible: true,
          mobileController: controller,
          onSelect: (id) =>
              setState(() => active = sessions.firstWhere((s) => s.id == id)),
          onConnect: (Host host) async => add(_Session('created')),
          onClose: remove,
          onFiles: (_) {},
        ),
      ),
    ),
  );
}
