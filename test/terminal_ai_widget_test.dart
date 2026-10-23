import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/ai_settings.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/ai_window_bridge.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('厂商预设与接口选择保存，切换厂商不混用密钥 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      final controller = LocalSyncSettingsController(model);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(body: AiSettingsPage(controller: controller)),
        ),
      );
      expect(find.textContaining('执行记录与命令输出会发送'), findsNothing);
      Future<void> select(String field, String option) async {
        final menu = find.byKey(ValueKey('ai-setting-$field'));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(MenuItemButton, option).hitTestable(),
        );
        await tester.pumpAndSettle();
      }

      String value(String field) => field == 'model'
          ? tester
                .widget<DropdownMenu<String>>(
                  find.byKey(const ValueKey('ai-setting-model')),
                )
                .controller!
                .text
          : tester
                .widget<TextField>(find.byKey(ValueKey('ai-setting-$field')))
                .controller!
                .text;
      await select('provider', 'Anthropic');
      expect(value('url'), 'https://api.anthropic.com/v1');
      expect(
        tester
            .widget<DropdownMenu<AiProtocol>>(
              find.byKey(const ValueKey('ai-setting-protocol')),
            )
            .initialSelection,
        AiProtocol.anthropic,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('ai-setting-key')));
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-key')),
        'anthropic-key',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('ai-setting-model')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-model')),
        'claude-test',
      );
      await select('provider', 'OpenAI');
      expect(value('url'), 'https://api.openai.com/v1');
      expect(value('key'), isEmpty);
      expect(value('model'), isEmpty);
      await select('provider', 'Anthropic');
      expect(value('key'), 'anthropic-key');
      expect(value('model'), 'claude-test');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(model.aiSettings.protocol, AiProtocol.anthropic);
      expect(model.aiSettings.provider, 'anthropic');
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: AiSettingsPage(key: UniqueKey(), controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(value('url'), 'https://api.anthropic.com/v1');
      expect(value('key'), 'anthropic-key');
      await select('protocol', 'OpenAI 兼容');
      await select('provider', '自定义');
      // Custom keeps the current endpoint and protocol for proxies.
      expect(value('url'), 'https://api.anthropic.com/v1');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(model.aiSettings.provider, 'custom');
      expect(model.aiSettings.protocol, AiProtocol.openai);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      model.dispose();
    });
  }

  testWidgets('默认模型与审批模型可选用其他服务商', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(body: AiSettingsPage(controller: controller)),
      ),
    );
    Future<void> select(String field, String option) async {
      final menu = find.byKey(ValueKey('ai-setting-$field'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, option).hitTestable(),
      );
      await tester.pumpAndSettle();
    }

    Future<void> fill(String field, String text) async {
      final finder = find.byKey(ValueKey('ai-setting-$field'));
      await tester.ensureVisible(finder);
      await tester.enterText(finder, text);
    }

    await select('provider', 'Anthropic');
    await fill('key', 'anthropic-key');
    await fill('model', 'claude-test');
    await select('provider', 'OpenAI');
    await fill('key', 'openai-key');
    await fill('model', 'gpt-test');
    await select('approval-provider', 'Anthropic');
    await fill('approval-model', 'claude-test');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(model.aiSettings.provider, 'openai');
    expect(model.aiSettings.model, 'gpt-test');
    expect(model.aiSettings.apiKey, 'openai-key');
    expect(model.aiSettings.approvalProvider, 'anthropic');
    expect(model.aiSettings.approvalModel, 'claude-test');
    expect(
      model.aiSettings.profiles.map((profile) => profile.id),
      containsAll(['openai', 'anthropic']),
    );
    expect(model.aiSettings.approvalSettings!.apiKey, 'anthropic-key');
    expect(model.aiSettings.approvalSettings!.protocol, AiProtocol.anthropic);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AiSettingsPage(key: UniqueKey(), controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownMenu<String>>(
            find.byKey(const ValueKey('ai-setting-model')),
          )
          .controller!
          .text,
      'gpt-test',
    );
    expect(
      tester
          .widget<DropdownMenu<String>>(
            find.byKey(const ValueKey('ai-setting-approval-model')),
          )
          .controller!
          .text,
      'claude-test',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  testWidgets('审批模型可以清除', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(body: AiSettingsPage(controller: controller)),
      ),
    );
    Future<void> select(String field, String option) async {
      final menu = find.byKey(ValueKey('ai-setting-$field'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, option).hitTestable(),
      );
      await tester.pumpAndSettle();
    }

    await select('provider', 'OpenAI');
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-key')),
      'openai-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-model')),
      'gpt-test',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-approval-model')),
      'claude-test',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-approval-model')),
      '',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownMenu<String>>(
            find.byKey(const ValueKey('ai-setting-approval-model')),
          )
          .controller!
          .text,
      isEmpty,
    );
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(model.aiSettings.approvalModel, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  testWidgets('审批模式默认选择：三种模式可切换、保存并在重新打开时恢复', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(body: AiSettingsPage(controller: controller)),
      ),
    );

    Future<void> select(String field, String option) async {
      final menu = find.byKey(ValueKey('ai-setting-$field'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, option).hitTestable(),
      );
      await tester.pumpAndSettle();
    }

    Finder shown(String label) => find.descendant(
      of: find.byKey(const ValueKey('ai-setting-approval-mode')),
      matching: find.text(label),
    );

    expect(find.text('默认审批模式'), findsOneWidget);
    expect(shown('手动审批'), findsOneWidget);

    await select('approval-mode', '自动审批');
    expect(shown('自动审批'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-url')),
      'https://api.openai.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-model')),
      'gpt-4o',
    );
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(model.aiSettings.defaultApprovalMode, AiApprovalMode.auto);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AiSettingsPage(key: UniqueKey(), controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(shown('自动审批'), findsOneWidget);

    await select('approval-mode', '只读模式');
    expect(shown('只读模式'), findsOneWidget);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(model.aiSettings.defaultApprovalMode, AiApprovalMode.readOnly);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  testWidgets('新建的自定义服务商可以删除', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(body: AiSettingsPage(controller: controller)),
      ),
    );
    Future<void> openProviderMenu() async {
      await tester.tap(find.byKey(const ValueKey('ai-provider-more')));
      await tester.pumpAndSettle();
    }

    await openProviderMenu();
    expect(
      tester
          .widget<MenuItemButton>(
            find.byKey(const ValueKey('ai-delete-provider')),
          )
          .onPressed,
      isNull,
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建服务商'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '我的代理',
    );
    await tester.tap(find.widgetWithText(FilledButton, '新建'));
    await tester.pumpAndSettle();
    await openProviderMenu();
    expect(
      tester
          .widget<MenuItemButton>(
            find.byKey(const ValueKey('ai-delete-provider')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text('我的代理'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('ai-delete-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    await openProviderMenu();
    expect(
      tester
          .widget<MenuItemButton>(
            find.byKey(const ValueKey('ai-delete-provider')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('我的代理'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  testWidgets('服务商名称可以重命名', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(body: AiSettingsPage(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('新建服务商'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '我的代理',
    );
    await tester.tap(find.widgetWithText(FilledButton, '新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-provider-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-rename-provider')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '公司网关',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '保存'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('公司网关'), findsWidgets);
    expect(find.text('我的代理'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('终端 AI 入口绑定当前会话 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SshConnection(id: 'ai-entry', host: testHost)
        ..status = ConnectionStatus.connected;
      session.terminal.write('tester@server:~\$ ');
      final model = _SessionModel(session);
      await model.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Workspace(model: model, onToggleTheme: () {}),
        ),
      );
      await tester.pumpAndSettle();
      final terminalState = tester.state(find.byType(TerminalView));
      final barriers = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(
        find.byKey(
          ValueKey(width < 900 ? 'terminal-ai-mobile' : 'terminal-ai'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TerminalAiPanel), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(ModalBarrier).evaluate().length, barriers);
      expect(
        find.descendant(
          of: find.byType(TerminalPane),
          matching: find.byType(TerminalAiPanel),
        ),
        findsOneWidget,
      );
      final mountedTerminal = find.byType(TerminalView, skipOffstage: false);
      expect(tester.state(mountedTerminal), same(terminalState));
      final terminalRect = tester.getRect(mountedTerminal);
      final aiRect = tester.getRect(find.byType(TerminalAiPanel));
      if (width < 900) {
        expect(find.byType(TerminalView), findsNothing);
        expect(aiRect, tester.getRect(find.byType(TerminalPane)));
        expect(
          tester.widget<TerminalView>(mountedTerminal).focusNode!.hasFocus,
          isFalse,
        );
      } else {
        expect(aiRect.left, greaterThanOrEqualTo(terminalRect.right));
        final terminal = tester.widget<TerminalView>(mountedTerminal);
        await tester.tap(find.byType(TerminalView));
        await tester.pump(const Duration(milliseconds: 350));
        expect(terminal.focusNode!.hasFocus, isTrue);
      }
      expect(find.text('先在设置 → AI 配置模型服务'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(TerminalAiPanel),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TerminalAiPanel), findsNothing);
      expect(tester.state(find.byType(TerminalView)), same(terminalState));
      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(session.status, ConnectionStatus.connected);
      expect(session.terminal.buffer.getText(), contains('tester@server:~\$ '));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      session.dispose();
    });
  }
  testWidgets('主窗口把当前 SSH 主机的本机历史接入 AI 面板', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'history-host', host: testHost)
      ..status = ConnectionStatus.connected;
    final history = _HistoryFixture();
    final model = _SessionModel(session, historyStore: history);
    await model.initialize();
    model.aiSettings = const AiSettings(
      baseUrl: 'https://ai.example.com/v1',
      model: 'test',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Workspace(model: model, onToggleTheme: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-ai')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    expect(
      history.scopes,
      contains('${testHost.id}|${testHost.endpoint}|${testHost.username}'),
    );
    expect(find.text('本机归档问题'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-history-item-history-1')));
    await tester.pumpAndSettle();
    expect(find.text('归档回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    session.dispose();
  });

  testWidgets('AI 面板可拖动调整宽度，保留输入、终端与所选宽度', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'resize', host: testHost)
      ..status = ConnectionStatus.connected;
    session.terminal.write('resize-output\r\n');
    final controller = TerminalPaneController();
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(
            session: session,
            controller: controller,
            onReconnect: () {},
            aiSettings: () => const AiSettings(
              baseUrl: 'https://ai.example.com/v1',
              model: 'test',
            ),
          ),
        ),
      ),
    );
    final terminalState = tester.state(find.byType(TerminalView));
    final handle = find.byKey(const ValueKey('ai-panel-resize-handle'));
    final panel = find.byType(TerminalAiPanel);
    final input = find.byKey(const ValueKey('ai-task-input'));
    double panelWidth() => tester.getSize(panel).width;
    double handleLeft() => tester.getTopLeft(handle).dx;
    void expectPreserved() {
      expect(tester.takeException(), isNull);
      expect(tester.widget<TextField>(input).controller!.text, '检查磁盘');
      expect(
        tester.state(find.byType(TerminalView, skipOffstage: false)),
        same(terminalState),
      );
      expect(session.terminal.buffer.getText(), contains('resize-output'));
    }

    Future<void> dragBy(double dx) async {
      await tester.drag(handle, Offset(dx, 0));
      await tester.pumpAndSettle();
      expectPreserved();
    }

    Future<void> resizeWindow(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expectPreserved();
    }

    // A closed panel has nothing to size: the terminal owns the whole pane.
    expect(handle, findsNothing);
    expect(panel, findsNothing);
    controller.selectOption('ai');
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
    expect(panelWidth(), 400, reason: '1000 宽的 40% 作为默认值');
    await tester.enterText(input, '检查磁盘');
    await tester.pumpAndSettle();
    expectPreserved();

    // Dragging right narrows the panel; it stops where the composer is still
    // usable, not at zero.
    await dragBy(400);
    expect(panelWidth(), 320);
    expect(handleLeft(), 672, reason: '终端仍占 672，面板占 320，手柄 8');

    // Dragging left widens it; the terminal keeps its 280px minimum.
    await dragBy(-500);
    expect(panelWidth(), 712, reason: '1000 宽的上界是 712，不是 512');
    expect(handleLeft(), 280);

    // Double-clicking the handle returns to the automatic 40% share.
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expectPreserved();
    expect(panelWidth(), 400);

    // A width the user picked survives the compact view and the breakpoint.
    await dragBy(-100);
    final picked = panelWidth();
    expect(picked, greaterThan(400));
    expect(picked, lessThan(512));
    await resizeWindow(const Size(390, 700));
    expect(handle, findsNothing);
    expect(find.byType(TerminalView), findsNothing);
    expect(tester.getSize(panel), const Size(390, 700));
    await resizeWindow(const Size(240, 160));
    expect(handle, findsNothing);
    expect(find.byType(TerminalView), findsNothing);
    expect(tester.getSize(panel), const Size(240, 160));
    await resizeWindow(const Size(1000, 700));
    expect(handle, findsOneWidget);
    expect(panelWidth(), closeTo(picked, 0.01), reason: '放大后回到用户选择的宽度');

    // 800 is the breakpoint where the handle appears; its upper bound is 512.
    await resizeWindow(const Size(800, 700));
    expect(handle, findsOneWidget);
    expect(panelWidth(), closeTo(picked, 0.01));
    await dragBy(-300);
    expect(panelWidth(), 512);
    expect(handleLeft(), 280);
    await resizeWindow(const Size(1000, 700));
    expect(panelWidth(), 512);
    await dragBy(-300);
    expect(panelWidth(), 712);

    // Closing and re-opening keeps the width the user chose.
    controller.selectOption('ai');
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(handle, findsNothing);
    expect(session.status, ConnectionStatus.connected);
    controller.selectOption('ai');
    await tester.pumpAndSettle();
    expect(panelWidth(), 712);
    expect(handleLeft(), 280);
    expect(session.terminal.buffer.getText(), contains('resize-output'));
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets('窄 AI 面板在 200% 字号下保留独立窗口入口，审批流程不溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final executor = _NeverExecute();
    final task = AiTaskController(
      settings: () => const AiSettings(
        baseUrl: 'https://ai.example.com/v1',
        model: 'model',
      ),
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: _ApprovalClient.new,
    );
    final session = SshConnection(id: 'narrow-panel', host: testHost)
      ..status = ConnectionStatus.connected;
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: TerminalAiLayout(
            terminal: TerminalPane(session: session, onReconnect: () {}),
            panel: TerminalAiPanel(
              task: task,
              hostName: '开发服务器',
              onClose: () {},
              onDetach: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byType(TerminalAiPanel);
    expect(tester.getSize(panel).width, 400);
    await tester.drag(
      find.byKey(const ValueKey('ai-panel-resize-handle')),
      const Offset(400, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, 320);
    expect(find.byKey(const ValueKey('ai-popout')), findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.text('开发服务器')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('ai-task-input')));
    await tester.enterText(
      find.byKey(const ValueKey('ai-task-input')),
      '清理测试文件',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('ai-send')));
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pumpAndSettle();
    expect(find.text('批准并执行'), findsOneWidget);
    expect(find.text('rm /tmp/test-file'), findsWidgets);
    expect(executor.calls, 0);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(task.running, isFalse);
    expect(executor.calls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
    session.dispose();
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('AI 设置保存及密钥隐藏 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      final controller = LocalSyncSettingsController(model);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(body: AiSettingsPage(controller: controller)),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-url')),
        'https://ai.example.com/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-key')),
        'test-key',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-model')),
        'model',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-setting-key')))
            .obscureText,
        isTrue,
      );
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(model.aiSettings.model, 'model');
      expect(model.aiSettings.apiKey, 'test-key');
      expect(find.text('AI 设置已保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      model.dispose();
    });
  }

  for (final (width, height, scale) in [
    (320.0, 900.0, 1.0),
    (1280.0, 900.0, 1.0),
    (320.0, 900.0, 2.0),
    (390.0, 240.0, 1.0),
    (320.0, 240.0, 2.0),
  ]) {
    testWidgets('AI 任务面板确认与取消 $width × $height × $scale', (tester) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final executor = _NeverExecute();
      final task = AiTaskController(
        settings: () => const AiSettings(
          baseUrl: 'https://ai.example.com/v1',
          model: 'model',
        ),
        executorFactory: () => executor,
        connected: () => true,
        clientFactory: _ApprovalClient.new,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: TerminalAiPanel(task: task, hostName: '开发服务器'),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('ai-task-input')));
      await tester.enterText(
        find.byKey(const ValueKey('ai-task-input')),
        '清理测试文件',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('ai-send')));
      await tester.tap(find.byKey(const ValueKey('ai-send')));
      await tester.pumpAndSettle();
      expect(find.text('批准并执行'), findsOneWidget);
      expect(find.text('rm /tmp/test-file'), findsWidgets);
      expect(executor.calls, 0);
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(task.running, isFalse);
      expect(executor.calls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      task.dispose();
    });
  }

  testWidgets('独立窗口与主面板互斥，切换和收回都不停止任务', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <MethodCall>[];
    var failOpen = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      aiWindowChannel,
      (call) async {
        calls.add(call);
        if (call.method == 'open' && failOpen) {
          throw PlatformException(code: 'window', message: '无法创建 AI 窗口');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        aiWindowChannel,
        null,
      ),
    );
    final host = AiWindowHost(
      appearance: () => const AppearancePreferences(),
      pushInterval: Duration.zero,
    );
    addTearDown(host.dispose);
    final first = SshConnection(id: 'pane-a', host: testHost)
      ..status = ConnectionStatus.connected;
    final second = SshConnection(id: 'pane-b', host: testHost)
      ..status = ConnectionStatus.connected;
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    AiSettings settings() =>
        const AiSettings(baseUrl: 'https://ai.example.com/v1', model: 'test');
    Widget pane(Key key, SshConnection session) => KeyedSubtree(
      key: key,
      child: TerminalPane(
        session: session,
        onReconnect: () {},
        aiSettings: settings,
        aiWindow: host,
        statusVisible: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: pane(const ValueKey('pane-a'), first)),
              Expanded(child: pane(const ValueKey('pane-b'), second)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-popout')), findsNothing);

    Future<void> openAi(ValueKey<String> pane) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(pane),
          matching: find.byKey(const ValueKey('terminal-ai')),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder panelIn(ValueKey<String> pane) => find.descendant(
      of: find.byKey(pane),
      matching: find.byType(TerminalAiPanel),
    );

    await openAi(const ValueKey('pane-a'));
    expect(panelIn(const ValueKey('pane-a')), findsOneWidget);
    final taskA =
        tester.widget<TerminalAiPanel>(panelIn(const ValueKey('pane-a'))).task
          ..running = true
          ..status = '思考中';
    taskA.notifyListeners();
    await tester.pump();

    failOpen = true;
    await tester.tap(find.byKey(const ValueKey('ai-popout')));
    await tester.pumpAndSettle();
    expect(panelIn(const ValueKey('pane-a')), findsOneWidget);
    expect(host.isDetached(first.id), isFalse);
    expect(taskA.running, isTrue);

    failOpen = false;
    await tester.tap(find.byKey(const ValueKey('ai-popout')));
    await tester.pumpAndSettle();
    expect(panelIn(const ValueKey('pane-a')), findsNothing);
    expect(host.isDetached(first.id), isTrue);
    expect(taskA.running, isTrue);
    expect(calls.where((call) => call.method == 'open'), isNotEmpty);

    await openAi(const ValueKey('pane-b'));
    final taskB =
        tester.widget<TerminalAiPanel>(panelIn(const ValueKey('pane-b'))).task
          ..running = true;
    taskB.notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-popout')));
    await tester.pumpAndSettle();
    expect(host.isDetached(second.id), isTrue);
    expect(host.isDetached(first.id), isFalse);
    expect(panelIn(const ValueKey('pane-a')), findsOneWidget);
    expect(panelIn(const ValueKey('pane-b')), findsNothing);
    expect(taskA.running, isTrue);
    expect(taskB.running, isTrue);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('pane-b')),
        matching: find.byKey(const ValueKey('terminal-ai')),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.isDetached(second.id), isFalse);
    expect(taskB.running, isTrue);
    expect(panelIn(const ValueKey('pane-b')), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('pane-b')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(taskB.running, isFalse);
    expect(taskA.running, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立窗口切换会话时新会话的嵌入面板隐藏，避免双显', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2000, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      aiWindowChannel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        aiWindowChannel,
        null,
      ),
    );
    final host = AiWindowHost(
      appearance: () => const AppearancePreferences(),
      pushInterval: Duration.zero,
    );
    addTearDown(host.dispose);
    final first = SshConnection(id: 'pane-a', host: testHost)
      ..status = ConnectionStatus.connected;
    final second = SshConnection(id: 'pane-b', host: testHost)
      ..status = ConnectionStatus.connected;
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    AiSettings settings() =>
        const AiSettings(baseUrl: 'https://ai.example.com/v1', model: 'test');
    Widget pane(Key key, SshConnection session) => KeyedSubtree(
      key: key,
      child: TerminalPane(
        session: session,
        onReconnect: () {},
        aiSettings: settings,
        aiWindow: host,
        statusVisible: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: pane(const ValueKey('pane-a'), first)),
              Expanded(child: pane(const ValueKey('pane-b'), second)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder panelIn(ValueKey<String> paneKey) => find.descendant(
      of: find.byKey(paneKey),
      matching: find.byType(TerminalAiPanel),
    );

    Future<void> openAi(ValueKey<String> paneKey) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(paneKey),
          matching: find.byKey(const ValueKey('terminal-ai')),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Both panes have their embedded assistant open.
    await openAi(const ValueKey('pane-a'));
    await openAi(const ValueKey('pane-b'));
    expect(panelIn(const ValueKey('pane-a')), findsOneWidget);
    expect(panelIn(const ValueKey('pane-b')), findsOneWidget);
    final taskA =
        tester.widget<TerminalAiPanel>(panelIn(const ValueKey('pane-a'))).task
          ..running = true;
    final taskB =
        tester.widget<TerminalAiPanel>(panelIn(const ValueKey('pane-b'))).task
          ..running = true;
    taskA.notifyListeners();
    taskB.notifyListeners();
    await tester.pump();

    // A is popped out: the AI window shows A.
    await host.open(first.id);
    await tester.pumpAndSettle();
    expect(host.isDetached(first.id), isTrue);
    expect(panelIn(const ValueKey('pane-a')), findsNothing);
    expect(panelIn(const ValueKey('pane-b')), findsOneWidget);

    // The window switches to B without going through B's pane. B must hide its
    // embedded panel instead of rendering the same conversation twice.
    await host.open(second.id);
    await tester.pumpAndSettle();
    expect(host.isDetached(second.id), isTrue);
    expect(host.isDetached(first.id), isFalse);
    expect(panelIn(const ValueKey('pane-a')), findsOneWidget);
    expect(panelIn(const ValueKey('pane-b')), findsNothing);
    expect(taskA.running, isTrue);
    expect(taskB.running, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (width, height, scale) in [
    (1280.0, 900.0, 1.0),
    (240.0, 900.0, 1.0),
    (240.0, 900.0, 2.0),
  ]) {
    testWidgets('模型菜单思考等级滑到极高并按档位发送，切回自动后停止传参 $width × $scale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, height);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _EffortClient();
      final executor = _RecordingExecutor();
      final task = AiTaskController(
        settings: () => const AiSettings(
          baseUrl: 'https://ai.example.com/v1',
          model: 'model-a',
        ),
        executorFactory: () => executor,
        connected: () => true,
        clientFactory: () => client,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: TerminalAiPanel(task: task, hostName: '开发服务器'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('ai-task-input'));
      final slider = find.byKey(const ValueKey('ai-reasoning-effort-slider'));
      final send = find.byKey(const ValueKey('ai-send'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '检查目录');
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '检查目录');

      Future<void> openMenu() async {
        await tester.ensureVisible(
          find.byKey(const ValueKey('ai-model-picker')),
        );
        await tester.tap(find.byKey(const ValueKey('ai-model-picker')));
        await tester.pumpAndSettle();
        expect(find.text('思考等级'), findsOneWidget);
        expect(find.text('刷新模型列表'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      Future<void> closeMenu() async {
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(find.text('思考等级'), findsNothing);
        expect(tester.takeException(), isNull);
      }

      // A drag starts at the slider centre (medium); the delta below lands on
      // whatever fraction of the track the menu width allows.
      Future<void> dragEffort(double delta) async {
        final track = tester.getSize(slider).width - 48;
        await tester.drag(slider, Offset(track * delta, 0));
        await tester.pumpAndSettle();
      }

      await openMenu();
      expect(task.reasoningEffort, AiReasoningEffort.automatic);
      expect(find.text('自动'), findsOneWidget);

      await dragEffort(2);
      expect(task.reasoningEffort, AiReasoningEffort.max);
      expect(find.text('最大'), findsOneWidget);
      await dragEffort(0.3);
      expect(task.reasoningEffort, AiReasoningEffort.xhigh);
      expect(find.text('极高'), findsOneWidget);
      expect(find.text('思考等级'), findsOneWidget, reason: '滑动不关闭菜单');
      expect(find.text('刷新模型列表'), findsOneWidget);
      expect(task.activeModel, 'model-a', reason: '选择档位不改模型');
      expect(
        tester.widget<TextField>(input).controller!.text,
        '检查目录',
        reason: '选择档位不丢草稿',
      );
      expect(task.running, isFalse);

      await closeMenu();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(executor.commands, ['pwd'], reason: '工具回合在这轮里执行');
      expect(task.entries.last.text, '检查完成');
      expect(client.configs, hasLength(2), reason: '工具结果后再请求同一模型');
      for (final config in client.configs) {
        expect(
          config.reasoningEffort,
          AiReasoningEffort.xhigh,
          reason: '工具回合沿用同一档位',
        );
      }
      expect(client.requests[1].last['role'], 'tool');
      expect(task.running, isFalse);
      expect(tester.takeException(), isNull);

      // Sliding back to the left end restores the provider default.
      await openMenu();
      await dragEffort(-2);
      expect(task.reasoningEffort, AiReasoningEffort.automatic);
      expect(find.text('自动'), findsOneWidget);
      expect(find.text('思考等级'), findsOneWidget);
      await closeMenu();
      await tester.enterText(input, '再次检查');
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(client.configs, hasLength(3));
      expect(client.configs.last.reasoningEffort, AiReasoningEffort.automatic);

      // The control itself is disabled while a turn is in flight.
      await openMenu();
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      task.running = true;
      task.notifyListeners();
      await tester.pump();
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      final picker = tester.widget<Widget>(
        find.byKey(const ValueKey('ai-model-picker')),
      );
      expect(
        picker is IconButton
            ? picker.onPressed
            : (picker as TextButton).onPressed,
        isNull,
      );
      task.running = false;
      task.notifyListeners();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      task.dispose();
    });
  }
}

class _EffortClient extends TerminalAiClient {
  final configs = <AiSettings>[];
  final requests = <List<Map<String, dynamic>>>[];

  @override
  Future<List<String>> listModels(AiSettings settings) async => const [
    'model-a',
    'model-b',
  ];

  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async {
    configs.add(settings);
    requests.add([
      for (final message in messages) Map<String, dynamic>.from(message),
    ]);
    if (requests.length == 1) {
      return AiReply(
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {
                'name': 'run_command',
                'arguments': jsonEncode({
                  'command': 'pwd',
                  'reason': '检查目录',
                  'requires_approval': false,
                }),
              },
            },
          ],
        },
        [AiToolCall('call-1', 'pwd', '检查目录', false)],
      );
    }
    return const AiReply({'role': 'assistant', 'content': '检查完成'}, []);
  }
}

class _RecordingExecutor implements AiCommandExecutor {
  final commands = <String>[];

  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    commands.add(command);
    onOutput('server output');
    return const AiCommandResult('server output', 0);
  }

  @override
  void cancel() {}
}

class _ApprovalClient extends TerminalAiClient {
  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async => const AiReply(
    {'role': 'assistant', 'content': '已定位需要清理的测试文件。'},
    [AiToolCall('1', 'rm /tmp/test-file', '此命令将删除测试文件', true)],
  );
}

class _NeverExecute implements AiCommandExecutor {
  int calls = 0;
  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    calls++;
    return const AiCommandResult('', 0);
  }

  @override
  void cancel() {}
}

class _SessionModel extends WorkspaceModel {
  _SessionModel(this.session, {AiConversationStore? historyStore})
    : super(memoryRepository(), aiHistoryStore: historyStore) {
    activeSessionId = session.id;
  }
  final SshConnection session;
  @override
  List<SshConnection> get sessions => [session];
  @override
  SshConnection? get activeSession => session;
}

class _HistoryFixture extends AiConversationStore {
  _HistoryFixture()
    : super(
        secrets: MemoryStore(),
        directory: () async => Directory.systemTemp,
      );

  final scopes = <String>[];
  static final created = DateTime(2024, 1, 1);

  @override
  Future<List<AiConversationSummary>> list(String scope) async {
    scopes.add(scope);
    return [
      AiConversationSummary(
        id: 'history-1',
        title: '本机归档问题',
        model: 'test',
        updatedAt: created,
      ),
    ];
  }

  @override
  Future<AiConversation?> load(String scope, String id) async {
    scopes.add(scope);
    return AiConversation(
      id: id,
      scope: scope,
      title: '本机归档问题',
      model: 'test',
      createdAt: created,
      updatedAt: created,
      entries: [
        {'text': '本机归档问题', 'user': true},
        {'text': '归档回答', 'model': 'test'},
      ],
      history: [
        {'role': 'user', 'content': '本机归档问题'},
        {'role': 'assistant', 'content': '归档回答'},
      ],
    );
  }
}
