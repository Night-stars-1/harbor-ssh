import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

const _settings = AiSettings(
  baseUrl: 'https://ai.example.com/v1',
  model: 'test-model',
  apiKey: 'test-key',
);

AiReply _call(String command, {bool approval = false, String id = 'call-1'}) =>
    AiReply(
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
                'reason': '检查服务器',
                'requires_approval': approval,
              }),
            },
          },
        ],
      },
      [AiToolCall(id, command, '检查服务器', approval)],
    );
const _done = AiReply({'role': 'assistant', 'content': '检查完成'}, []);

class _Client extends TerminalAiClient {
  final replies = <AiReply>[];
  final requests = <List<Map<String, dynamic>>>[];
  Completer<AiReply>? pending;
  bool cancelled = false;
  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) async {
    requests.add(List.of(messages));
    return pending?.future ?? replies.removeAt(0);
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

class _Executor implements AiCommandExecutor {
  final commands = <String>[];
  Completer<AiCommandResult>? pending;
  bool cancelled = false;
  int exitCode = 0;
  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    commands.add(command);
    onOutput('server output');
    return pending?.future ?? AiCommandResult('server output', exitCode);
  }

  @override
  void cancel() {
    cancelled = true;
  }
}

void main() {
  test('API 地址规范化，允许本机 HTTP，拒绝带凭据和远程明文地址', () {
    expect(_settings.endpoint.path, '/v1/chat/completions');
    expect(
      const AiSettings(
        baseUrl: 'https://ai.example.com/v1/chat/completions',
        model: 'm',
      ).endpoint.path,
      '/v1/chat/completions',
    );
    expect(
      const AiSettings(
        baseUrl: 'http://localhost:11434/v1/',
        model: 'm',
      ).endpoint.path,
      '/v1/chat/completions',
    );
    for (final url in [
      'http://ai.example.com/v1',
      'https://key@ai.example.com/v1',
      'https://ai.example.com/v1?key=x',
    ]) {
      expect(
        () => AiSettings(baseUrl: url, model: 'm').endpoint,
        throwsA(isA<AiFailure>()),
      );
    }
  });

  test('AI 配置保存在安全存储，存储失败保留旧设置', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveAiSettings(_settings);
    expect(
      (repository.preferences as MemoryStore).values.values.join(),
      isNot(contains('test-key')),
    );
    final reloaded = WorkspaceModel(repository);
    await reloaded.initialize();
    expect(reloaded.aiSettings.toJson(), _settings.toJson());
    (repository.secrets as MemoryStore).failWrites = true;
    await expectLater(
      model.saveAiSettings(
        const AiSettings(baseUrl: 'https://other.example/v1', model: 'new'),
      ),
      throwsStateError,
    );
    expect(model.aiSettings.toJson(), _settings.toJson());
    reloaded.dispose();
    model.dispose();
  });

  test('工具调用往返：实际命令输出与退出码返回模型，再完成任务', () async {
    final client = _Client()..replies.addAll([_call('df -h'), _done]);
    final executor = _Executor()..exitCode = 1;
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    await task.start('检查磁盘');
    expect(executor.commands, ['df -h']);
    final toolResult =
        jsonDecode(client.requests.last.last['content'] as String) as Map;
    expect(toolResult['exitCode'], 1);
    expect(toolResult['output'], 'server output');
    expect(task.entries.last.text, '检查完成');
    expect(task.running, isFalse);
    expect(task.failure, isNull);
    task.dispose();
  });

  test('高影响命令等待确认，取消后不执行也不继续调用模型', () async {
    final client = _Client()
      ..replies.addAll([_call('rm -rf /tmp/example'), _done]);
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    final completed = task.start('删除目录');
    await Future<void>.delayed(Duration.zero);
    expect(task.pending?.command, 'rm -rf /tmp/example');
    expect(executor.commands, isEmpty);
    task.approve(false);
    await completed;
    expect(executor.commands, isEmpty);
    expect(client.requests, hasLength(1));
    task.dispose();
  });

  test('模型标记需要确认的命令仅在批准后执行', () async {
    final client = _Client()
      ..replies.addAll([_call('custom-operation', approval: true), _done]);
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    final completed = task.start('操作');
    await Future<void>.delayed(Duration.zero);
    expect(executor.commands, isEmpty);
    task.approve(true);
    await completed;
    expect(executor.commands, ['custom-operation']);
    task.dispose();
  });

  test('停止时取消网络和 SSH；迟到的模型响应不能执行命令', () async {
    final client = _Client()..pending = Completer<AiReply>();
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    final completed = task.start('检查');
    task.stop();
    client.pending!.complete(_call('pwd'));
    await completed;
    expect(client.cancelled, isTrue);
    expect(executor.cancelled, isTrue);
    expect(executor.commands, isEmpty);
    task.dispose();
  });

  test('执行中停止不会继续下一步；断线后的待审批命令也不执行', () async {
    final client = _Client()..replies.addAll([_call('pwd'), _done]);
    final executor = _Executor()..pending = Completer<AiCommandResult>();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    final completed = task.start('检查');
    await Future<void>.delayed(Duration.zero);
    task.stop();
    executor.pending!.complete(const AiCommandResult('output', 0));
    await completed;
    expect(client.requests, hasLength(1));
    task.dispose();

    var connected = true;
    final secondClient = _Client()..replies.add(_call('pwd', approval: true));
    final secondExecutor = _Executor();
    final second = AiTaskController(
      settings: () => _settings,
      executorFactory: () => secondExecutor,
      connected: () => connected,
      clientFactory: () => secondClient,
    );
    final done = second.start('检查');
    await Future<void>.delayed(Duration.zero);
    connected = false;
    second.approve(true);
    await done;
    expect(secondExecutor.commands, isEmpty);
    expect(second.failure, contains('SSH 已断开'));
    second.dispose();
  });

  test('自动循环在 24 条命令后停止', () async {
    final client = _Client()
      ..replies.addAll(List.generate(25, (i) => _call('pwd', id: '$i')));
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    await task.start('检查');
    expect(executor.commands, hasLength(24));
    expect(task.failure, contains('24'));
    task.dispose();
  });

  test('真实 HTTP 协议请求工具调用，错误消息不回显服务端秘密', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requestNumber = 0;
    server.listen((request) async {
      requestNumber++;
      expect(request.uri.path, '/v1/chat/completions');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer test-key',
      );
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['tools'][0]['function']['name'], 'run_command');
      expect(body['stream'], isFalse);
      request.response.headers.contentType = ContentType.json;
      if (requestNumber == 1) {
        request.response.write(
          jsonEncode({
            'choices': [
              {'message': _call('pwd').message, 'finish_reason': 'tool_calls'},
            ],
          }),
        );
      } else if (requestNumber == 2) {
        request.response.statusCode = 401;
        request.response.write('secret-key-from-error');
      } else {
        final invalid = _call('pwd').message;
        (invalid['tool_calls'] as List).first['function']['name'] =
            'unexpected_tool';
        request.response.write(
          jsonEncode({
            'choices': [
              {'message': invalid},
            ],
          }),
        );
      }
      await request.response.close();
    });
    final config = AiSettings(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'test-key',
      model: 'mock',
    );
    final client = TerminalAiClient();
    final reply = await client.complete(config, [
      {'role': 'user', 'content': '检查'},
    ]);
    expect(reply.calls.single.command, 'pwd');
    await expectLater(
      client.complete(config, []),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('认证失败'), isNot(contains('secret'))),
        ),
      ),
    );
    await expectLater(client.complete(config, []), throwsA(isA<AiFailure>()));
    client.cancel();
  });
}
