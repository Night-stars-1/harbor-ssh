import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/mcp_client.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_mcp_settings.dart';
import 'package:harbor_ssh/ui/ai_prompt_settings.dart';
import 'package:harbor_ssh/ui/ai_settings.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  testWidgets('提示词弹窗与 MCP 配置保存、重开、切换服务商和清空', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    final clients = <_FakeMcpClient>[];
    McpClient factory(AiMcpServer server) {
      final client = _FakeMcpClient(server);
      clients.add(client);
      return client;
    }

    Future<void> pump() => tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AiSettingsPage(
            key: UniqueKey(),
            controller: controller,
            mcpClientFactory: factory,
          ),
        ),
      ),
    );

    Future<void> savePage() async {
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    final promptEdit = find.byKey(const ValueKey('ai-setting-prompt-edit'));
    final promptField = find.byKey(const ValueKey('ai-setting-system-prompt'));
    final promptCancel = find.byKey(const ValueKey('ai-setting-prompt-cancel'));
    final promptConfirm = find.byKey(
      const ValueKey('ai-setting-prompt-confirm'),
    );

    Future<void> openPromptEditor() async {
      await tester.ensureVisible(promptEdit);
      await tester.tap(promptEdit);
      await tester.pumpAndSettle();
    }

    String promptDraft() =>
        tester.widget<TextField>(promptField).controller!.text;

    Future<void> dismissPromptEditor({required bool confirm}) async {
      await tester.tap(confirm ? promptConfirm : promptCancel);
      await tester.pumpAndSettle();
    }

    await pump();
    await tester.pumpAndSettle();
    await openPromptEditor();
    await tester.enterText(promptField, '回答前先给出可回滚方案');
    await dismissPromptEditor(confirm: true);
    expect(promptField, findsNothing, reason: '确定后关闭弹窗');

    // Changing the provider swaps the credential drafts but must keep the
    // page-scoped supplement.
    final provider = find.byKey(const ValueKey('ai-setting-provider'));
    await tester.ensureVisible(provider);
    await tester.tap(provider);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Anthropic').hitTestable(),
    );
    await tester.pumpAndSettle();
    await openPromptEditor();
    expect(promptDraft(), '回答前先给出可回滚方案', reason: '切换服务商不丢提示词');

    // Cancelling (or dismissing with Escape) keeps the page text untouched.
    await tester.enterText(promptField, '被取消的草稿');
    await dismissPromptEditor(confirm: false);
    expect(promptField, findsNothing, reason: '取消后关闭弹窗');
    await openPromptEditor();
    expect(promptDraft(), '回答前先给出可回滚方案', reason: '取消不写回页面');
    await dismissPromptEditor(confirm: false);

    // Escape dismisses the dialog without writing back either.
    await openPromptEditor();
    await tester.enterText(promptField, '按 Escape 的草稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(promptField, findsNothing, reason: 'Escape 关闭弹窗');
    await openPromptEditor();
    expect(promptDraft(), '回答前先给出可回滚方案', reason: 'Escape 不写回页面');
    await dismissPromptEditor(confirm: false);

    // Add one MCP server through the editor and exercise the real tool-list
    // test button (the injected client records the call).
    final add = find.byKey(const ValueKey('ai-mcp-add'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-mcp-name')), 'GitHub');
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-url')),
      'https://mcp.example.com/mcp',
    );
    await tester.tap(find.byKey(const ValueKey('ai-mcp-header-add')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('ai-mcp-header-key-0')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-header-key-0')),
      'Authorization',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-header-value-0')),
      'Bearer ui-secret',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('ai-mcp-header-value-0')),
          )
          .obscureText,
      isTrue,
      reason: '请求头值默认隐藏',
    );

    // Duplicate header names are a field error: the test action must report it
    // inline instead of throwing out of the dialog.
    await tester.ensureVisible(find.byKey(const ValueKey('ai-mcp-header-add')));
    await tester.tap(find.byKey(const ValueKey('ai-mcp-header-add')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('ai-mcp-header-key-1')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-header-key-1')),
      'Authorization',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-header-value-1')),
      'Bearer duplicate',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('ai-mcp-test')));
    await tester.tap(find.byKey(const ValueKey('ai-mcp-test')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-mcp-test-error')), findsOneWidget);
    expect(find.textContaining('请求头「Authorization」重复'), findsOneWidget);
    expect(clients, isEmpty, reason: '无效配置不会创建连接');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-mcp-header-remove-1')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('ai-mcp-test')));
    await tester.tap(find.byKey(const ValueKey('ai-mcp-test')));
    await tester.pumpAndSettle();
    expect(find.text('连接成功，发现 2 个工具'), findsOneWidget);
    expect(find.textContaining('search_issues'), findsWidgets);
    expect(clients, hasLength(1));
    expect(clients.single.listToolsCalls, 1);
    expect(clients.single.callToolCalls, 0, reason: '测试连接只列出工具');
    expect(clients.single.closed, isTrue);
    expect(
      tester
          .widgetList<Text>(find.byType(Text))
          .any((text) => text.data?.contains('ui-secret') ?? false),
      isFalse,
      reason: '诊断结果不渲染请求头值',
    );
    await tester.tap(find.byKey(const ValueKey('ai-mcp-save')));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);

    await savePage();
    expect(model.aiSettings.systemPrompt, '回答前先给出可回滚方案');
    expect(model.aiSettings.mcpServers, hasLength(1));
    expect(model.aiSettings.mcpServers.single.name, 'GitHub');
    expect(
      model.aiSettings.mcpServers.single.headers['Authorization'],
      'Bearer ui-secret',
    );

    // Re-open: both the prompt supplement and the server survive a page
    // recreation, and the saved header value is still masked.
    await pump();
    await tester.pumpAndSettle();
    await openPromptEditor();
    expect(promptDraft(), '回答前先给出可回滚方案', reason: '重开后提示词仍在');
    await dismissPromptEditor(confirm: false);
    expect(find.text('GitHub'), findsOneWidget);
    final serverId = model.aiSettings.mcpServers.single.id;
    final more = find.byKey(ValueKey('ai-mcp-more-$serverId'));

    Future<void> openServerMenu() async {
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
    }

    // The row itself opens the editor, so editing never needs a second tap.
    // Cancelling leaves the saved server untouched.
    await tester.ensureVisible(find.byKey(ValueKey('ai-mcp-open-$serverId')));
    await tester.tap(find.byKey(ValueKey('ai-mcp-open-$serverId')));
    await tester.pumpAndSettle();
    expect(find.text('编辑 MCP 服务'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-url')),
      'https://discarded.example.com/mcp',
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(
      model.aiSettings.mcpServers.single.url,
      'https://mcp.example.com/mcp',
      reason: '取消编辑不写回',
    );
    await savePage();
    expect(
      model.aiSettings.mcpServers.single.url,
      'https://mcp.example.com/mcp',
      reason: '取消后保存仍是原地址',
    );

    // The same editor is also reachable from the overflow menu.
    await openServerMenu();
    await tester.tap(find.byKey(ValueKey('ai-mcp-edit-$serverId')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('ai-mcp-header-value-0')),
          )
          .obscureText,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-url')),
      'https://mcp2.example.com/mcp',
    );
    await tester.tap(find.byKey(const ValueKey('ai-mcp-save')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(find.byKey(ValueKey('ai-mcp-toggle-$serverId')))
          .value,
      isTrue,
      reason: '服务器默认启用',
    );
    await tester.ensureVisible(find.byKey(ValueKey('ai-mcp-toggle-$serverId')));
    await tester.tap(find.byKey(ValueKey('ai-mcp-toggle-$serverId')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: '开关只切换不弹窗');
    await savePage();
    final saved = model.aiSettings.mcpServers.single;
    expect(saved.enabled, isFalse, reason: '启用状态随设置保存');
    expect(saved.url, 'https://mcp2.example.com/mcp');
    expect(
      saved.headers['Authorization'],
      'Bearer ui-secret',
      reason: '编辑地址不会丢失请求头',
    );

    // Clearing the supplement in the dialog saves an empty value and leaves
    // the MCP server untouched.
    await openPromptEditor();
    await tester.enterText(promptField, '');
    await dismissPromptEditor(confirm: true);
    await savePage();
    expect(model.aiSettings.systemPrompt, isEmpty);
    expect(model.aiSettings.mcpServers, hasLength(1));

    await pump();
    await tester.pumpAndSettle();
    await openPromptEditor();
    expect(promptDraft(), isEmpty, reason: '清空后重开仍为空');
    await dismissPromptEditor(confirm: false);
    expect(find.text('GitHub'), findsOneWidget);

    // Delete lives behind the overflow menu and still asks for confirmation.
    await openServerMenu();
    await tester.tap(find.byKey(ValueKey('ai-mcp-delete-$serverId')));
    await tester.pumpAndSettle();
    expect(find.text('删除 MCP 服务？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget, reason: '取消删除保留服务');
    await savePage();
    expect(model.aiSettings.mcpServers, hasLength(1), reason: '取消删除不写回');
    await openServerMenu();
    await tester.tap(find.byKey(ValueKey('ai-mcp-delete-$serverId')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    await savePage();
    expect(model.aiSettings.mcpServers, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  testWidgets('MCP 列表行在 320px 窄屏仍可编辑且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var servers = <AiMcpServer>[
      const AiMcpServer(
        id: 'ops',
        name: '运维助手',
        url: 'https://mcp.example.com/a-very-long-endpoint-that-must-ellipsize/ops',
      ),
      const AiMcpServer(
        id: 'docs',
        name: '内部文档',
        url: 'http://10.0.0.12:8080/mcp',
        enabled: false,
      ),
    ];
    await tester.pumpWidget(
      _mcpHarness(
        readServers: () => servers,
        onChanged: (next) => servers = List.of(next),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '窄屏行不溢出');

    await tester.tap(find.byKey(const ValueKey('ai-mcp-toggle-docs')));
    await tester.pumpAndSettle();
    expect(servers.last.enabled, isTrue);
    await tester.tap(find.byKey(const ValueKey('ai-mcp-toggle-docs')));
    await tester.pumpAndSettle();
    expect(servers.last.enabled, isFalse);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('ai-mcp-more-ops')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-mcp-edit-ops')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '窄屏菜单不溢出');
    await tester.tap(find.byKey(const ValueKey('ai-mcp-edit-ops')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '窄屏弹窗不溢出');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ai-mcp-open-docs')));
    await tester.pumpAndSettle();
    expect(find.text('编辑 MCP 服务'), findsOneWidget, reason: '停用服务仍可编辑');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('320px 窄屏弹窗编辑提示词不溢出并写回草稿', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: '初始补充');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AiPromptSettings(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The on-screen keyboard covers the lower half of a narrow screen while
    // the dialog is open.
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-setting-prompt-edit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '窄屏弹窗不溢出');

    final long = List.filled(40, '长内容').join();
    final field = find.byKey(const ValueKey('ai-setting-system-prompt'));
    await tester.enterText(field, long);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '长内容在弹窗内滚动');
    await tester.tap(find.byKey(const ValueKey('ai-setting-prompt-confirm')));
    await tester.pumpAndSettle();
    expect(controller.text, long);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地转发审批默认不保存规则，勾选后随批准发送', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _ApprovalTask();
    addTearDown(task.dispose);
    task
      ..running = true
      ..status = '等待确认'
      ..pending = _forward(1);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: '开发服务器'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final option = find.byKey(const ValueKey('ai-save-forward-rule'));
    expect(option, findsOneWidget);
    expect(find.text('保存到主机规则'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(option).value, isFalse);
    expect(
      find.text('本地端口转发：127.0.0.1:8080 → 服务器侧 127.0.0.1:80'),
      findsOneWidget,
    );

    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(option).value, isTrue);
    await tester.ensureVisible(find.text('批准并执行'));
    await tester.tap(find.text('批准并执行'));
    await tester.pumpAndSettle();
    expect(task.approvals, [(true, true, 'f1')]);

    // A new forward always starts unchecked, and cancel never saves.
    task
      ..running = true
      ..status = '等待确认'
      ..pending = _forward(2);
    task.poke();
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(option).value, isFalse);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(task.approvals.last, (false, false, 'f2'));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立窗口同样展示转发保存选项并传递选择', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _ApprovalTask();
    addTearDown(task.dispose);
    task
      ..running = true
      ..status = '等待确认'
      ..pending = _forward(3);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: '生产服务器', onDock: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final option = find.byKey(const ValueKey('ai-save-forward-rule'));
    await tester.ensureVisible(option);
    expect(tester.widget<CheckboxListTile>(option).value, isFalse);
    await tester.tap(option);
    await tester.pump();
    await tester.ensureVisible(find.text('批准并执行'));
    await tester.tap(find.text('批准并执行'));
    await tester.pumpAndSettle();
    expect(task.approvals, [(true, true, 'f3')]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('MCP 审批显示服务器、工具与参数，不按 shell 渲染', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = _ApprovalTask();
    addTearDown(task.dispose);
    task.entries.add(
      AiTaskEntry('MCP「GitHub」调用工具 search_issues', command: true)
        ..reason = '搜索相关 issue'
        ..finished = true,
    );
    task
      ..running = true
      ..status = '等待确认'
      ..pending = AiToolCall(
        'm1',
        'MCP「GitHub」调用工具 search_issues',
        '允许调用服务器上的这个工具？',
        true,
        name: 'search_issues',
        arguments: const {'query': 'repo:flutter/flutter', 'limit': 5},
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: '开发服务器'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存到主机规则'), findsNothing);
    expect(find.text('MCP「GitHub」调用工具 search_issues'), findsWidgets);
    final texts = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    expect(
      texts.any(
        (widget) =>
            (widget.data ?? '').contains('"query": "repo:flutter/flutter"'),
      ),
      isTrue,
      reason: '参数以 JSON 展示',
    );
    expect(find.byIcon(Icons.hub_outlined), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('MCP 测试连接可取消并释放客户端', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _HangingMcpClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: AiMcpSettingsEditor(
              servers: const [],
              onChanged: (_) {},
              clientFactory: (_) => client,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ai-mcp-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-mcp-name')), 'Slow');
    await tester.enterText(
      find.byKey(const ValueKey('ai-mcp-url')),
      'https://mcp.example.com/mcp',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('ai-mcp-test')));
    await tester.tap(find.byKey(const ValueKey('ai-mcp-test')));
    await tester.pump();
    expect(find.text('正在连接…'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(client.cancelled, isTrue);
    expect(client.closed, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// Mounts [AiMcpSettingsEditor] over a mutable in-memory list so the row
/// interactions can be exercised without the whole settings page.
Widget _mcpHarness({
  required List<AiMcpServer> Function() readServers,
  required ValueChanged<List<AiMcpServer>> onChanged,
}) => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: StatefulBuilder(
        builder: (context, setState) => AiMcpSettingsEditor(
          servers: readServers(),
          onChanged: (next) => setState(() => onChanged(next)),
          clientFactory: (_) => throw const McpFailure('测试不连接服务器'),
        ),
      ),
    ),
  ),
);

AiToolCall _forward(int id) => AiToolCall(
  'f$id',
  '本地端口转发：127.0.0.1:8080 → 服务器侧 127.0.0.1:80',
  '允许建立本地端口转发？',
  true,
  name: 'create_port_forward',
  arguments: {
    'name': 'web',
    'local_port': 8080,
    'target_host': '127.0.0.1',
    'target_port': 80,
    'reason': '访问内网管理页',
  },
);

class _ApprovalTask extends AiTaskController {
  _ApprovalTask()
    : super(
        settings: () => const AiSettings(
          baseUrl: 'https://ai.example.com/v1',
          model: 'model',
        ),
        executorFactory: () => throw const AiFailure('测试不执行命令'),
        connected: () => true,
        clientFactory: () => throw const AiFailure('测试不发送请求'),
      );

  final approvals = <(bool, bool, String?)>[];

  void poke() => notifyListeners();

  @override
  void approve(
    bool allowed, {
    bool saveForward = false,
    String? expectedCallId,
  }) {
    approvals.add((allowed, saveForward, expectedCallId));
    pending = null;
    notifyListeners();
  }
}

class _FakeMcpClient implements McpClient {
  _FakeMcpClient(this.server);

  @override
  final AiMcpServer server;
  @override
  final Duration requestTimeout = const Duration(seconds: 1);
  @override
  final Duration auxiliaryTimeout = const Duration(seconds: 1);

  int listToolsCalls = 0;
  int callToolCalls = 0;
  bool closed = false;

  @override
  Future<List<McpTool>> listTools() async {
    listToolsCalls++;
    return [
      McpTool('search_issues', '搜索 issue', const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
      }),
      McpTool('read_issue', '读取 issue', const {
        'type': 'object',
        'properties': <String, dynamic>{},
      }),
    ];
  }

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    callToolCalls++;
    return const {'content': <Map<String, dynamic>>[]};
  }

  @override
  void cancel() {}

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// Test connection that never answers until [cancel] or [close] is called.
class _HangingMcpClient implements McpClient {
  _HangingMcpClient() : server = _server;

  static const _server = AiMcpServer(
    id: 'slow',
    name: 'Slow',
    url: 'https://mcp.example.com/mcp',
  );

  @override
  final AiMcpServer server;
  @override
  final Duration requestTimeout = const Duration(seconds: 1);
  @override
  final Duration auxiliaryTimeout = const Duration(seconds: 1);

  final _tools = Completer<List<McpTool>>();
  bool cancelled = false;
  bool closed = false;

  void _abort(String message) {
    if (!_tools.isCompleted) _tools.completeError(McpFailure(message));
  }

  @override
  Future<List<McpTool>> listTools() => _tools.future;

  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async => const {'content': <Map<String, dynamic>>[]};

  @override
  void cancel() {
    cancelled = true;
    _abort('已取消');
  }

  @override
  Future<void> close() async {
    closed = true;
    _abort('已关闭');
  }
}
