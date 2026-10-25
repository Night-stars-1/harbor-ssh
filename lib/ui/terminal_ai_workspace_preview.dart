import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../data/terminal_ai.dart';
import 'ai_task_controller.dart';
import 'ai_window_session.dart';
import 'terminal_ai_panel.dart';
import 'theme.dart';

/// Previews for the standalone AI workbench — the layout [TerminalAiPanel]
/// renders when it is given an `onDock` callback (the detached window).
///
/// The panel is driven by a real controller with a preview-only model catalog.
/// No network, SSH session or history store is used, and command execution is
/// disabled. The controller is disposed when the preview is removed.

AiTaskController _task({bool configured = true}) => AiTaskController(
  settings: () => configured
      ? const AiSettings(
          baseUrl: 'https://ai.example.com/v1',
          model: 'gpt-5-mini',
        )
      : const AiSettings(),
  executorFactory: () => throw const AiFailure('预览不执行命令'),
  connected: () => false,
  clientFactory: _PreviewClient.new,
);

class _PreviewClient extends TerminalAiClient {
  @override
  Future<List<String>> listModels(AiSettings settings) async => const [
    'gpt-5-mini',
    'workspace-model',
  ];
}

/// A finished turn with a tool call, so the transcript and the activity strip
/// both have something to render.
void _fillTranscript(AiTaskController task) {
  task.entries.addAll([
    AiTaskEntry('检查磁盘空间，找出占用最大的目录', user: true),
    AiTaskEntry('df -h', command: true)
      ..reason = '查看文件系统使用情况'
      ..output =
          'Filesystem  Size  Used Avail Use%\n'
          '/dev/vda1    80G   52G   28G  65%'
      ..exitCode = 0
      ..finished = true,
    AiTaskEntry(
      '磁盘已使用 **65%**，剩余 **28 GB**。\n\n'
      '建议先检查日志目录和应用缓存，再决定是否清理。\n\n'
      '```bash\ndu -h --max-depth=1 /var/log\n```',
      model: 'gpt-5-mini',
    ),
  ]);
}

Widget _workbench({
  required Brightness brightness,
  required double textScale,
  bool configured = true,
  void Function(AiTaskController task)? scene,
}) => _WorkbenchPreview(
  brightness: brightness,
  textScale: textScale,
  configured: configured,
  scene: scene,
);

/// Two sample hosts the preview may switch between. Nothing here touches SSH,
/// a network or the app's real session catalog.
const _previewSessions = <AiWindowSession>[
  AiWindowSession(
    id: 'preview-a',
    hostName: '生产服务器',
    endpoint: 'ubuntu-01 · 10.0.0.11',
    connected: true,
    running: true,
  ),
  AiWindowSession(
    id: 'preview-b',
    hostName: '测试服务器',
    endpoint: 'debian-02 · 10.0.0.12',
    connected: true,
  ),
];

/// Preview-only session selection: it mirrors the detached window's contract
/// with an in-memory list, so the workbench's switcher and per-session drafts
/// can be previewed without a real SSH session or the main engine.
class _PreviewSessions implements AiWindowSessionSelection {
  _PreviewSessions(this.sessions, this._sessionId);

  @override
  final List<AiWindowSession> sessions;

  String? _sessionId;
  bool _selecting = false;
  void Function()? onChanged;

  @override
  String? get sessionId => _sessionId;

  @override
  bool get selectingSession => _selecting;

  @override
  Future<bool> selectSession(String id) async {
    if (id == _sessionId || _selecting) return true;
    _selecting = true;
    onChanged?.call();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _sessionId = id;
    _selecting = false;
    onChanged?.call();
    return true;
  }
}

class _WorkbenchPreview extends StatefulWidget {
  const _WorkbenchPreview({
    required this.brightness,
    required this.textScale,
    required this.configured,
    this.scene,
  });

  final Brightness brightness;
  final double textScale;
  final bool configured;
  final void Function(AiTaskController task)? scene;

  @override
  State<_WorkbenchPreview> createState() => _WorkbenchPreviewState();
}

class _WorkbenchPreviewState extends State<_WorkbenchPreview> {
  late final task = _task(configured: widget.configured);
  late final selection = _PreviewSessions(
    _previewSessions,
    _previewSessions.first.id,
  );
  final _drafts = <String, AiPanelDraft>{};

  @override
  void initState() {
    super.initState();
    widget.scene?.call(task);
    selection.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    task.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = selection.sessionId!;
    final session = selection.sessions.firstWhere(
      (item) => item.id == sessionId,
      orElse: () => selection.sessions.first,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: harborTheme(brightness: widget.brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(widget.textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: TerminalAiPanel(
          key: ValueKey('ai-workbench-$sessionId'),
          task: task,
          hostName: session.hostName,
          sessionSelection: selection,
          draft: _drafts[sessionId],
          onDraftChanged: (draft) => _drafts[sessionId] = draft,
          onSettings: () {},
          onDock: () {},
        ),
      ),
    );
  }
}

@Preview(
  name: 'AI 工作台 · 对话 · 1200',
  group: 'Harbor SSH · AI',
  size: Size(1200, 820),
)
Widget aiWorkbenchTranscriptPreview() => _workbench(
  brightness: Brightness.light,
  textScale: 1,
  scene: _fillTranscript,
);

@Preview(
  name: 'AI 工作台 · 空态 · 560',
  group: 'Harbor SSH · AI',
  size: Size(560, 820),
)
Widget aiWorkbenchEmptyPreview() =>
    _workbench(brightness: Brightness.light, textScale: 1);

@Preview(
  name: 'AI 工作台 · 审批 · 480 2x',
  group: 'Harbor SSH · AI',
  size: Size(480, 520),
)
Widget aiWorkbenchApprovalPreview() => _workbench(
  brightness: Brightness.light,
  textScale: 2,
  scene: (task) {
    _fillTranscript(task);
    task
      ..running = true
      ..status = '等待确认'
      ..pending = const AiToolCall(
        'preview-approval',
        'rm -- /tmp/harbor-preview.log',
        '删除临时日志文件，此操作需要你的确认。',
        true,
      );
  },
);

@Preview(
  name: 'AI 工作台 · 运行中 · 1200 深色',
  group: 'Harbor SSH · AI',
  size: Size(1200, 820),
)
Widget aiWorkbenchRunningDarkPreview() => _workbench(
  brightness: Brightness.dark,
  textScale: 1,
  scene: (task) {
    _fillTranscript(task);
    task
      ..running = true
      ..status = '正在分析目录占用'
      ..turnStartedAt = DateTime.now();
  },
);

@Preview(
  name: 'AI 工作台 · 本地转发审批 · 560',
  group: 'Harbor SSH · AI',
  size: Size(560, 720),
)
Widget aiWorkbenchForwardApprovalPreview() => _workbench(
  brightness: Brightness.light,
  textScale: 1,
  scene: (task) {
    _fillTranscript(task);
    task
      ..running = true
      ..status = '等待确认'
      ..pending = AiToolCall(
        'preview-forward',
        '本地端口转发：127.0.0.1:8080 → 服务器侧 127.0.0.1:80',
        'AI 请求在你的电脑上建立到服务器的本地端口转发。',
        true,
        name: 'create_port_forward',
        arguments: const {
          'name': 'web',
          'local_port': 8080,
          'target_host': '127.0.0.1',
          'target_port': 80,
          'reason': '访问内网管理页',
        },
      );
  },
);

@Preview(
  name: 'AI 工作台 · MCP 工具审批 · 560',
  group: 'Harbor SSH · AI',
  size: Size(560, 720),
)
Widget aiWorkbenchMcpApprovalPreview() => _workbench(
  brightness: Brightness.dark,
  textScale: 1,
  scene: (task) {
    _fillTranscript(task);
    task
      ..running = true
      ..status = '等待确认'
      ..pending = AiToolCall(
        'preview-mcp',
        'MCP「GitHub」调用工具 search_issues',
        'AI 请求调用 MCP 服务器上的工具，参数如下。',
        true,
        name: 'search_issues',
        arguments: const {
          'query': 'repo:flutter/flutter is:issue is:open',
          'limit': 5,
        },
      );
  },
);

@Preview(
  name: 'AI 工作台 · 未配置 · 480',
  group: 'Harbor SSH · AI',
  size: Size(480, 520),
)
Widget aiWorkbenchUnconfiguredPreview() =>
    _workbench(brightness: Brightness.light, textScale: 1, configured: false);
