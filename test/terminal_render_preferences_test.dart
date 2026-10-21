import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  testWidgets('悬停与输出后字号和主题不变，切换后立即生效', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'render-preferences', host: testHost)
      ..status = ConnectionStatus.connected;
    addTearDown(session.dispose);

    Widget app({required double fontSize, required Brightness brightness}) =>
        MaterialApp(
          theme: harborTheme(brightness: brightness),
          home: Scaffold(
            body: TerminalPane(
              session: session,
              onReconnect: () {},
              fontSize: fontSize,
            ),
          ),
        );

    await tester.pumpWidget(app(fontSize: 14, brightness: Brightness.light));
    session.terminal.write('ready\r\n');
    await tester.pumpAndSettle();
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final initialCellSize = state.renderTerminal.cellSize;
    final initialBackground = state.widget.theme.background;
    expect(initialBackground, harborTheme().colorScheme.surfaceContainerLowest);

    final mouse = TestGesture(
      dispatcher: tester.sendEventToBinding,
      kind: PointerDeviceKind.mouse,
      device: 9,
    );
    await mouse.addPointer(
      location: state.renderTerminal.localToGlobal(const Offset(24, 24)),
    );
    await mouse.moveTo(
      state.renderTerminal.localToGlobal(const Offset(48, 40)),
    );
    session.terminal.write('more output\r\n');
    await tester.pumpAndSettle();
    expect(state.renderTerminal.cellSize, initialCellSize);
    expect(state.widget.theme.background, initialBackground);

    await tester.pumpWidget(app(fontSize: 18, brightness: Brightness.light));
    await tester.pumpAndSettle();
    expect(
      state.renderTerminal.cellSize.height,
      greaterThan(initialCellSize.height),
    );
    expect(state.widget.textStyle.fontSize, 18);

    await tester.pumpWidget(app(fontSize: 18, brightness: Brightness.dark));
    await tester.pumpAndSettle();
    expect(
      state.widget.theme.background,
      harborTheme(brightness: Brightness.dark)
          .colorScheme
          .surfaceContainerLowest,
    );
    expect(state.widget.theme.background, isNot(initialBackground));

    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
