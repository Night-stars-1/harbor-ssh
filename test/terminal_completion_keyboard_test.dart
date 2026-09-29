import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/path_completion.dart';
import 'package:harbor_ssh/ui/terminal_completion.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final command in ['git', 'docker ', 'cd ']) {
      testWidgets('补全弹出后上下键和长按仍发送给终端 $platform $command', (tester) async {
        tester.view.physicalSize = const Size(1200, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = _CompletionSession();
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

        for (final key in [
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        ]) {
          // A shell response changes the input; the next command can open
          // suggestions again, but its ordinary arrows must still reach SSH.
          session.terminal.write('\r\x1b[2Kroot@host:~# ');
          await tester.pumpAndSettle(const Duration(milliseconds: 200));
          session.terminal.write(command);
          await tester.pumpAndSettle(const Duration(milliseconds: 200));
          expect(find.byType(TerminalCompletionList), findsOneWidget);
          output.clear();

          await tester.sendKeyDownEvent(key);
          await tester.sendKeyRepeatEvent(key);
          await tester.sendKeyUpEvent(key);
          await tester.pumpAndSettle(const Duration(milliseconds: 200));

          final sequence = key == LogicalKeyboardKey.arrowUp
              ? '\x1b[A'
              : '\x1b[B';
          expect(output, [sequence, sequence]);
          expect(find.byType(TerminalCompletionList), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('应用光标模式下上下键仍使用终端自己的编码', (tester) async {
    final session = _CompletionSession();
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
    session.terminal.write('\x1b[?1hroot@host:~# ');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    final withoutPopup = List.of(output);
    expect(withoutPopup, hasLength(2));
    output.clear();
    session.terminal.write('docker ');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.byType(TerminalCompletionList), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(output, withoutPopup);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Alt/Option 上下只切换候选，松开后 Tab 补全',
    (tester) async {
      final session = _CompletionSession();
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
      final completion = tester
          .widget<TerminalCompletionList>(popup)
          .completion;
      expect(completion.selected, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(popup, findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      expect(completion.selected, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(completion.selected, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(output, isEmpty);
      final suffix = completion.entries[completion.selected].suffix;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(output, [suffix]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );
}

class _CompletionSession extends SshConnection {
  _CompletionSession() : super(id: 'completion-keys', host: testHost) {
    status = ConnectionStatus.connected;
    commandHistory.mergeOlder(['git log', 'git status']);
  }

  @override
  Future<void> loadCommandHistory() async {}

  @override
  Future<List<String>> listAvailableCommands() async => [];

  @override
  Future<List<RemotePathEntry>> listDirectory(String path) async => const [
    RemotePathEntry('docs', isDirectory: true),
    RemotePathEntry('src', isDirectory: true),
  ];
}
