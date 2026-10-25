import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_privilege.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';

const _model = 'denial-flow-model';
const _rootSecret = 'test-password';
const _rootReason = '读取 sshd 配置确认监听端口';
const _forwardReason = '访问服务器上的管理页';

const _settings = AiSettings(
  baseUrl: 'https://ai.example.com/v1',
  apiKey: 'test-key',
  model: _model,
);

AiReply _rootReply(String id, {String reason = _rootReason}) => AiReply(
  {
    'role': 'assistant',
    'content': null,
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {
          'name': aiRootToolName,
          'arguments': jsonEncode({'reason': reason}),
        },
      },
    ],
  },
  [
    AiToolCall(
      id,
      '',
      reason,
      true,
      name: aiRootToolName,
      arguments: {'reason': reason},
    ),
  ],
);

const _forwardArguments = {
  'name': '管理页',
  'local_port': 0,
  'target_host': '127.0.0.1',
  'target_port': 8080,
  'reason': _forwardReason,
};

AiReply _forwardReply(String id) => AiReply(
  {
    'role': 'assistant',
    'content': null,
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {
          'name': aiPortForwardToolName,
          'arguments': jsonEncode(_forwardArguments),
        },
      },
    ],
  },
  [
    AiToolCall(
      id,
      '',
      _forwardReason,
      true,
      name: aiPortForwardToolName,
      arguments: _forwardArguments,
    ),
  ],
);

AiReply _commandReply(String command, {String id = 'command-1'}) => AiReply(
  {
    'role': 'assistant',
    'content': null,
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {
          'name': 'run_command',
          'arguments': jsonEncode({
            'command': command,
            'reason': '确认当前身份',
          }),
        },
      },
    ],
  },
  [AiToolCall(id, command, '确认当前身份', false)],
);

AiReply _doneReply(String text) =>
    AiReply({'role': 'assistant', 'content': text}, []);

/// Scripted provider used exactly like the real client: every request the
/// controller would send is retained, so the test can inspect the tool result
/// the model actually receives after a denial.
class _ScriptedClient extends TerminalAiClient {
  _ScriptedClient(List<AiReply> replies) : _replies = [...replies];

  final List<AiReply> _replies;
  final requests = <List<Map<String, dynamic>>>[];

  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async {
    requests.add(
      (jsonDecode(jsonEncode(messages)) as List)
          .cast<Map<String, dynamic>>()
          .toList(),
    );
    if (_replies.isEmpty) throw StateError('测试模型没有更多回复');
    return _replies.removeAt(0);
  }

  @override
  void cancel() {}
}

/// Stateful executor that owns both capabilities the denial flows exercise:
/// an elevated channel and loopback port forwards.
///
/// Elevation waits on [elevateGate] when set, mirroring the real channel that
/// stays in flight until sudo answers. Revoking while in flight closes the
/// channel, so the late authentication fails instead of granting root.
class _DenialExecutor implements AiSessionExecutor, AiPrivilegeExecutor {
  final commands = <String>[];
  final executedAsRoot = <bool>[];
  final forwards = <(AiForwardRequest, bool)>[];
  final elevateAttempts = <String>[];
  Completer<void>? elevateGate;
  int revokeCalls = 0;
  bool _elevated = false;
  bool _revoked = false;
  bool _cancelled = false;

  @override
  bool get elevated => _elevated;

  @override
  String get systemContext => '主机：dev.example.com';

  @override
  Future<void> elevate(String password) async {
    elevateAttempts.add(password);
    final gate = elevateGate;
    if (gate != null) await gate.future;
    if (_revoked || _cancelled) {
      throw const AiFailure('root 授权已取消');
    }
    if (password != _rootSecret) {
      throw const AiFailure('root 授权失败');
    }
    _elevated = true;
  }

  @override
  void revokePrivilege() {
    revokeCalls++;
    _revoked = true;
    _elevated = false;
  }

  @override
  void cancel() {
    _cancelled = true;
    _elevated = false;
  }

  @override
  Future<AiForwardResult> createPortForward(
    AiForwardRequest request, {
    required bool save,
  }) async {
    forwards.add((request, save));
    return AiForwardResult(
      ruleId: 'rule-1',
      name: request.name,
      localPort: request.localPort == 0 ? 51000 : request.localPort,
      targetHost: request.targetHost,
      targetPort: request.targetPort,
      url: 'http://127.0.0.1:51000',
      saved: save,
    );
  }

  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    if (_cancelled) throw const AiFailure('任务已停止');
    commands.add(command);
    executedAsRoot.add(_elevated);
    final output = _elevated ? '0' : '1000';
    onOutput(output);
    return AiCommandResult(output, 0);
  }
}

Map<String, dynamic>? _toolResult(
  List<Map<String, dynamic>> request,
  String callId,
) {
  for (final message in request) {
    if (message['role'] != 'tool' || message['tool_call_id'] != callId) {
      continue;
    }
    return jsonDecode(message['content'] as String) as Map<String, dynamic>;
  }
  return null;
}

Map<String, dynamic>? _resultIn(
  List<List<Map<String, dynamic>>> requests,
  String callId,
) {
  for (final request in requests) {
    final result = _toolResult(request, callId);
    if (result != null) return result;
  }
  return null;
}

bool _hasPrivilegedSuccess(List<List<Map<String, dynamic>>> requests) =>
    requests.any(
      (request) => request.any(
        (message) =>
            message['role'] == 'tool' &&
            (message['content'] as String).contains('"privilege":"root"'),
      ),
    );

String _entryDump(AiTaskController task) => task.entries
    .map(
      (entry) =>
          '${entry.text}\n${entry.command}\n${entry.output}\n'
          '${entry.reason}\n${entry.interruption}',
    )
    .join('\n');

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String? reason,
}) async {
  for (var attempt = 0; attempt < 800; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: reason ?? '条件在 800 帧内未满足');
}

Future<void> _send(WidgetTester tester, String text) async {
  final input = find.byKey(const ValueKey('ai-task-input'));
  await tester.ensureVisible(input);
  await tester.enterText(input, text);
  await tester.pump();
  final send = find.byKey(const ValueKey('ai-send'));
  await tester.ensureVisible(send);
  await tester.tap(send);
  await tester.pump();
}

Finder _cardButton(String label) => find.descendant(
  of: find.byKey(const ValueKey('ai-pending-approval')),
  matching: find.widgetWithText(TextButton, label),
);

Future<void> _runRootDenial(
  WidgetTester tester, {
  required bool detached,
}) async {
  tester.view.physicalSize = const Size(340, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final client = _ScriptedClient([
    _rootReply('root-r1'),
    _commandReply('id -u'),
    _doneReply('已按普通权限继续检查。'),
    _rootReply('root-r2', reason: '再次读取系统配置'),
    _rootReply('root-r3', reason: '重新申请 root 权限'),
    _doneReply('已取消本次 root 请求。'),
    _doneReply('仍可继续对话。'),
  ]);
  final executor = _DenialExecutor();
  final task = AiTaskController(
    settings: () => _settings,
    executorFactory: () => executor,
    connected: () => true,
    clientFactory: () => client,
    approvalMode: AiApprovalMode.auto,
  );
  addTearDown(task.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: harborTheme(),
      home: Scaffold(
        body: TerminalAiPanel(
          task: task,
          hostName: '开发服务器',
          onDock: detached ? () {} : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // A root request reaches the privileged card; the user types a password and
  // then rejects the request instead of submitting it.
  await _send(tester, '确认 sshd 是否以 root 运行');
  await _pumpUntil(
    tester,
    () => task.pending?.name == aiRootToolName,
    reason: 'root 审批卡未出现',
  );
  await tester.pump();
  final password = find.byKey(const ValueKey('ai-root-password'));
  expect(password, findsOneWidget);
  await tester.enterText(password, _rootSecret);
  await tester.pump();
  final cancel = find.byKey(const ValueKey('ai-root-cancel'));
  await tester.ensureVisible(cancel);
  await tester.tap(cancel);
  await tester.pump();

  await _pumpUntil(
    tester,
    () => !task.running,
    reason: '拒绝 root 后模型没有继续到本轮结束',
  );

  // The denied call is the only thing that changed: the turn stayed alive,
  // the model got a denial for exactly that tool call and the ordinary command
  // that followed ran without elevation.
  expect(task.pending, isNull);
  expect(task.rootActive, isFalse);
  expect(task.privilegeError, isNull);
  expect(executor.elevateAttempts, isEmpty, reason: '取消前不应尝试验证密码');
  expect(executor.commands, ['id -u']);
  expect(executor.executedAsRoot, [false]);

  final denied = _toolResult(client.requests[1], 'root-r1');
  expect(denied, isNotNull, reason: '模型必须收到该调用的工具结果');
  expect(denied!['status'], 'denied');
  expect(denied['exitCode'], isNull);
  expect(_hasPrivilegedSuccess(client.requests), isFalse);

  final rootEntry = task.entries.firstWhere(
    (entry) => entry.text.contains('请求 root 权限'),
  );
  expect(rootEntry.finished, isTrue);
  expect(rootEntry.started, isNot(true));
  expect(rootEntry.interruption, isNotNull);
  expect(task.entries.any((entry) => entry.text.contains('已按普通权限继续检查')), isTrue);
  expect(find.text('已按普通权限继续检查。'), findsOneWidget);

  // The typed secret never reaches the provider, the transcript or the tool
  // result that is replayed on later requests.
  expect(jsonEncode(client.requests), isNot(contains(_rootSecret)));
  expect(_entryDump(task), isNot(contains(_rootSecret)));
  expect(jsonEncode(denied), isNot(contains(_rootSecret)));

  // Second round: cancellation during an in-flight authentication must
  // interrupt that sudo attempt without stopping the executor or conversation.
  await _send(tester, '再申请一次 root');
  await _pumpUntil(
    tester,
    () => task.pending?.name == aiRootToolName,
    reason: '第二次 root 审批卡未出现',
  );
  await tester.pump();
  await tester.enterText(password, _rootSecret);
  await tester.pump();
  final gate = executor.elevateGate = Completer<void>();
  final authorize = find.byKey(const ValueKey('ai-root-authorize'));
  await tester.ensureVisible(authorize);
  await tester.tap(authorize);
  await _pumpUntil(
    tester,
    () => task.authorizingRoot,
    reason: '提交密码后未进入验证状态',
  );
  // The flag flips synchronously on the controller; the ListenableBuilder
  // needs the next frame to render the verifying row.
  await _pumpUntil(
    tester,
    () => find
        .byKey(const ValueKey('ai-root-progress'))
        .evaluate()
        .isNotEmpty,
    reason: '验证状态未渲染到 root 卡片',
  );
  expect(find.byKey(const ValueKey('ai-root-progress')), findsOneWidget);

  final duringAuthCancel = find.byKey(const ValueKey('ai-root-cancel'));
  await tester.ensureVisible(duringAuthCancel);
  final rejectedId = task.pending!.id;
  await tester.tap(duringAuthCancel);
  await tester.pump();
  // The turn continues immediately, so the old pending may already have been
  // replaced by the next request. Assert the stable facts: the old call was
  // rejected, no privilege survives, and any newer request has a new id.
  expect(task.authorizingRoot, isFalse);
  expect(task.rootActive, isFalse);
  expect(task.privilegeError, isNull);
  expect(
    task.pending?.id,
    isNot(rejectedId),
    reason: '被拒绝的 root 调用不再处于待确认状态',
  );

  // The turn continues even while the old authentication is still in flight:
  // the model asks for root again and the new request is independent.
  await _pumpUntil(
    tester,
    () => task.pending?.name == aiRootToolName,
    reason: '验证中取消后模型没有继续请求下一步',
  );
  await tester.pump();
  final newPendingId = task.pending!.id;
  expect(
    newPendingId,
    isNot(rejectedId),
    reason: '同一轮的新授权必须是新的调用',
  );
  expect(find.byKey(const ValueKey('ai-root-password')), findsOneWidget);

  // The late result of the rejected attempt must not authorize, clear or
  // otherwise touch the request that replaced it.
  gate.complete();
  await tester.pump();
  await tester.pump();
  expect(task.rootActive, isFalse);
  expect(task.authorizingRoot, isFalse);
  expect(task.pending?.id, newPendingId);
  expect(task.privilegeError, isNull);
  expect(executor.elevateAttempts, [_rootSecret]);

  final newCancel = find.byKey(const ValueKey('ai-root-cancel'));
  await tester.ensureVisible(newCancel);
  await tester.tap(newCancel);
  await tester.pump();
  await _pumpUntil(
    tester,
    () => !task.running,
    reason: '拒绝新一轮 root 后模型没有继续到本轮结束',
  );
  expect(task.pending, isNull);
  expect(task.rootActive, isFalse);
  expect(
    executor.revokeCalls,
    greaterThanOrEqualTo(1),
    reason: '迟到的提权通道必须关闭',
  );
  expect(executor.commands, ['id -u'], reason: '取消后不得执行任何 root 命令');

  final authDenied = _resultIn(client.requests, 'root-r2');
  expect(authDenied, isNotNull);
  expect(authDenied!['status'], 'denied');
  final nextDenied = _resultIn(client.requests, 'root-r3');
  expect(nextDenied, isNotNull);
  expect(nextDenied!['status'], 'denied');
  expect(_hasPrivilegedSuccess(client.requests), isFalse);
  expect(jsonEncode(client.requests), isNot(contains(_rootSecret)));
  expect(_entryDump(task), isNot(contains(_rootSecret)));

  // The conversation is still usable after both denials.
  await _send(tester, '取消后继续对话');
  await _pumpUntil(
    tester,
    () => !task.running && client.requests.length == 7,
    reason: '拒绝后下一轮用户消息未被处理',
  );
  await tester.pumpAndSettle();
  expect(find.text('仍可继续对话。'), findsOneWidget);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}

Future<void> _runForwardDenial(
  WidgetTester tester, {
  required bool detached,
}) async {
  tester.view.physicalSize = const Size(340, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final client = _ScriptedClient([
    _forwardReply('forward-f1'),
    _doneReply('已取消创建转发，未监听任何端口。'),
    _doneReply('继续正常对话。'),
  ]);
  final executor = _DenialExecutor();
  final task = AiTaskController(
    settings: () => _settings,
    executorFactory: () => executor,
    connected: () => true,
    clientFactory: () => client,
    approvalMode: AiApprovalMode.auto,
  );
  addTearDown(task.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: harborTheme(),
      home: Scaffold(
        body: TerminalAiPanel(
          task: task,
          hostName: '开发服务器',
          onDock: detached ? () {} : null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await _send(tester, '帮我打开管理页');
  await _pumpUntil(
    tester,
    () => task.pending?.name == aiPortForwardToolName,
    reason: '转发审批卡未出现',
  );
  await tester.pump();
  final saveRule = find.byKey(const ValueKey('ai-save-forward-rule'));
  await tester.ensureVisible(saveRule);
  expect(tester.widget<SwitchListTile>(saveRule).value, isFalse);
  await tester.tap(saveRule);
  await tester.pump();
  expect(tester.widget<SwitchListTile>(saveRule).value, isTrue);

  // Reject even though the user asked to save the rule: a denial must never
  // create or persist the forward.
  final cancel = _cardButton('取消');
  await tester.ensureVisible(cancel);
  await tester.tap(cancel);
  await tester.pump();
  await _pumpUntil(
    tester,
    () => !task.running,
    reason: '拒绝转发后模型没有继续到本轮结束',
  );

  expect(task.pending, isNull);
  expect(task.failure, isNull);
  expect(executor.forwards, isEmpty, reason: '取消后不得绑定监听或保存规则');
  expect(executor.commands, isEmpty);

  final denied = _toolResult(client.requests[1], 'forward-f1');
  expect(denied, isNotNull);
  expect(denied!['status'], 'denied');
  expect(denied['exitCode'], isNull);

  final forwardEntry = task.entries.firstWhere(
    (entry) => entry.text.contains('本地端口转发'),
  );
  expect(forwardEntry.finished, isTrue);
  expect(forwardEntry.started, isNot(true));
  expect(forwardEntry.interruption, isNotNull);
  expect(forwardEntry.output, isEmpty);
  expect(
    task.entries.any((entry) => entry.text.contains('已取消创建转发')),
    isTrue,
  );

  // The same conversation accepts a follow-up message normally.
  await _send(tester, '那先不转发了');
  await _pumpUntil(
    tester,
    () => !task.running && client.requests.length == 3,
    reason: '拒绝后下一轮用户消息未被处理',
  );
  await tester.pumpAndSettle();
  expect(find.text('继续正常对话。'), findsOneWidget);
  expect(executor.forwards, isEmpty);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('窄屏内嵌面板：取消 root 授权只拒绝请求，模型继续且密码不进入对话', (tester) async {
    await _runRootDenial(tester, detached: false);
  });

  testWidgets('窄屏独立窗口：取消 root 授权只拒绝请求，模型继续且密码不进入对话', (tester) async {
    await _runRootDenial(tester, detached: true);
  });

  testWidgets('窄屏内嵌面板：勾选保存后取消转发不创建监听，模型收到拒绝并继续', (tester) async {
    await _runForwardDenial(tester, detached: false);
  });

  testWidgets('窄屏独立窗口：勾选保存后取消转发不创建监听，模型收到拒绝并继续', (tester) async {
    await _runForwardDenial(tester, detached: true);
  });
}
