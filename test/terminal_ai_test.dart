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
  test('旧配置保留 OpenAI 格式，新协议与厂商可持久化，地址支持完整端点', () {
    final legacy = AiSettings.fromJson({
      'baseUrl': 'https://proxy.example/v1',
      'apiKey': 'legacy-key',
      'model': 'legacy-model',
    });
    expect(legacy.protocol, AiProtocol.openai);
    expect(legacy.provider, 'custom');
    expect(legacy.apiKey, 'legacy-key');
    const liveLegacy = AiSettings(
      baseUrl: 'https://proxy.example/v1',
      model: 'm',
      protocol: null,
      provider: null,
    );
    expect(liveLegacy.toJson()['protocol'], 'openai');
    expect(liveLegacy.toJson()['provider'], 'custom');
    expect(liveLegacy.endpoint.path, '/v1/chat/completions');
    const native = AiSettings(
      baseUrl: 'https://api.anthropic.com/v1/messages/',
      model: 'claude',
      protocol: AiProtocol.anthropic,
      provider: 'anthropic',
    );
    expect(AiSettings.fromJson(native.toJson()).toJson(), native.toJson());
    expect(native.endpoint.toString(), 'https://api.anthropic.com/v1/messages');
    expect(
      const AiSettings(
        baseUrl: 'https://proxy.example/prefix/v1/chat/completions',
        model: 'claude',
        protocol: AiProtocol.anthropic,
      ).endpoint.path,
      '/prefix/v1/messages',
    );
    for (final preset in aiProviderPresets.where(
      (value) => value.id != 'custom',
    )) {
      final config = AiSettings(
        baseUrl: preset.baseUrl,
        protocol: preset.protocol,
        model: 'model',
      );
      expect(
        config.endpoint.path,
        endsWith(
          preset.protocol == AiProtocol.anthropic
              ? '/messages'
              : '/chat/completions',
        ),
      );
    }
  });

  test('Anthropic 完整工具循环：专用鉴权、系统提示、多个结果及原始内容回传', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <Map>[];
    final content = [
      {
        'type': 'thinking',
        'thinking': 'Inspect the environment.',
        'signature': 'fixture-signature',
      },
      {'type': 'text', 'text': '先检查目录和系统。'},
      for (final (id, command) in [('tool-1', 'pwd'), ('tool-2', 'uname -s')])
        {
          'type': 'tool_use',
          'id': id,
          'name': 'run_command',
          'input': {
            'command': command,
            'reason': '检查环境',
            'requires_approval': false,
          },
        },
    ];
    server.listen((request) async {
      expect(request.uri.path, '/v1/messages');
      expect(request.headers.value('x-api-key'), 'anthropic-test-key');
      expect(request.headers.value('anthropic-version'), '2023-06-01');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      requests.add(body);
      expect(body['max_tokens'], 4096);
      expect(body['system'], aiSystemPrompt);
      expect(
        body['tools'][0]['input_schema']['required'],
        contains('requires_approval'),
      );
      expect(
        (body['messages'] as List).any(
          (m) => m['role'] == 'tool' || m['role'] == 'system',
        ),
        isFalse,
      );
      if (requests.length == 2) {
        final messages = body['messages'] as List;
        expect(messages, hasLength(3));
        expect(messages[1]['content'], content);
        expect(messages[2]['role'], 'user');
        final results = messages[2]['content'] as List;
        expect(results, hasLength(2));
        expect(results.map((r) => r['tool_use_id']), ['tool-1', 'tool-2']);
        for (final result in results) {
          expect(result['type'], 'tool_result');
          expect(
            jsonDecode(result['content'] as String)['output'],
            'server output',
          );
        }
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'type': 'message',
          'role': 'assistant',
          'stop_reason': requests.length == 1 ? 'tool_use' : 'end_turn',
          'content': requests.length == 1
              ? content
              : [
                  {'type': 'text', 'text': '环境检查完成。'},
                ],
        }),
      );
      await request.response.close();
    });
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'anthropic-test-key',
        model: 'test-claude',
        protocol: AiProtocol.anthropic,
      ),
      executorFactory: () => executor,
      connected: () => true,
    );
    await task.start('检查当前环境');
    expect(task.failure, isNull);
    expect(requests, hasLength(2));
    expect(executor.commands, ['pwd', 'uname -s']);
    expect(task.entries.last.text, '环境检查完成。');
    task.dispose();
  });

  test('Anthropic 截断响应、未知工具和服务错误均不执行命令', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requestNumber = 0;
    server.listen((request) async {
      await request.drain<void>();
      requestNumber++;
      request.response.headers.contentType = ContentType.json;
      if (requestNumber == 3) {
        request.response.statusCode = 401;
        request.response.write('secret-error-details');
      } else {
        request.response.write(
          jsonEncode({
            'type': 'message',
            'role': 'assistant',
            'stop_reason': requestNumber == 1 ? 'max_tokens' : 'tool_use',
            'content': [
              {
                'type': 'tool_use',
                'id': '1',
                'name': requestNumber == 1 ? 'run_command' : 'unknown',
                'input': {
                  'command': 'pwd',
                  'reason': '检查',
                  'requires_approval': false,
                },
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    final settings = AiSettings(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'm',
      protocol: AiProtocol.anthropic,
    );
    final client = TerminalAiClient();
    await expectLater(
      client.complete(settings, []),
      throwsA(
        isA<AiFailure>().having((e) => e.message, 'message', contains('截断')),
      ),
    );
    await expectLater(
      client.complete(settings, []),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.message,
          'message',
          contains('无效的执行请求'),
        ),
      ),
    );
    await expectLater(
      client.complete(settings, []),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('认证失败'), isNot(contains('secret'))),
        ),
      ),
    );
    client.cancel();
  });
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
