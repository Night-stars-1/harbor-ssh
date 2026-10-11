import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/ai_image_input.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/ai_window_session.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';

/// 1×1 PNG：附件持久性测试用的最小合法图片。
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

const _configured = AiSettings(
  baseUrl: 'https://ai.example.com/v1',
  model: 'test',
);

/// 独立窗口尺寸覆盖：窄而矮、窄而高、桌面宽屏，最后回到初始尺寸验证往返。
const _sizes = [
  Size(480, 520),
  Size(560, 820),
  Size(1200, 820),
  Size(480, 520),
];

void main() {
  testWidgets('独立窗口 480x520–1200x820 缩放保留草稿与附件，输入和发送始终可点', (tester) async {
    _useSize(tester, const Size(480, 520));
    final task = _task(_Client());
    addTearDown(task.dispose);
    await _pump(tester, task, imageInput: _Input());
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('ai-task-input'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '检查磁盘空间');
    await tester.pump();
    await _pick(tester);
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);

    final send = find.byKey(const ValueKey('ai-send'));
    for (final size in _sizes) {
      _resize(tester, size);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<TextField>(field).controller!.text, '检查磁盘空间');
      expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-history')), findsWidgets);
      expect(field.hitTestable(), findsOneWidget);
      expect(send.hitTestable(), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长对话滚动后输入区仍可用', (tester) async {
    _useSize(tester, const Size(480, 520));
    final task = _task(_Client());
    addTearDown(task.dispose);
    await _pump(tester, task);
    await tester.pumpAndSettle();

    for (var i = 0; i < 40; i++) {
      task.entries.add(AiTaskEntry('第 $i 条消息，用于撑长对话内容', user: i.isEven));
    }
    task.refresh();
    await tester.pumpAndSettle();

    final transcript = find.byKey(const ValueKey('ai-transcript'));
    expect(transcript, findsOneWidget);
    await tester.drag(transcript, const Offset(0, -800));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('ai-task-input'));
    final send = find.byKey(const ValueKey('ai-send'));
    expect(field.hitTestable(), findsOneWidget);
    expect(send.hitTestable(), findsOneWidget);
    await tester.enterText(field, '继续排查');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '继续排查');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final approve in [false, true]) {
    testWidgets('独立窗口 480x520 2x 审批态可滚动到${approve ? '批准' : '取消'}并操作', (
      tester,
    ) async {
      _useSize(tester, const Size(480, 520));
      final executor = _Executor();
      final task = AiTaskController(
        settings: () => _configured,
        executorFactory: () => executor,
        connected: () => true,
        clientFactory: _ApprovalClient.new,
      );
      addTearDown(task.dispose);
      await _pump(tester, task, scale: 2);
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('ai-task-input'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '清理测试文件');
      await tester.pump();
      final send = find.byKey(const ValueKey('ai-send'));
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(task.pending, isNotNull);

      final target = find.text(approve ? '批准并执行' : '取消');
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target, findsOneWidget);
      expect(target.hitTestable(), findsOneWidget);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(task.running, isFalse);
      if (approve) {
        expect(executor.calls, 1);
      } else {
        expect(executor.calls, 0);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('独立窗口消息左右分栏且限宽', (tester) async {
    _useSize(tester, const Size(1200, 820));
    final task = _task(_Client());
    addTearDown(task.dispose);
    final user = AiTaskEntry('检查磁盘空间，找出占用最大的目录，并给出清理建议', user: true);
    final assistant = AiTaskEntry('好的，我先查看文件系统的使用情况，再给出清理建议。', model: 'test');
    task.entries
      ..add(user)
      ..add(assistant);
    await _pump(tester, task);
    await tester.pumpAndSettle();

    final transcript = tester.getRect(
      find.byKey(const ValueKey('ai-transcript')),
    );
    // 气泡外层 widget 与内部 Material 共用 ObjectKey，按 Material 唯一定位。
    final userRect = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.key == ObjectKey(user),
      ),
    );
    final assistantRect = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is Material && widget.key == ObjectKey(assistant),
      ),
    );

    // 用户气泡不超过 480，AI 气泡不超过 640。
    expect(userRect.width, lessThanOrEqualTo(480 + 0.5));
    expect(assistantRect.width, lessThanOrEqualTo(640 + 0.5));
    // 用户贴右、AI 贴左，各自停在聊天区的内边距上。
    expect(userRect.right, closeTo(transcript.right - 20, 0.5));
    expect(assistantRect.left, closeTo(transcript.left + 20, 0.5));
    expect(userRect.center.dx, greaterThan(assistantRect.center.dx));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('独立窗口 A/B/A 切换各自保留草稿与附件', (tester) async {
    _useSize(tester, const Size(1200, 820));
    final task = _task(_Client());
    addTearDown(task.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: _Harness(task: task),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('ai-task-input'));
    await tester.enterText(field, 'A 的草稿');
    await tester.pump();
    await _pick(tester);
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-session-b')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsNothing);

    await tester.enterText(field, 'B 的草稿');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ai-session-a')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'A 的草稿');
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-session-b')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'B 的草稿');
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宽窗与窄窗都能切换 SSH 会话', (tester) async {
    _useSize(tester, const Size(1200, 820));
    final task = _task(_Client());
    addTearDown(task.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: _Harness(task: task),
      ),
    );
    await tester.pumpAndSettle();

    final railTile = find.byKey(const ValueKey('ai-session-a'));
    expect(railTile, findsOneWidget);
    expect(railTile.hitTestable(), findsOneWidget);

    _resize(tester, const Size(480, 520));
    await tester.pumpAndSettle();
    expect(railTile, findsNothing);

    final menu = find.byKey(const ValueKey('ai-session-menu'));
    expect(menu, findsOneWidget);
    expect(menu.hitTestable(), findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-session-menu-b')));
    await tester.pumpAndSettle();

    expect(find.textContaining('服务器 B'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切到运行中的其他会话不会清掉原会话草稿', (tester) async {
    _useSize(tester, const Size(1200, 820));
    final task = _task(_Client());
    addTearDown(task.dispose);
    final selection = _TestSelection(_testSessions, 'a', () {});
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(
            key: const ValueKey('panel-a'),
            task: task,
            hostName: '服务器 A',
            onDock: () {},
            sessionSelection: selection,
            draft: const AiPanelDraft(),
            onDraftChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('ai-task-input'));
    await tester.enterText(field, 'A 的草稿');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'A 的草稿');

    // 主引擎已切到 B 且 B 正在运行，但面板仍停留在 A：这一次通知不能清掉 A
    // 的草稿（只有 root 重建后新面板才代表 B）。
    selection.moveTo('b');
    task.running = true;
    task.refresh();
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'A 的草稿');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切回已运行的会话并恢复草稿后，同会话通知不清草稿', (tester) async {
    _useSize(tester, const Size(1200, 820));
    final task = _task(_Client());
    addTearDown(task.dispose);
    final selection = _TestSelection(_testSessions, 'a', () {});
    // A 的任务仍在运行，用户切回来：面板带着已保存的草稿重建。
    task.running = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(
            key: const ValueKey('panel-a'),
            task: task,
            hostName: '服务器 A',
            onDock: () {},
            sessionSelection: selection,
            draft: const AiPanelDraft(text: TextEditingValue(text: 'A 的草稿')),
            onDraftChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('ai-task-input'));
    expect(tester.widget<TextField>(field).controller!.text, 'A 的草稿');

    // 同一会话的镜像通知：运行中不等于新的 turn 开始，草稿必须保持。
    task.refresh();
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'A 的草稿');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 独立窗口 root 的最小复刻：按 sessionId 重建面板，草稿存在按会话索引的
/// Map 里。测试只观察用户可见行为（草稿/附件是否各自保留）。
class _Harness extends StatefulWidget {
  const _Harness({required this.task});

  final AiTaskController task;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final _drafts = <String, AiPanelDraft>{};
  late final _selection = _TestSelection(_testSessions, 'a', () {
    if (mounted) setState(() {});
  });

  @override
  Widget build(BuildContext context) {
    final id = _selection.sessionId!;
    return Scaffold(
      body: TerminalAiPanel(
        key: ValueKey('panel-$id'),
        task: widget.task,
        hostName: _testSessions
            .firstWhere((session) => session.id == id)
            .hostName,
        imageInput: _Input(),
        onDock: () {},
        sessionSelection: _selection,
        draft: _drafts[id],
        onDraftChanged: (draft) => _drafts[id] = draft,
      ),
    );
  }
}

const _testSessions = <AiWindowSession>[
  AiWindowSession(
    id: 'a',
    hostName: '服务器 A',
    endpoint: 'a · 10.0.0.1',
    connected: true,
  ),
  AiWindowSession(
    id: 'b',
    hostName: '服务器 B',
    endpoint: 'b · 10.0.0.2',
    connected: true,
  ),
];

class _TestSelection implements AiWindowSessionSelection {
  _TestSelection(this.sessions, this._sessionId, this.onChanged);

  @override
  final List<AiWindowSession> sessions;
  String? _sessionId;
  final void Function() onChanged;

  @override
  String? get sessionId => _sessionId;

  @override
  bool get selectingSession => false;

  /// Moves the selection without notifying, so a test can reproduce the window
  /// where the engine already switched but the panel has not been rebuilt yet.
  void moveTo(String id) => _sessionId = id;

  @override
  Future<bool> selectSession(String id) async {
    _sessionId = id;
    onChanged();
    return true;
  }
}

void _useSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _resize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
}

Future<void> _pump(
  WidgetTester tester,
  AiTaskController task, {
  AiImageInput? imageInput,
  double scale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: harborTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: TerminalAiPanel(
        task: task,
        hostName: '开发服务器',
        onDock: () {},
        imageInput: imageInput,
      ),
    ),
  ),
);

Future<void> _pick(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('ai-add-image')));
  final button = tester.widget<IconButton>(
    find.byKey(const ValueKey('ai-add-image')),
  );
  await tester.runAsync(() async => await (button.onPressed as dynamic)());
  await tester.pumpAndSettle();
}

/// 只用于让测试手动注入对话内容后触发重建；notifyListeners 是受保护成员，
/// 测试不能直接调用，所以由子类公开一个安全入口。
class _Task extends AiTaskController {
  _Task(TerminalAiClient client)
    : super(
        settings: () => _configured,
        executorFactory: _Executor.new,
        connected: () => true,
        clientFactory: () => client,
      );

  void refresh() => notifyListeners();
}

_Task _task(TerminalAiClient client) => _Task(client);

class _Input implements AiImageInput {
  @override
  Future<AiImage?> clipboard() async => null;

  @override
  Future<List<AiImageSource>> pick() async => [
    AiImageSource('screenshot.png', () => Stream.value(base64Decode(_png))),
  ];
}

class _Client extends TerminalAiClient {
  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async => const AiReply({'role': 'assistant', 'content': '好的'}, []);
}

/// 首轮返回一条需要审批的命令，审批执行后第二轮返回真正的最终回复，
/// 使任务能正常结束（而不是再次进入等待确认）。
class _ApprovalClient extends TerminalAiClient {
  var _round = 0;

  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async {
    if (_round++ > 0) {
      return const AiReply({'role': 'assistant', 'content': '已完成清理。'}, []);
    }
    return const AiReply(
      {'role': 'assistant', 'content': '已定位需要清理的测试文件。'},
      [AiToolCall('1', 'rm /tmp/test-file', '此命令将删除测试文件', true)],
    );
  }
}

class _Executor implements AiCommandExecutor {
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
