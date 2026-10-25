import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/ai_markdown_code_block.dart';
import 'package:harbor_ssh/ui/ai_markdown_table.dart';
import 'package:harbor_ssh/ui/ai_window_bridge.dart';
import 'package:harbor_ssh/ui/ai_window_session.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('独立窗口镜像主引擎状态，用户动作回主引擎执行', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('你好', user: true));
    h.task
      ..running = true
      ..status = '思考中'
      ..approvalMode = AiApprovalMode.auto;

    await h.host.open('s1');
    expect(h.openCount, 1);
    expect(h.host.isDetached('s1'), isTrue);
    expect(h.pushes, hasLength(1), reason: '打开窗口后立即镜像一次');

    await h.remote.initialize();
    expect(h.remote.sessionId, 's1');
    expect(h.remote.hostName, '生产服务器');
    expect(h.remote.entries.single.text, '你好');
    expect(h.remote.running, isTrue);
    expect(h.remote.status, '思考中');
    expect(h.remote.approvalMode, AiApprovalMode.auto);
    expect(h.remote.settings().configured, isTrue);
    expect(h.remote.activeModel, 'model-x');

    // Approval and every other user action land on the one main-engine
    // controller.
    h.task.entries.clear();
    h.task.pending = const AiToolCall('c1', 'rm -rf /tmp/x', '清理', true);
    h.task.poke();
    await h.settle();
    expect(h.remote.pending!.command, 'rm -rf /tmp/x');
    expect(h.remote.pending!.reason, '清理');
    h.remote.approve(true, expectedCallId: 'c1');
    await h.settle();
    expect(h.task.approved, isTrue);
    expect(h.task.approvedSaveForward, isFalse);
    expect(h.task.approvedCallId, 'c1');

    // A port-forward approval uses the single approve operation and carries the
    // per-call rule choice through the extra saveForward flag.
    h.task.pending = const AiToolCall(
      'f1',
      '本地转发：127.0.0.1:8080 → 服务器 127.0.0.1:80',
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
    h.task.poke();
    await h.settle();
    expect(h.remote.pending!.name, 'create_port_forward');
    h.remote.approve(true, saveForward: true, expectedCallId: 'f1');
    await h.settle();
    expect(h.task.approved, isTrue);
    expect(h.task.approvedSaveForward, isTrue);
    expect(h.task.approvedCallId, 'f1');
    expect(h.task.calls, contains('approve:true:1:f1'));

    await h.remote.start('列出文件');
    expect(h.task.calls, contains('start:列出文件'));
    h.remote.stop();
    h.remote.setModel('model-y');
    h.remote.setApprovalMode(AiApprovalMode.readOnly);
    h.remote.setAutoApprove(false);
    await h.remote.newConversation();
    await h.remote.openConversation('c1');
    await h.remote.deleteConversation('c2');
    await h.remote.loadHistory();
    await h.settle();
    expect(h.task.calls, contains('stop:'));
    expect(h.task.calls, contains('setModel:model-y'));
    expect(h.task.calls, contains('setApprovalMode:readOnly'));
    expect(h.task.calls, contains('setAutoApprove:false'));
    expect(h.task.calls, contains('newConversation'));
    expect(h.task.calls, contains('openConversation:c1'));
    expect(h.task.calls, contains('deleteConversation:c2'));
    expect(h.task.calls, contains('loadHistory'));
    expect(await h.remote.listModels(), ['a', 'b']);
    expect(h.task.calls, contains('listModels'));
    expect(
      (await h.remote.previewConversation('c3'))!.single.text,
      '预览内容',
      reason: '历史预览经主引擎读取',
    );
    expect(h.task.calls, contains('previewConversation:c3'));
    final stopsBeforeClose = h.task.stopCount;
    expect(stopsBeforeClose, 1, reason: '面板停止按钮只转发一次');

    // Dock and native close both give the panel back to the main window.
    await h.host.handle(
      const MethodCall('dock', <String, Object?>{'sessionId': 's1'}),
    );
    expect(h.docks, 1);
    expect(h.host.isDetached('s1'), isFalse);
    await h.host.handle(const MethodCall('closed'));
    expect(h.docks, 1, reason: '同一次关闭不重复回嵌');
    await h.host.open('s1');
    await h.host.handle(const MethodCall('closed'));
    expect(h.docks, 2);
    expect(h.task.stopCount, stopsBeforeClose, reason: '关闭窗口绝不停止任务');
  });

  test('迟到的审批不会作用于后来的调用', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('你好', user: true));
    await h.host.open('s1');
    await h.remote.initialize();

    h.task.pending = const AiToolCall('old', 'rm -rf /tmp/old', '清理旧文件', true);
    h.task.poke();
    await h.settle();
    expect(h.remote.pending!.id, 'old');

    // The controller moves on before the user's click reaches the main engine.
    h.task.pending = const AiToolCall('new', 'rm -rf /tmp/new', '清理新文件', true);
    h.task.poke();
    await h.settle();
    expect(h.remote.pending!.id, 'new');

    // The stale grant and the stale cancel are both ignored.
    h.remote.approve(true, expectedCallId: 'old');
    await h.settle();
    expect(h.task.approved, isNull);
    expect(
      h.task.calls.where((call) => call.startsWith('approve')),
      isEmpty,
      reason: '主引擎没有收到旧调用的审批',
    );
    h.remote.approve(false, expectedCallId: 'old');
    await h.settle();
    expect(h.task.stopCount, 0, reason: '迟到的取消不停止新调用');

    // A click carrying the current call id still works.
    h.remote.approve(true, expectedCallId: 'new');
    await h.settle();
    expect(h.task.approved, isTrue);
    expect(h.task.approvedCallId, 'new');
  });

  test('重复 open/close 复用同一窗口并重建条目镜像', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('第一条', user: true));

    for (var round = 0; round < 3; round++) {
      await h.host.open('s1');
      expect(h.host.isDetached('s1'), isTrue);
      await h.remote.applyMirror(h.pushes.last);
      expect(h.remote.entries.single.text, '第一条');
      expect(h.pushes.last['reset'], isTrue, reason: '每次唤醒都重建条目镜像');
      await h.host.handle(
        const MethodCall('dock', <String, Object?>{'sessionId': 's1'}),
      );
      expect(h.host.isDetached('s1'), isFalse);
    }
    expect(h.openCount, 3);
    expect(h.docks, 3);
    expect(h.task.stopCount, 0);
  });

  test('图片只在首次出现时传字节，token 更新只传变化条目', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final image = await AiImage.fromBytes('shot.png', base64Decode(png));
    await h.remote.initialize();
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('看这张图', user: true, images: [image]));
    h.task.entries.add(AiTaskEntry('处理中'));

    await h.host.open('s1');
    await h.settle();
    final first = h.pushes.single;
    expect((first['images'] as Map).length, 1);
    expect((first['entries'] as Map).length, 2);
    final mirrored = h.remote.entries.first;
    expect(mirrored.images!.single.bytes, image.bytes);
    expect(h.remote.entries, hasLength(2));

    // A streaming token update: same entry object, no image bytes, and only the
    // entry that changed.
    h.task.entries.first.text = '看这张图（补充说明）';
    h.task.poke();
    await h.settle();
    final push = h.pushes.last;
    expect(push['reset'], isFalse);
    expect(push['images'], isEmpty, reason: '图片字节不重复发送');
    expect((push['entries'] as Map).keys, ['0'], reason: '只包含变化条目');
    expect(h.remote.entries.first.text, '看这张图（补充说明）');
    expect(
      identical(h.remote.entries.first, mirrored),
      isTrue,
      reason: '纯文本更新沿用同一条目对象',
    );
    expect(h.remote.entries.first.images!.single.bytes, image.bytes);
    expect(h.remote.entries.last.text, '处理中');

    // An attachment picked in the detached window must reach the main engine.
    await h.remote.start('看看这张图', images: [image]);
    await h.settle();
    expect(h.task.calls, contains('start:看看这张图'));
    expect(h.task.lastImages.single.bytes, image.bytes);
    expect(h.task.lastImages.single.name, 'shot.png');
  });

  test('新对话同位置的图片不会沿用上一条对话的附件引用', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final previous = await AiImage.fromBytes('shot.png', base64Decode(png));
    final current = await AiImage.fromBytes(
      'shot.png',
      Uint8List.fromList([...base64Decode(png), 1, 2, 3]),
    );
    await h.remote.initialize();
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('旧图', user: true, images: [previous]));
    await h.host.open('s1');
    await h.settle();
    expect(h.remote.entries.single.images!.single.bytes, previous.bytes);

    // The pane opens another conversation: the same index now holds a different
    // attachment (what `openConversation` does).
    h.task.entries[0] = AiTaskEntry('新图', user: true, images: [current]);
    h.task.poke();
    await h.settle();
    expect((h.pushes.last['images'] as Map), hasLength(1));
    expect(h.remote.entries.single.text, '新图');
    expect(
      h.remote.entries.single.images!.single.bytes,
      current.bytes,
      reason: '旧对话的附件引用不能落到新条目上',
    );
    expect(h.remote.entries.single.images!.single.bytes, isNot(previous.bytes));
  });

  test('镜像推送按节流合并，流式 token 不会逐条发消息', () async {
    final h = _Harness(pushInterval: const Duration(milliseconds: 30));
    addTearDown(h.dispose);
    final image = await AiImage.fromBytes('shot.png', base64Decode(png));
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('看图', user: true, images: [image]));
    await h.host.open('s1');
    expect((h.pushes.single['images'] as Map).length, 1);

    h.task.entries.add(AiTaskEntry(''));
    for (var token = 0; token < 5; token++) {
      h.task.entries.last.text += '字';
      h.task.poke();
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(h.pushes, hasLength(2), reason: '连续 token 合并成一次推送');
    expect(h.pushes.last['reset'], isFalse);
    expect(h.pushes.last['images'], isEmpty);
    expect((h.pushes.last['entries'] as Map).keys, ['1']);
  });

  test('API Key 与提供方配置不出主窗口', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('你好', user: true));
    await h.host.open('s1');
    await h.remote.initialize();

    expect(jsonEncode(h.pushes.last), isNot(contains('sk-secret')));
    expect(h.remote.settings().apiKey, isEmpty);
    expect(h.remote.settings().profiles, isEmpty);
    expect(h.remote.settings().baseUrl, 'https://ai.example.com/v1');
    expect(h.remote.settings().model, 'model-x');
    expect(h.remote.settings().configured, isTrue);

    h.task.config = const AiSettings(
      baseUrl: 'https://other.example.com/v1',
      apiKey: 'sk-other',
      model: 'model-z',
      provider: 'openai',
      protocol: AiProtocol.anthropic,
      systemPrompt: 'supplement-never-mirrored',
      mcpServers: [
        AiMcpServer(
          id: 'mcp-github',
          name: 'github',
          url: 'https://mcp.example.com/mcp',
          headers: {'Authorization': 'Bearer mcp-github-secret'},
        ),
      ],
    );
    h.host.refresh();
    await h.settle();
    expect(h.remote.activeModel, 'model-z');
    expect(h.remote.settings().protocol, AiProtocol.anthropic);
    expect(h.remote.settings().apiKey, isEmpty);
    expect(h.remote.settings().mcpServers, isEmpty);
    expect(jsonEncode(h.pushes.last), isNot(contains('sk-other')));
    expect(jsonEncode(h.pushes.last), isNot(contains('mcp-github-secret')));
    expect(
      jsonEncode(h.pushes.last),
      isNot(contains('supplement-never-mirrored')),
    );
  });

  test('切换会话不串线，迟到的旧会话结果被丢弃', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final other = _TestTask();
    addTearDown(other.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.host.register('s2', other, '测试服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('s1 的对话', user: true));
    other.entries.add(AiTaskEntry('s2 的对话', user: true));

    await h.host.open('s1');
    await h.remote.initialize();
    expect(h.remote.sessionId, 's1');
    expect(h.remote.hostName, '生产服务器');

    // A preview that is still in flight while the window moves to s2.
    final gate = h.task.previewGate = Completer<void>();
    final pending = h.remote.previewConversation('c1');
    await h.host.open('s2');
    await h.settle();
    expect(h.remote.sessionId, 's2');
    expect(h.remote.hostName, '测试服务器');
    expect(h.remote.entries.single.text, 's2 的对话');
    gate.complete();
    expect(await pending, isNull, reason: '旧会话的迟到预览不再生效');
    expect(h.remote.entries.single.text, 's2 的对话');
    expect(h.host.isDetached('s1'), isFalse);
    expect(h.remote.settings().model, 'model-x');
  });

  test('主引擎侧丢弃旧会话的迟到回复，只回当前会话状态', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final other = _TestTask();
    addTearDown(other.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.host.register('s2', other, '测试服务器', onDock: h.dock);
    other.entries.add(AiTaskEntry('s2 的对话', user: true));
    await h.host.open('s1');

    final gate = h.task.previewGate = Completer<void>();
    final pending = h.host.handle(
      const MethodCall('action', <String, Object?>{
        'sessionId': 's1',
        'op': AiWindowOp.previewConversation,
        'args': <String, Object?>{'id': 'c1'},
      }),
    );
    await h.host.open('s2');
    gate.complete();
    final reply = await pending as Map;
    expect((reply['state'] as Map)['sessionId'], 's2');
    expect(h.host.isDetached('s2'), isTrue);
  });

  test('会话关闭时窗口收到 closed 并隐藏，不误导调用回嵌', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task
      ..entries.add(AiTaskEntry('进行中', user: true))
      ..running = true;
    await h.host.open('s1');
    await h.remote.initialize();
    expect(h.remote.running, isTrue);

    h.host.unregister('s1');
    await h.settle();
    expect(h.hides, 1);
    expect(h.docks, 0, reason: '会话结束不是用户回嵌');
    expect(h.remote.sessionId, isNull);
    expect(h.remote.running, isFalse);
    expect(h.remote.entries, isEmpty);
    expect(h.remote.status, contains('会话已关闭'));
    expect(h.host.isDetached('s1'), isFalse);
    expect(h.task.stopCount, 0);
  });

  test('关闭独立窗口不停止任务，未知会话的动作被拒绝', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task
      ..entries.add(AiTaskEntry('进行中', user: true))
      ..running = true;
    await h.host.open('s1');
    await h.remote.initialize();

    h.remote.dispose();
    await h.settle();
    expect(h.task.stopCount, 0, reason: '窗口销毁不能停止主引擎任务');
    expect(h.task.running, isTrue);

    await expectLater(
      h.host.handle(
        const MethodCall('action', <String, Object?>{
          'sessionId': 'gone',
          'op': AiWindowOp.stop,
          'args': <String, Object?>{},
        }),
      ),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'session'),
      ),
    );
    expect(h.task.stopCount, 0);
  });

  test('窗口创建失败时保持内嵌且不推送镜像', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.failOpen = true;
    await h.host.open('s1');
    expect(h.openCount, 0);
    expect(h.host.isDetached('s1'), isFalse);
    expect(h.pushes, isEmpty);
    h.failOpen = false;
    await h.host.open('s1');
    expect(h.host.isDetached('s1'), isTrue);
    expect(h.pushes, hasLength(1));
  });

  test('切换独立窗口交还上一个面板，创建失败则保持原窗口', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final second = _TestTask();
    addTearDown(second.dispose);
    var firstDocks = 0;
    var secondDocks = 0;
    h.host.register('s1', h.task, '甲', onDock: () => firstDocks++);
    h.host.register('s2', second, '乙', onDock: () => secondDocks++);

    await h.host.open('s1');
    expect(h.host.isDetached('s1'), isTrue);
    expect(firstDocks, 0);

    h.failOpen = true;
    await h.host.open('s2');
    expect(h.host.isDetached('s1'), isTrue, reason: '创建失败不能抢走已经显示的会话');
    expect(h.host.isDetached('s2'), isFalse);
    expect(firstDocks, 0);
    expect(h.task.stopCount, 0);

    h.failOpen = false;
    await h.host.open('s2');
    expect(h.host.isDetached('s2'), isTrue);
    expect(h.host.isDetached('s1'), isFalse);
    expect(firstDocks, 1, reason: '新窗口打开后，上一个面板回到主窗口');
    expect(secondDocks, 0);
    expect(h.task.stopCount, 0);
    expect(second.stopCount, 0);

    await h.host.dock('s2');
    expect(secondDocks, 1);
    expect(h.hides, 1);
    expect(h.host.isDetached('s2'), isFalse);
    expect(second.stopCount, 0, reason: '从主窗口收回不停止任务');
  });

  testWidgets('同一面板在独立窗口内用代理控制器渲染并转发审批与发送', (tester) async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task.entries.add(AiTaskEntry('已连接生产服务器', user: true));
    h.task.entries.add(AiTaskEntry('准备就绪'));
    h.task.entries.add(
      AiTaskEntry('''用 `bash` 运行：

```bash
bash deploy-marzban.sh 1
```

| 命令 | 作用 |
| --- | --- |
| `bash deploy-marzban.sh 1` | 安装主面板 |
'''),
    );
    await h.host.open('s1');
    await h.remote.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: h.remote, hostName: h.remote.hostName),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已连接生产服务器'), findsOneWidget);
    expect(find.text('准备就绪'), findsOneWidget);
    expect(find.byType(AiMarkdownCodeBlock), findsOneWidget);
    expect(find.text('Bash'), findsOneWidget);
    expect(find.byType(AiMarkdownTable), findsOneWidget);
    expect(find.text('命令'), findsOneWidget);
    expect(find.text('作用'), findsOneWidget);
    expect(find.text('安装主面板'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('ai-task-input')));
    await tester.enterText(
      find.byKey(const ValueKey('ai-task-input')),
      '查看磁盘占用',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('ai-send')));
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pumpAndSettle();
    expect(h.task.calls, contains('start:查看磁盘占用'));

    // The approval card of the main engine renders in the detached panel too.
    h.task.pending = const AiToolCall('c1', 'rm /tmp/x', '将删除临时文件', true);
    h.task.status = '等待确认';
    h.task.poke();
    await tester.pumpAndSettle();
    expect(find.text('rm /tmp/x'), findsWidgets);
    await tester.ensureVisible(find.text('批准并执行'));
    await tester.tap(find.text('批准并执行'));
    await tester.pumpAndSettle();
    expect(h.task.approved, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('独立窗口可切换到从未打开 AI 的 SSH，切换不停止原任务', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final other = _TestTask();
    addTearDown(other.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.task
      ..entries.add(AiTaskEntry('s1 的对话', user: true))
      ..running = true;
    final created = <String>{'s1'};
    h.sessions = () => const [
      AiWindowSession(
        id: 's1',
        hostName: '生产服务器',
        endpoint: 'a.example:22',
        connected: true,
        running: true,
      ),
      AiWindowSession(
        id: 's2',
        hostName: '测试服务器',
        endpoint: 'b.example:22',
        connected: true,
      ),
    ];
    h.ensure = (id) async {
      if (id == 's2' && created.add(id)) {
        h.host.register('s2', other, '测试服务器', onDock: h.dock);
      }
      return created.contains(id);
    };
    h.bindSessions();

    await h.host.open('s1');
    await h.remote.initialize();
    expect(h.remote.sessions.map((s) => s.id), ['s1', 's2']);
    expect(h.remote.selectingSession, isFalse);

    expect(await h.remote.selectSession('s2'), isTrue);
    expect(h.remote.sessionId, 's2');
    expect(h.remote.hostName, '测试服务器');
    expect(h.remote.selectingSession, isFalse);
    expect(h.task.stopCount, 0, reason: '切到 B 不停止 A 的运行中任务');
    expect(h.task.running, isTrue);
    expect(h.host.isDetached('s1'), isFalse);
    expect(h.host.isDetached('s2'), isTrue);

    // A user action in the window now lands on B only.
    await h.remote.start('只在 B 上执行');
    await h.settle();
    expect(other.calls, contains('start:只在 B 上执行'));
    expect(h.task.calls, isNot(contains('start:只在 B 上执行')));
    expect(other.stopCount, 0);
  });

  test('重连后的主机名会更新独立窗口标题', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '旧名称', onDock: h.dock);
    await h.host.open('s1');
    await h.remote.initialize();
    expect(h.remote.hostName, '旧名称');
    h.host.register('s1', h.task, '新名称', onDock: h.dock);
    await h.settle();
    expect(h.remote.hostName, '新名称');
    expect(h.remote.sessionId, 's1');
  });

  test('目录随会话打开、关闭与后台任务状态更新', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final background = _TestTask();
    addTearDown(background.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.host.register('s2', background, '测试服务器', onDock: h.dock);
    var connected = true;
    var secondOpen = false;
    h.sessions = () => [
      AiWindowSession(
        id: 's1',
        hostName: '生产服务器',
        endpoint: 'a.example:22',
        connected: connected,
        running: h.task.running,
      ),
      if (secondOpen)
        AiWindowSession(
          id: 's2',
          hostName: '测试服务器',
          endpoint: 'b.example:22',
          connected: true,
          running: background.running,
        ),
    ];
    h.bindSessions();

    await h.host.open('s1');
    await h.remote.initialize();
    expect(h.remote.sessions.map((s) => s.id), ['s1']);

    // A second SSH session is opened in the main window.
    secondOpen = true;
    h.host.refreshSessions();
    await h.settle();
    expect(h.remote.sessions.map((s) => s.id), ['s1', 's2']);

    // Its turn state changes: the window mirrors another session, yet the
    // directory is refreshed.
    background.running = true;
    background.poke();
    await h.settle();
    expect(
      h.remote.sessions.firstWhere((s) => s.id == 's2').running,
      isTrue,
      reason: '非 active 任务状态变化也会推送目录',
    );

    // The mirrored SSH session disconnects.
    connected = false;
    h.host.refreshSessions();
    await h.settle();
    expect(h.remote.sessions.first.connected, isFalse);

    // s2 closes: it leaves the directory.
    secondOpen = false;
    h.host.refreshSessions();
    await h.settle();
    expect(h.remote.sessions.map((s) => s.id), ['s1']);
  });

  test('迟到的选择不会把窗口拖回旧会话', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final second = _TestTask();
    addTearDown(second.dispose);
    h.host.register('s1', h.task, '甲', onDock: h.dock);
    h.host.register('s2', second, '乙', onDock: h.dock);
    h.sessions = () => const [
      AiWindowSession(
        id: 's1',
        hostName: '甲',
        endpoint: 'a:22',
        connected: true,
      ),
      AiWindowSession(
        id: 's2',
        hostName: '乙',
        endpoint: 'b:22',
        connected: true,
      ),
      AiWindowSession(
        id: 's3',
        hostName: '丙',
        endpoint: 'c:22',
        connected: true,
      ),
    ];
    h.bindSessions();
    await h.host.open('s1');
    await h.remote.initialize();
    // The main window already moved on to s2 (another pane detached it).
    await h.host.open('s2');

    // A select that still believes it is on s1 must be rejected.
    final stale = await h.host.handle(
      const MethodCall('action', <String, Object?>{
        'sessionId': 's1',
        'generation': 1,
        'op': AiWindowOp.openSession,
        'args': <String, Object?>{'id': 's3'},
      }),
    ) as Map;
    expect(stale.containsKey('result'), isFalse);
    expect((stale['state'] as Map)['sessionId'], 's2');
    expect(h.host.isDetached('s2'), isTrue);
    expect(h.host.isDetached('s1'), isFalse);

    // A stale generation of the current session is rejected too.
    final wrongGeneration = await h.host.handle(
      const MethodCall('action', <String, Object?>{
        'sessionId': 's2',
        'generation': 999,
        'op': AiWindowOp.openSession,
        'args': <String, Object?>{'id': 's3'},
      }),
    ) as Map;
    expect(wrongGeneration.containsKey('result'), isFalse);
    expect(h.host.isDetached('s2'), isTrue);
    expect(h.host.isDetached('s3'), isFalse);
  });

  test('会话目录只镜像凭据无关的字段', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.host.register('s1', h.task, '生产服务器', onDock: h.dock);
    h.sessions = () => const [
      AiWindowSession(
        id: 's1',
        hostName: '生产服务器',
        endpoint: 'a.example:22',
        connected: true,
        running: true,
        waitingApproval: true,
      ),
    ];
    h.bindSessions();
    await h.host.open('s1');
    await h.remote.initialize();

    final rows = h.pushes.last['sessions'] as List;
    expect(rows, hasLength(1));
    expect((rows.single as Map).keys.toSet(), {
      'id',
      'hostName',
      'endpoint',
      'connected',
      'running',
      'waitingApproval',
    });
    expect(jsonEncode(rows), isNot(contains('sk-secret')));
    expect(jsonEncode(rows), isNot(contains('password')));
    expect(h.remote.sessions.single.waitingApproval, isTrue);
  });

  test('独立窗口改思考等级落在真实主控制器并进入下一次请求与快照', () async {
    // This suite runs under TestWidgetsFlutterBinding, whose mock HttpClient
    // answers every request with 400. This flow must reach a real loopback
    // server, so lift that override for this test only.
    final httpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = httpOverrides);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      bodies.add(body);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': bodies.length == 1
                  ? {
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
                    }
                  : {'role': 'assistant', 'content': '检查完成'},
            },
          ],
        }),
      );
      await request.response.close();
    });

    final executor = _RecordingExecutor();
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'sk-window-secret',
        model: 'window-model',
      ),
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: TerminalAiClient.new,
    );
    final host = AiWindowHost(
      appearance: () => const AppearancePreferences(),
      pushInterval: Duration.zero,
    );
    final remote = RemoteAiTaskController();
    final pushes = <Map<Object?, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Future<void> deliver(Object? payload) => messenger.handlePlatformMessage(
      aiWindowChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('changed', payload),
      ),
      null,
    );
    messenger.setMockMethodCallHandler(aiWindowChannel, (call) async {
      switch (call.method) {
        case 'open':
        case 'hide':
          return null;
        case 'changed':
          final payload = Map<Object?, Object?>.from(call.arguments as Map);
          pushes.add(payload);
          unawaited(deliver(payload));
          return null;
        default:
          return host.handle(call);
      }
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(aiWindowChannel, null);
      remote.dispose();
      host.dispose();
      task.dispose();
    });
    Future<void> settle() async {
      for (var round = 0; round < 8; round++) {
        await Future<void>.delayed(Duration.zero);
      }
      await remote.applied;
    }

    host.register('s1', task, '生产服务器', onDock: () {});
    await host.open('s1');
    await remote.initialize();
    expect(remote.reasoningEffort, AiReasoningEffort.automatic);
    expect(task.reasoningEffort, AiReasoningEffort.automatic);

    // The detached window's slider forwards to the one main-engine task.
    remote.setReasoningEffort(AiReasoningEffort.xhigh);
    await settle();
    expect(task.reasoningEffort, AiReasoningEffort.xhigh);
    expect(remote.reasoningEffort, AiReasoningEffort.xhigh);
    expect(
      (pushes.last['settings'] as Map)['reasoningEffort'],
      'xhigh',
      reason: '快照回显下一次请求实际使用的档位',
    );

    // The forwarded choice really reaches the provider on the next turn.
    await task.start('检查环境');
    expect(task.failure, isNull, reason: '真实回环请求必须成功');
    expect(executor.commands, ['pwd']);
    expect(bodies, hasLength(2));
    for (final body in bodies) {
      expect(body['reasoning_effort'], 'xhigh');
    }
    expect(jsonEncode(pushes.last), isNot(contains('sk-window-secret')));

    // Automatic is forwarded too and removes the field from the wire.
    remote.setReasoningEffort(AiReasoningEffort.automatic);
    await settle();
    expect(task.reasoningEffort, AiReasoningEffort.automatic);
    expect(remote.reasoningEffort, AiReasoningEffort.automatic);
    await task.start('继续检查');
    expect(bodies, hasLength(3));
    expect(bodies.last.containsKey('reasoning_effort'), isFalse);
    expect((pushes.last['settings'] as Map)['reasoningEffort'], 'automatic');
  });
}

/// Test double for the main-engine controller: records what the detached
/// window asks it to do instead of touching SSH or a model.
class _TestTask extends AiTaskController {
  factory _TestTask([
    AiSettings config = const AiSettings(
      baseUrl: 'https://ai.example.com/v1',
      apiKey: 'sk-secret',
      model: 'model-x',
    ),
  ]) {
    final holder = _Value(config);
    return _TestTask._(holder);
  }

  _TestTask._(this.holder)
    : super(
        settings: () => holder.value,
        executorFactory: () => throw const AiFailure('no executor'),
        connected: () => true,
        clientFactory: () => throw const AiFailure('no client'),
      );

  final _Value<AiSettings> holder;
  final calls = <String>[];
  int stopCount = 0;
  bool? approved;
  bool? approvedSaveForward;
  String? approvedCallId;
  List<AiImage> lastImages = const [];
  Completer<void>? previewGate;

  AiSettings get config => holder.value;
  set config(AiSettings value) => holder.value = value;

  void poke() => notifyListeners();

  @override
  Future<void> start(String goal, {List<AiImage> images = const []}) async {
    calls.add('start:$goal');
    lastImages = images;
  }

  @override
  void stop({String? message}) {
    stopCount++;
    calls.add('stop:${message ?? ''}');
    running = false;
    notifyListeners();
  }

  @override
  void approve(
    bool allowed, {
    bool saveForward = false,
    String? expectedCallId,
  }) {
    calls.add('approve:$allowed:${saveForward ? 1 : 0}:$expectedCallId');
    approved = allowed;
    approvedSaveForward = saveForward;
    approvedCallId = expectedCallId;
  }

  @override
  void setModel(String? model) => calls.add('setModel:$model');

  @override
  void setApprovalMode(AiApprovalMode mode) {
    calls.add('setApprovalMode:${mode.name}');
    approvalMode = mode;
    notifyListeners();
  }

  @override
  void setAutoApprove(bool enabled) => calls.add('setAutoApprove:$enabled');

  @override
  Future<List<String>> listModels() async {
    calls.add('listModels');
    return const ['a', 'b'];
  }

  @override
  Future<void> loadHistory() async => calls.add('loadHistory');

  @override
  Future<void> newConversation() async => calls.add('newConversation');

  @override
  Future<void> openConversation(String id) async =>
      calls.add('openConversation:$id');

  @override
  Future<void> deleteConversation(String id) async =>
      calls.add('deleteConversation:$id');

  @override
  Future<List<AiTaskEntry>?> previewConversation(String id) async {
    calls.add('previewConversation:$id');
    final gate = previewGate;
    if (gate != null) await gate.future;
    return [AiTaskEntry('预览内容', user: true)];
  }
}

class _Value<T> {
  _Value(this.value);
  T value;
}

/// Loopback of the native relay: host -> native calls are recorded, child ->
/// native calls are answered by the host and mirrors are relayed back to the
/// child handler, exactly like `flutter_window.cpp`.
class _Harness {
  _Harness({this.pushInterval = Duration.zero}) {
    host = AiWindowHost(
      appearance: () => appearance,
      pushInterval: pushInterval,
    );
    task = _TestTask();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(aiWindowChannel, _relay);
  }

  final Duration pushInterval;
  late final _TestTask task;
  final remote = RemoteAiTaskController();
  final pushes = <Map<Object?, Object?>>[];
  final relay = <MethodCall>[];
  AppearancePreferences appearance = const AppearancePreferences();
  late final AiWindowHost host;
  bool failOpen = false;
  int openCount = 0;
  int hides = 0;
  int docks = 0;

  /// Session directory the host reads, as [TerminalWorkspace] supplies it.
  List<AiWindowSession> Function() sessions = () => const [];

  /// Lazily materializes a session that never opened the assistant.
  Future<bool> Function(String sessionId) ensure = (_) async => false;

  void bindSessions() => host.bindSessions(catalog: sessions, ensure: ensure);

  void dock() => docks++;

  Future<void> deliver(Object? payload) => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        aiWindowChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('changed', payload),
        ),
        null,
      );

  Future<Object?> _relay(MethodCall call) async {
    relay.add(call);
    switch (call.method) {
      case 'open':
        if (failOpen) {
          throw PlatformException(code: 'window', message: '无法创建 AI 窗口');
        }
        openCount++;
        return null;
      case 'hide':
        hides++;
        return null;
      case 'changed':
        final payload = Map<Object?, Object?>.from(call.arguments as Map);
        pushes.add(payload);
        unawaited(deliver(payload));
        return null;
      default:
        return host.handle(call);
    }
  }

  /// Lets queued mirror work (listener pushes, relayed payloads) settle.
  Future<void> settle() async {
    for (var index = 0; index < 6; index++) {
      await Future<void>.delayed(Duration.zero);
    }
    await remote.applied;
  }

  void dispose() {
    remote.dispose();
    host.dispose();
    task.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(aiWindowChannel, null);
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
