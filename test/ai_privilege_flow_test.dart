import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/ai_privilege.dart';
import 'package:harbor_ssh/data/ssh_ai_executor.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';

import 'support.dart';

const _model = 'root-flow-model';
const _wrongPassword = 'wrong-root-password-9f2';
const _rightPassword = 'correct-root-password-4c8';
const _reason = '读取 sshd 配置确认监听端口';

const _settings = AiSettings(
  baseUrl: 'https://ai.example.com/v1',
  model: _model,
  apiKey: 'test-key',
);

const _done = AiReply({'role': 'assistant', 'content': '检查完成'}, []);

AiReply _rootReply({
  String id = 'root-1',
  Map<String, dynamic> arguments = const {'reason': _reason},
}) => AiReply(
  {
    'role': 'assistant',
    'content': null,
    'tool_calls': [
      {
        'id': id,
        'type': 'function',
        'function': {
          'name': aiRootToolName,
          'arguments': jsonEncode(arguments),
        },
      },
    ],
  },
  [
    AiToolCall(
      id,
      '',
      _reason,
      true,
      name: aiRootToolName,
      arguments: arguments,
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
            'requires_approval': false,
          }),
        },
      },
    ],
  },
  [AiToolCall(id, command, '确认当前身份', false)],
);

/// One assistant turn that requests root and a command together, so the test
/// can verify both tool calls receive exactly one result on the next request.
AiReply _rootThenCommandReply({
  required String rootId,
  required String commandId,
  required String command,
}) {
  const rootArguments = {'reason': _reason};
  final commandArguments = {
    'command': command,
    'reason': '确认当前身份',
    'requires_approval': false,
  };
  return AiReply(
    {
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {
          'id': rootId,
          'type': 'function',
          'function': {
            'name': aiRootToolName,
            'arguments': jsonEncode(rootArguments),
          },
        },
        {
          'id': commandId,
          'type': 'function',
          'function': {
            'name': 'run_command',
            'arguments': jsonEncode(commandArguments),
          },
        },
      ],
    },
    [
      AiToolCall(
        rootId,
        '',
        _reason,
        true,
        name: aiRootToolName,
        arguments: rootArguments,
      ),
      AiToolCall(commandId, command, '确认当前身份', false),
    ],
  );
}

/// Scripted OpenAI-compatible model endpoint.
///
/// Uses the same request shape the real client sends, so the root tool must be
/// advertised before the controller accepts it and every tool result is
/// visible in the next request exactly as a provider would see it.
class _Client extends TerminalAiClient {
  final replies = <AiReply>[];
  final requests = <List<Map<String, dynamic>>>[];
  final configs = <AiSettings>[];
  Completer<AiReply>? pending;
  bool cancelled = false;

  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async {
    configs.add(settings);
    requests.add(List.of(messages));
    if (replies.isNotEmpty) return replies.removeAt(0);
    final gate = pending;
    if (gate == null) throw StateError('测试模型没有待发送的回复');
    return gate.future;
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

/// Stateful stand-in for a real elevated exec channel.
///
/// Mirrors [AiPrivilegeExecutor] truthfully: elevation only succeeds after the
/// password check (or NOPASSWD), a granted-but-closed channel fails instead of
/// silently running unprivileged, and cancel/revoke close the channel.
class _PrivilegedExecutor implements AiPrivilegeExecutor {
  _PrivilegedExecutor({this.passwordless = false});

  final bool passwordless;
  final commands = <String>[];
  final executedAsRoot = <bool>[];
  final elevateAttempts = <String>[];
  int revokeCalls = 0;
  int cancelCalls = 0;
  bool _granted = false;
  bool _ready = false;
  bool _cancelled = false;

  /// When set, elevation waits for it, letting a test observe the in-flight
  /// authorization window.
  Completer<void>? elevateGate;

  /// Per-call gates consumed in order by successive [elevate] calls, so a
  /// test can finish an older attempt independently from a newer one.
  final elevateGates = <Completer<void>>[];

  /// Simulates a late authentication failure once the gate completes.
  bool failAfterGate = false;

  @override
  bool get elevated => _ready;

  @override
  Future<void> elevate(String password) async {
    elevateAttempts.add(password);
    final gate = elevateGates.isNotEmpty
        ? elevateGates.removeAt(0)
        : elevateGate;
    if (gate != null) await gate.future;
    final accepted = passwordless || password == _rightPassword;
    if (!accepted || failAfterGate) {
      _granted = false;
      _ready = false;
      throw const AiFailure('提权失败，请检查密码或服务器 sudo 权限后重试');
    }
    _granted = true;
    _ready = true;
  }

  @override
  void revokePrivilege() {
    revokeCalls++;
    _ready = false;
  }

  @override
  void cancel() {
    cancelCalls++;
    _cancelled = true;
    _ready = false;
  }

  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    if (_cancelled) throw const AiFailure('任务已停止');
    if (_granted && !_ready) {
      throw const AiFailure('root 权限通道已关闭，请重新提权');
    }
    commands.add(command);
    executedAsRoot.add(_ready);
    final output = _ready ? '0' : '1000';
    onOutput(output);
    return AiCommandResult(output, 0);
  }
}

class _PlainExecutor implements AiCommandExecutor {
  final commands = <String>[];

  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    commands.add(command);
    onOutput('1000');
    return const AiCommandResult('1000', 0);
  }

  @override
  void cancel() {}
}

Future<void> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String? reason,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail(reason ?? '条件在 $timeout 内未满足');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<AiConversationStore> _store() async {
  final directory = await Directory.systemTemp.createTemp('harbor-root-flow');
  addTearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  return AiConversationStore(
    secrets: MemoryStore(),
    directory: () async => directory,
  );
}

Future<AiConversation?> _storedConversation(
  AiConversationStore store,
  String scope,
  String id,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 10)) {
    try {
      final conversation = await store.load(scope, id);
      if (conversation != null) return conversation;
    } on AiConversationFailure {
      // The asynchronously scheduled save has not landed yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('历史对话未在 10 秒内写入');
}

List<Map<String, dynamic>> _toolResults(
  List<Map<String, dynamic>> messages,
) => [
  for (final message in messages)
    if (message['role'] == 'tool')
      jsonDecode(message['content'] as String) as Map<String, dynamic>,
];

void main() {
  test('自动模式仍须人工授权：失败可重试，root 命令执行后关闭通道且密码不落历史', () async {
    final client = _Client()
      ..replies.addAll([
        _rootReply(),
        _commandReply('id -u'),
        _done,
      ]);
    final executor = _PrivilegedExecutor();
    final store = await _store();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
      approvalMode: AiApprovalMode.auto,
      historyStore: store,
      historyScope: 'root-flow',
    );
    addTearDown(task.dispose);

    final run = task.start('确认服务是否以 root 运行');
    await _eventually(() => task.pending != null);
    final callId = task.pending!.id;

    expect(task.autoApprove, isTrue);
    expect(task.pending!.name, aiRootToolName);
    expect(task.pending!.requiresApproval, isTrue);
    expect(task.pending!.arguments, const {'reason': _reason});
    expect(executor.elevateAttempts, isEmpty);
    expect(task.rootActive, isFalse);

    // The approval-mode switch and a generic click must never grant root: the
    // request stays pending until the privileged password flow succeeds.
    task.approve(true, expectedCallId: callId);
    task.approve(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(task.pending?.id, callId);
    expect(executor.elevateAttempts, isEmpty);
    expect(task.rootActive, isFalse);

    // A delayed click for an older call never authenticates the current one.
    await task.authorizeRoot(_rightPassword, expectedCallId: 'approval-stale');
    expect(executor.elevateAttempts, isEmpty);
    expect(task.privilegeError, isNull);
    expect(task.pending?.id, callId);

    // A wrong password fails with fixed text and keeps the same request open.
    await task.authorizeRoot(_wrongPassword, expectedCallId: callId);
    expect(executor.elevateAttempts, [_wrongPassword]);
    expect(task.authorizingRoot, isFalse);
    expect(task.rootActive, isFalse);
    expect(task.pending?.id, callId);
    expect(task.privilegeError, '提权失败，请检查密码或服务器权限后重试');
    expect(task.privilegeError, isNot(contains(_wrongPassword)));

    // Retrying on the same request succeeds; the root command then runs once
    // through the elevated channel.
    await task.authorizeRoot(_rightPassword, expectedCallId: callId);
    expect(task.rootActive, isTrue);
    expect(task.privilegeError, isNull);
    expect(task.pending, isNull);

    await run.timeout(const Duration(seconds: 10));
    expect(executor.elevateAttempts, [_wrongPassword, _rightPassword]);
    expect(executor.commands, ['id -u']);
    expect(executor.executedAsRoot, [true]);
    expect(executor.cancelCalls, greaterThanOrEqualTo(1));
    expect(executor.elevated, isFalse, reason: '本轮结束必须关闭 root 通道');
    expect(task.rootActive, isFalse);
    expect(task.running, isFalse);
    expect(
      jsonEncode([
        for (final entry in task.entries) [entry.text, entry.output, entry.reason],
      ]),
      isNot(contains(_rightPassword)),
    );
    expect(
      jsonEncode([
        for (final entry in task.entries) [entry.text, entry.output, entry.reason],
      ]),
      isNot(contains(_wrongPassword)),
    );

    final rootEntry = task.entries.singleWhere(
      (entry) => entry.text.contains('请求 root 权限'),
    );
    expect(rootEntry.output, contains('已获得 root 权限'));
    expect(rootEntry.exitCode, 0);
    final commandEntry = task.entries.singleWhere(
      (entry) => entry.text == 'id -u',
    );
    expect(commandEntry.output.trim(), '0');
    expect(commandEntry.exitCode, 0);

    // The model received the real privilege result, not the password, and the
    // root command result follows it.
    expect(jsonEncode(client.requests), isNot(contains(_wrongPassword)));
    expect(jsonEncode(client.requests), isNot(contains(_rightPassword)));
    final rootResult = _toolResults(client.requests[1]).single;
    expect(rootResult['status'], 'ok');
    expect(rootResult['privilege'], 'root');
    expect(rootResult['scope'], 'current_turn');
    expect(rootResult['revokedOn'], 'turn_end');
    final commandResult = _toolResults(client.requests[2]).last;
    expect(commandResult['output'], '0');
    expect(commandResult['exitCode'], 0);

    // The persisted conversation keeps only the protocol result and command
    // output; the credentials never enter entries, history or the snapshot.
    await _eventually(() => task.activeConversationId != null);
    final saved = await _storedConversation(
      store,
      'root-flow',
      task.activeConversationId!,
    );
    expect(saved, isNotNull);
    final persisted = jsonEncode([saved!.entries, saved.history]);
    expect(persisted, isNot(contains(_wrongPassword)));
    expect(persisted, isNot(contains(_rightPassword)));
    expect(persisted, contains('root'));
    expect(persisted, contains('id -u'));
  });

  test('拒绝提权只拒绝该工具：同批命令继续执行、模型收到 denied 并完成本轮', () async {
    final client = _Client()
      ..replies.addAll([
        _rootThenCommandReply(
          rootId: 'root-denied',
          commandId: 'command-after-denial',
          command: 'id -u',
        ),
        _done,
      ]);
    final executor = _PrivilegedExecutor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
      approvalMode: AiApprovalMode.auto,
    );
    addTearDown(task.dispose);

    final run = task.start('需要 root 才能读取配置');
    await _eventually(() => task.pending != null);
    final rootCallId = task.pending!.id;
    expect(task.pending!.name, aiRootToolName);

    task.approve(false, expectedCallId: rootCallId);
    await run.timeout(const Duration(seconds: 10));

    expect(task.running, isFalse);
    expect(task.failure, isNull);
    expect(task.pending, isNull);
    expect(task.privilegeError, isNull);
    expect(executor.elevateAttempts, isEmpty, reason: '拒绝后不得发起认证');
    expect(executor.commands, ['id -u']);
    expect(executor.executedAsRoot, [false]);
    expect(executor.cancelCalls, greaterThanOrEqualTo(1));

    final rootEntry = task.entries.firstWhere(
      (entry) => entry.command && entry.exitCode == null,
    );
    expect(rootEntry.finished, isTrue);
    expect(rootEntry.started, isNot(true));
    expect(rootEntry.exitCode, isNull);

    // The refusal is a normal tool result for the same call id, so the model
    // keeps a paired conversation and still sees the other batch result.
    expect(client.requests, hasLength(2));
    final results = _toolResults(client.requests[1]);
    expect(
      [
        for (final message in client.requests[1])
          if (message['role'] == 'tool') message['tool_call_id'],
      ],
      ['root-denied', 'command-after-denial'],
    );
    expect(results, hasLength(2));
    expect(results.first['status'], 'denied');
    expect(results.first['exitCode'], isNull);
    expect(results.first['output'], '');
    final commandResult = results.last;
    expect(commandResult['output'], '1000');
    expect(commandResult['exitCode'], 0);
  });

  test('认证中拒绝提权：立即撤销旧尝试、新授权可立刻开始且迟到结果不污染新状态', () async {
    final oldGate = Completer<void>();
    final newGate = Completer<void>();
    final executor = _PrivilegedExecutor()
      ..elevateGates.addAll([oldGate, newGate]);
    final client = _Client()
      ..replies.addAll([
        _rootReply(id: 'root-inflight'),
        _rootReply(id: 'root-retry'),
        _done,
      ]);
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    addTearDown(task.dispose);

    final run = task.start('提权后读取配置');
    await _eventually(() => task.pending != null);
    final oldCallId = task.pending!.id;
    final oldAuthorization = task.authorizeRoot(
      _rightPassword,
      expectedCallId: oldCallId,
    );
    await _eventually(() => task.authorizingRoot);
    expect(executor.elevateAttempts, [_rightPassword]);

    // Rejecting while the password is still being verified denies only this
    // call and invalidates its attempt.
    task.approve(false, expectedCallId: oldCallId);
    expect(task.running, isTrue);
    expect(task.pending, isNull);
    expect(task.authorizingRoot, isFalse);
    expect(task.privilegeError, isNull);
    expect(task.rootActive, isFalse);
    expect(executor.cancelCalls, 0, reason: '拒绝单次提权不得取消整个执行器');
    final revokesAfterDenial = executor.revokeCalls;
    expect(revokesAfterDenial, greaterThanOrEqualTo(1));

    // The model sees the refusal and requests root again; the new
    // authorization starts while the old attempt is still unfinished.
    await _eventually(() => task.pending != null);
    final newCallId = task.pending!.id;
    expect(newCallId, isNot(oldCallId));
    final newAuthorization = task.authorizeRoot(
      _rightPassword,
      expectedCallId: newCallId,
    );
    expect(task.authorizingRoot, isTrue);
    expect(executor.elevateAttempts, [_rightPassword, _rightPassword]);

    oldGate.complete();
    await oldAuthorization.timeout(const Duration(seconds: 10));
    expect(task.authorizingRoot, isTrue, reason: '旧尝试迟到结果不得清除新授权状态');
    expect(task.pending?.id, newCallId);
    expect(task.rootActive, isFalse);
    expect(task.privilegeError, isNull);
    expect(
      executor.revokeCalls,
      revokesAfterDenial,
      reason: '旧尝试迟到不得撤销新尝试的通道',
    );

    newGate.complete();
    await newAuthorization.timeout(const Duration(seconds: 10));
    expect(task.rootActive, isTrue);
    expect(task.authorizingRoot, isFalse);
    expect(task.pending, isNull);

    await run.timeout(const Duration(seconds: 10));
    expect(task.failure, isNull);
    expect(task.running, isFalse);
    // Both tool calls are answered exactly once and in order.
    expect(client.requests, hasLength(3));
    final results = _toolResults(client.requests[2]);
    expect(results.map((item) => item['status']), ['denied', 'ok']);
    final deniedEntry = task.entries.firstWhere(
      (entry) => entry.command && entry.exitCode == null,
    );
    expect(deniedEntry.finished, isTrue);
    expect(deniedEntry.started, isNot(true));
    expect(jsonEncode(client.requests), isNot(contains(_rightPassword)));
    expect(
      jsonEncode([
        for (final entry in task.entries) [entry.text, entry.output, entry.reason],
      ]),
      isNot(contains(_rightPassword)),
    );
  });

  test('撤销在途打开不会留下忙锁：新授权立即开始且旧清理不清新尝试', () async {
    final firstOpen = Completer<SSHSession>();
    final opens = <String>[];
    final executor = SshAiExecutor(
      (_) async => throw StateError('未使用'),
      openPrivilege: (command) {
        opens.add(command);
        // Both openings stay pending: this test observes the cancellation
        // signal itself, not a finished SSH handshake.
        return opens.length == 1
            ? firstOpen.future
            : Completer<SSHSession>().future;
      },
    );
    addTearDown(executor.cancel);

    final held = executor.elevate(_rightPassword);
    expect(opens, hasLength(1));
    executor.revokePrivilege();

    // A new authorization must start while the revoked opening is still
    // pending; a shared busy flag or a late cleanup would block it.
    final second = executor.elevate(_rightPassword);
    expect(opens, hasLength(2), reason: '撤销旧尝试后新授权必须立即开始');

    await expectLater(
      held.timeout(const Duration(seconds: 2)),
      throwsA(isA<AiFailure>()),
    );
    // The revoked attempt's finally ran after the new one started; it must
    // not clear the new attempt or the busy guard would disappear.
    final third = executor.elevate(_rightPassword);
    expect(opens, hasLength(2), reason: '旧 finally 不得清空新尝试');
    await expectLater(third, throwsA(isA<AiFailure>()));

    executor.revokePrivilege();
    await expectLater(
      second.timeout(const Duration(seconds: 2)),
      throwsA(isA<AiFailure>()),
    );
    expect(executor.elevated, isFalse);
  });

  test('显式停止仍不继续请求模型，与单次拒绝保持不同语义', () async {
    final client = _Client()..replies.add(_rootReply());
    final executor = _PrivilegedExecutor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    addTearDown(task.dispose);

    final run = task.start('提权请求');
    await _eventually(() => task.pending != null);
    task.stop();
    await run.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(client.requests, hasLength(1), reason: '显式停止不得再请求模型');
    expect(task.running, isFalse);
    expect(task.pending, isNull);
    expect(executor.cancelCalls, greaterThanOrEqualTo(1));
    expect(executor.elevateAttempts, isEmpty);
  });

  test('只读、无提权执行器和非法参数都在密码流程之前被拒绝', () async {
    // Read-only mode must never advertise or run request_root, even if the
    // model tries anyway.
    final readOnlyClient = _Client()
      ..replies.addAll([_rootReply(id: 'readonly-root'), _done]);
    final readOnlyExecutor = _PrivilegedExecutor();
    final readOnly = AiTaskController(
      settings: () => _settings,
      executorFactory: () => readOnlyExecutor,
      connected: () => true,
      clientFactory: () => readOnlyClient,
      approvalMode: AiApprovalMode.readOnly,
    );
    addTearDown(readOnly.dispose);
    await readOnly.start('只读模式尝试提权');
    expect(readOnlyExecutor.elevateAttempts, isEmpty);
    expect(readOnly.pending, isNull);
    expect(readOnly.rootActive, isFalse);
    final readOnlyEntry = readOnly.entries.singleWhere(
      (entry) => entry.command,
    );
    expect(readOnlyEntry.interruption, '只读模式不允许此工具');
    expect(readOnlyEntry.started, isNot(isTrue));

    // An executor without the capability gets a truthful rejection instead of
    // an authentication prompt that could never succeed.
    final plainClient = _Client()
      ..replies.addAll([_rootReply(id: 'plain-root'), _done]);
    final plainExecutor = _PlainExecutor();
    final plain = AiTaskController(
      settings: () => _settings,
      executorFactory: () => plainExecutor,
      connected: () => true,
      clientFactory: () => plainClient,
    );
    addTearDown(plain.dispose);
    await plain.start('普通会话尝试提权');
    expect(plain.pending, isNull);
    expect(plainExecutor.commands, isEmpty);
    expect(
      plain.entries.singleWhere((entry) => entry.command).interruption,
      '当前会话不支持提权',
    );

    // A drifted or fake tool call with invalid arguments fails before the
    // password UI and never reaches the executor.
    final invalidClient = _Client()
      ..replies.addAll([
        _rootReply(id: 'bad-root', arguments: const {'reason': ''}),
        _done,
      ]);
    final invalidExecutor = _PrivilegedExecutor();
    final invalid = AiTaskController(
      settings: () => _settings,
      executorFactory: () => invalidExecutor,
      connected: () => true,
      clientFactory: () => invalidClient,
    );
    addTearDown(invalid.dispose);
    await invalid.start('发送非法提权参数');
    expect(invalidExecutor.elevateAttempts, isEmpty);
    expect(invalid.pending, isNull);
    final invalidEntry = invalid.entries.singleWhere(
      (entry) => entry.command,
    );
    expect(invalidEntry.interruption, '工具参数无效，未执行');
    final toolResult = _toolResults(invalidClient.requests[1]).single;
    expect(toolResult['status'], 'tool_not_allowed');
  });

  test('NOPASSWD sudo 允许空密码完成提权', () async {
    final client = _Client()
      ..replies.addAll([
        _rootReply(id: 'passwordless-root'),
        _commandReply('id -u', id: 'passwordless-command'),
        _done,
      ]);
    final executor = _PrivilegedExecutor(passwordless: true);
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    addTearDown(task.dispose);

    final run = task.start('免密 sudo 会话确认身份');
    await _eventually(() => task.pending != null);
    final callId = task.pending!.id;
    await task.authorizeRoot('', expectedCallId: callId);
    expect(executor.elevateAttempts, ['']);
    expect(task.rootActive, isTrue);
    expect(task.pending, isNull);

    await run.timeout(const Duration(seconds: 10));
    expect(executor.commands, ['id -u']);
    expect(executor.executedAsRoot, [true]);
    expect(task.rootActive, isFalse);
    expect(executor.elevated, isFalse);
  });

  test('停止后迟到的提权结果不得复活旧轮', () async {
    final client = _Client()..replies.add(_rootReply());
    final executor = _PrivilegedExecutor()..elevateGate = Completer<void>();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    addTearDown(task.dispose);

    final run = task.start('提权后继续读取配置');
    await _eventually(() => task.pending != null);
    final callId = task.pending!.id;
    final authorization = task.authorizeRoot(
      _rightPassword,
      expectedCallId: callId,
    );
    await _eventually(() => task.authorizingRoot);

    task.stop();
    await run.timeout(const Duration(seconds: 10));
    expect(task.running, isFalse);
    expect(task.rootActive, isFalse);

    executor.elevateGate!.complete();
    await authorization;
    expect(task.rootActive, isFalse);
    expect(task.pending, isNull);
    expect(task.authorizingRoot, isFalse);
    expect(executor.revokeCalls, greaterThanOrEqualTo(1));
    expect(executor.elevated, isFalse);
    expect(executor.commands, isEmpty, reason: '停止后不得执行任何 root 命令');
    expect(
      task.entries.singleWhere((entry) => entry.command).interruption,
      '未执行',
    );
  });

  test('旧轮迟到成功或失败都不得清除新轮的授权中状态', () async {
    for (final oldSucceeds in [true, false]) {
      final oldExecutor = _PrivilegedExecutor()
        ..elevateGate = Completer<void>()
        ..failAfterGate = !oldSucceeds;
      final newExecutor = _PrivilegedExecutor()
        ..elevateGate = Completer<void>();
      final executors = <AiPrivilegeExecutor>[oldExecutor, newExecutor];
      final clients = <_Client>[
        _Client()..replies.add(_rootReply(id: 'old-root')),
        _Client()
          ..replies.addAll([_rootReply(id: 'new-root'), _done]),
      ];
      var clientIndex = 0;
      final task = AiTaskController(
        settings: () => _settings,
        executorFactory: () => executors.removeAt(0),
        connected: () => true,
        clientFactory: () => clients[clientIndex++],
      );

      try {
        final first = task.start('第一轮请求提权');
        await _eventually(() => task.pending != null);
        final oldCallId = task.pending!.id;
        final oldAuthorization = task.authorizeRoot(
          _rightPassword,
          expectedCallId: oldCallId,
        );
        await _eventually(() => task.authorizingRoot);

        task.stop();
        await first.timeout(const Duration(seconds: 10));
        expect(task.running, isFalse);

        // A new turn starts while the previous authorization is still alive.
        final second = task.start('第二轮重新请求提权');
        await _eventually(() => task.pending != null);
        final newCallId = task.pending!.id;
        expect(newCallId, isNot(oldCallId));
        final newAuthorization = task.authorizeRoot(
          _rightPassword,
          expectedCallId: newCallId,
        );
        expect(task.authorizingRoot, isTrue);
        expect(newExecutor.elevateAttempts, [_rightPassword]);

        // Only now does the previous turn's verification finish.
        oldExecutor.elevateGate!.complete();
        await oldAuthorization;
        expect(
          task.authorizingRoot,
          isTrue,
          reason: '旧轮${oldSucceeds ? '成功' : '失败'}结果不得清除新轮的授权中状态',
        );
        expect(task.rootActive, isFalse);
        expect(task.privilegeError, isNull);
        expect(task.pending?.id, newCallId);
        expect(newExecutor.revokeCalls, 0);
        expect(newExecutor.elevated, isFalse);
        if (oldSucceeds) {
          expect(
            oldExecutor.revokeCalls,
            greaterThanOrEqualTo(1),
            reason: '旧轮迟到的成功通道必须被关闭',
          );
        }
        expect(oldExecutor.elevated, isFalse);

        // The new authorization still completes on its own terms.
        newExecutor.elevateGate!.complete();
        await newAuthorization;
        expect(task.rootActive, isTrue);
        expect(task.authorizingRoot, isFalse);
        expect(task.privilegeError, isNull);
        expect(task.pending, isNull);

        await second.timeout(const Duration(seconds: 10));
        expect(task.rootActive, isFalse);
        expect(newExecutor.elevated, isFalse);
        expect(oldExecutor.commands, isEmpty);
      } finally {
        task.dispose();
      }
    }
  });

  test('结束提权会停止本轮并关闭 root 通道', () async {
    final client = _Client()
      ..replies.add(_rootReply())
      ..pending = Completer<AiReply>();
    final executor = _PrivilegedExecutor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    addTearDown(task.dispose);

    final run = task.start('提权后等待下一步');
    await _eventually(() => task.pending != null);
    await task.authorizeRoot(
      _rightPassword,
      expectedCallId: task.pending!.id,
    );
    expect(task.rootActive, isTrue);
    // The turn has already asked the model for the next step; endRoot must
    // stop it instead of silently continuing unprivileged.
    await _eventually(() => client.requests.length >= 2);

    task.endRoot();
    expect(task.running, isFalse);
    expect(task.rootActive, isFalse);
    expect(task.authorizingRoot, isFalse);
    expect(task.pending, isNull);
    expect(task.status, '已结束提权并停止本轮任务');
    expect(executor.cancelCalls, greaterThanOrEqualTo(1));
    expect(executor.elevated, isFalse);
    expect(executor.commands, isEmpty);

    client.pending!.complete(_done);
    await run.timeout(const Duration(seconds: 10));
    expect(task.entries.last.notice, isTrue);
    expect(task.entries.last.text, contains('已结束提权并停止本轮任务'));

    // Idle cleanup is harmless.
    task.endRoot();
    expect(task.running, isFalse);
    expect(task.status, '已结束提权并停止本轮任务');
  });

  test('只在支持提权且非只读时向模型声明 request_root', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
    });
    final requests = <Map<String, dynamic>>[];
    final errors = <Object>[];
    server.listen((request) async {
      try {
        final body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        requests.add(body);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '已检查',
                },
              },
            ],
          }),
        );
        await request.response.close();
      } catch (error) {
        errors.add(error);
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });
    final settings = AiSettings(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: _model,
    );

    final capable = AiTaskController(
      settings: () => settings,
      executorFactory: () => _PrivilegedExecutor(),
      connected: () => true,
    );
    addTearDown(capable.dispose);
    await capable.start('列出可用的提权方式');
    expect(errors, isEmpty);
    expect(requests, hasLength(1));
    final tools = (requests.single['tools'] as List)
        .cast<Map<String, dynamic>>();
    final rootTool = tools.singleWhere(
      (tool) => (tool['function'] as Map)['name'] == aiRootToolName,
    );
    final function = rootTool['function'] as Map;
    final parameters = function['parameters'] as Map;
    expect((parameters['properties'] as Map).keys, ['reason']);
    expect(parameters['required'], ['reason']);
    expect(parameters['additionalProperties'], isFalse);
    expect(jsonEncode(function), isNot(contains('password')));
    expect(
      function['description'],
      contains('每次调用都需要人工确认'),
    );

    final readOnly = AiTaskController(
      settings: () => settings,
      executorFactory: () => _PrivilegedExecutor(),
      connected: () => true,
      approvalMode: AiApprovalMode.readOnly,
    );
    addTearDown(readOnly.dispose);
    await readOnly.start('只读列出目录');
    expect(errors, isEmpty);
    expect(requests, hasLength(2));
    final readOnlyTools = (requests[1]['tools'] as List)
        .cast<Map<String, dynamic>>();
    final readOnlyNames = [
      for (final tool in readOnlyTools) (tool['function'] as Map)['name'],
    ];
    expect(readOnlyNames, isNot(contains(aiRootToolName)));
    expect(readOnlyNames, isNot(contains(aiPortForwardToolName)));
    expect(
      readOnlyNames.every(
        (name) => const [
          'list_directory',
          'read_file',
          'search_text',
          'system_info',
        ].contains(name),
      ),
      isTrue,
    );

    // A writable session whose executor cannot elevate must not advertise the
    // tool either, so the model is never invited to ask for a password.
    final plain = AiTaskController(
      settings: () => settings,
      executorFactory: () => _PlainExecutor(),
      connected: () => true,
    );
    addTearDown(plain.dispose);
    await plain.start('普通会话列出命令工具');
    expect(errors, isEmpty);
    expect(requests, hasLength(3));
    final plainNames = [
      for (final tool in (requests[2]['tools'] as List).cast<Map>())
        (tool['function'] as Map)['name'],
    ];
    expect(plainNames, contains('run_command'));
    expect(plainNames, isNot(contains(aiRootToolName)));
  });
}
