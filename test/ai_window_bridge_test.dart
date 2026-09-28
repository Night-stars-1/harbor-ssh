import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/ai_window_bridge.dart';
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
    h.remote.approve(true);
    await h.settle();
    expect(h.task.approved, isTrue);

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
    );
    h.host.refresh();
    await h.settle();
    expect(h.remote.activeModel, 'model-z');
    expect(h.remote.settings().protocol, AiProtocol.anthropic);
    expect(h.remote.settings().apiKey, isEmpty);
    expect(jsonEncode(h.pushes.last), isNot(contains('sk-other')));
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
  void approve(bool allowed) {
    calls.add('approve:$allowed');
    approved = allowed;
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
