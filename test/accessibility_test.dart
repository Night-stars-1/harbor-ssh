import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/terminal_theme.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  testWidgets(
    'phone navigation, filters and menus meet Android touch targets',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = memoryRepository();
      await repository.saveHosts([testHost]);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(HarborApp(model: WorkspaceModel(repository)));
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reduced motion leaves cards unscaled while pressed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(reduceMotion: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: ExpressiveHostCard(
                host: testHost,
                onConnect: () {},
                onFavorite: () {},
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(testHost.name)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(ExpressiveHostCard),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(transform.transform.entry(0, 0), 1);
    expect(transform.transform.entry(1, 1), 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    test(
      '$brightness terminal text, ANSI colors and errors remain readable',
      () {
        final colors = harborTheme(brightness: brightness).colorScheme;
        final terminal = harborTerminalTheme(colors);
        for (final color in [
          terminal.foreground,
          terminal.brightBlack,
          terminal.red,
          terminal.green,
          terminal.yellow,
          terminal.blue,
          terminal.magenta,
          terminal.cyan,
          terminal.brightRed,
          terminal.brightGreen,
          terminal.brightYellow,
          terminal.brightBlue,
          terminal.brightMagenta,
          terminal.brightCyan,
          terminal.brightWhite,
        ]) {
          expect(
            contrast(color, terminal.background),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(
          contrast(colors.error, colors.surfaceContainerHigh),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(terminal.cursor, terminal.background),
          greaterThanOrEqualTo(3),
        );
        expect(
          contrast(
            terminal.foreground,
            Color.alphaBlend(terminal.selection, terminal.background),
          ),
          greaterThanOrEqualTo(4.5),
        );
      },
    );
  }

  for (final width in [320.0, 390.0, 800.0, 1280.0]) {
    testWidgets('200% text: hosts, credentials and editor fit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = memoryRepository();
      await repository.saveHosts([testHost]);
      await repository.saveUsers([
        const SshUser(id: 'user', name: '生产部署凭证', username: 'deploy'),
      ]);
      final model = WorkspaceModel(repository);
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(ExpressiveHostCard),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      model.filter(users: true);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(ExpressiveUserCard),
        200,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('生产部署凭证'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存凭证'));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byTooltip('取消'));
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      model.filter();
      await tester.pumpAndSettle();
      final add = width < 900
          ? find.byType(FloatingActionButton)
          : find.text('新建连接');
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存连接'));
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
      expect(find.text('请填写此项'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('navigation exposes selected state and large touch targets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      HarborApp(model: WorkspaceModel(memoryRepository())),
    );
    await tester.pumpAndSettle();
    final nav = find.ancestor(
      of: find.text('所有连接'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(nav).height, greaterThanOrEqualTo(48));
    expect(
      tester.getSemantics(nav).flagsCollection.isSelected,
      ui.Tristate.isTrue,
    );
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(nav).flagsCollection.isSelected,
      ui.Tristate.isFalse,
    );
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('keyboard context menus never connect the host', (tester) async {
    var connections = 0;
    String? action;
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: ExpressiveHostCard(
            host: testHost,
            onConnect: () => connections++,
            onFavorite: () {},
            onAction: (value) => action = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('编辑连接'), findsOneWidget);
    expect(connections, 0);
    await tester.tap(find.text('编辑连接'));
    await tester.pumpAndSettle();
    expect(action, 'edit');
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('删除连接'), findsOneWidget);
    expect(connections, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal keys retain 48dp targets at 200% text and send input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = SshConnection(id: 'a11y', host: testHost)
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
    final esc = find.widgetWithText(FilledButton, 'Esc');
    expect(tester.getSize(esc).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(esc).width, greaterThanOrEqualTo(48));
    await tester.tap(esc);
    expect(output, contains('\x1b'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
