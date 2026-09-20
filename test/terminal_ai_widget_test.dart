import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/ai_settings.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('厂商预设与接口选择保存，切换厂商不混用密钥 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
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
        await tester.tap(find.text(option).last);
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
      expect(tester.state(find.byType(TerminalView)), same(terminalState));
      final terminalRect = tester.getRect(find.byType(TerminalView));
      final aiRect = tester.getRect(find.byType(TerminalAiPanel));
      if (width < 900) {
        expect(aiRect.top, greaterThanOrEqualTo(terminalRect.bottom));
      } else {
        expect(aiRect.left, greaterThanOrEqualTo(terminalRect.right));
      }
      final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(milliseconds: 350));
      expect(terminal.focusNode!.hasFocus, isTrue);
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
      expect(session.status, ConnectionStatus.connected);
      expect(session.terminal.buffer.getText(), contains('tester@server:~\$ '));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      session.dispose();
    });
  }
  testWidgets('AI 随 SSH 面板缩放，保留输入和终端状态', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'resize', host: testHost)
      ..status = ConnectionStatus.connected;
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
    controller.selectOption('ai');
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('ai-task-input'));
    await tester.enterText(input, '检查磁盘');
    for (final size in [
      const Size(390, 700),
      const Size(240, 160),
      const Size(1000, 700),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<TextField>(input).controller!.text, '检查磁盘');
      expect(tester.state(find.byType(TerminalView)), same(terminalState));
    }
    controller.selectOption('ai');
    await tester.pumpAndSettle();
    expect(find.byType(TerminalAiPanel), findsNothing);
    expect(session.status, ConnectionStatus.connected);
    await tester.pumpWidget(const SizedBox.shrink());
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
  _SessionModel(this.session) : super(memoryRepository()) {
    activeSessionId = session.id;
  }
  final SshConnection session;
  @override
  List<SshConnection> get sessions => [session];
  @override
  SshConnection? get activeSession => session;
}
