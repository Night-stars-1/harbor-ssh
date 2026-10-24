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
  test('会话可切换模型并自动批准需要确认的命令', () async {
    final client = _Client()
      ..replies.addAll([_call('pwd', approval: true), _done]);
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    task.setModel('alternate-model');
    task.setAutoApprove(true);
    expect(task.activeModel, 'alternate-model');
    await task.start('检查目录');
    expect(client.configs.first.model, 'alternate-model');
    expect(executor.commands, ['pwd']);
    expect(task.pending, isNull);
    task.dispose();
  });

  test('只读模型仍由客户端执行工具命令，不额外拦截或等待审批', () async {
    final client = _Client()
      ..replies.addAll([
        AiReply(
          const {'role': 'assistant', 'content': null},
          [
            AiToolCall(
              'read-1',
              '',
              '读取目录',
              false,
              name: 'list_directory',
              arguments: {'path': '/tmp', 'reason': '查看临时目录'},
            ),
          ],
        ),
        _done,
      ]);
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    task.setApprovalMode(AiApprovalMode.readOnly);
    await task.start('清理临时文件');
    expect(executor.commands, ["ls -la -- '/tmp'"]);
    expect(task.pending, isNull);
    task.dispose();
  });

  test('每条回复记录当轮模型，切换模型不改写旧消息标签', () async {
    var settings = _settings;
    final client = _Client()..replies.addAll([_done, _done]);
    final task = AiTaskController(
      settings: () => settings,
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client,
    );
    await task.start('第一问');
    settings = const AiSettings(
      baseUrl: 'https://ai.example.com/v1',
      model: 'second-model',
    );
    await task.start('第二问');
    expect(
      task.entries
          .where((entry) => entry.user != true)
          .map((entry) => entry.model),
      ['test-model', 'second-model'],
    );
    task.dispose();
  });
  test('连续对话保留工具结果，新对话清空上下文且会话之间隔离', () async {
    final client = _Client()
      ..replies.addAll([_call('pwd'), _done, _done, _done]);
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client,
    );
    await task.start('检查目录');
    await task.start('继续解释');
    expect(client.requests.last.map((m) => m['role']), [
      'system',
      'user',
      'assistant',
      'tool',
      'assistant',
      'user',
    ]);
    expect(jsonEncode(client.requests.last), contains('server output'));
    expect(task.entries.where((e) => e.user == true).map((e) => e.text), [
      '检查目录',
      '继续解释',
    ]);
    task.newConversation();
    expect(task.entries, isEmpty);
    await task.start('新的问题');
    expect(client.requests.last, hasLength(2));
    final other = AiTaskController(
      settings: () => _settings,
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client,
    );
    client.replies.add(_done);
    await other.start('另一个服务器');
    expect(client.requests.last, hasLength(2));
    other.dispose();
    task.dispose();
  });

  test('取消多工具审批后续聊，为所有未执行命令补齐结果', () async {
    final first = _call('rm /tmp/a', id: 'a');
    final second = _call('pwd', id: 'b');
    final client = _Client()
      ..replies.addAll([
        AiReply(
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              ...first.message['tool_calls'] as List,
              ...second.message['tool_calls'] as List,
            ],
          },
          [...first.calls, ...second.calls],
        ),
        _done,
      ]);
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => client,
    );
    final initial = task.start('清理');
    await Future<void>.delayed(Duration.zero);
    task.approve(false);
    await initial;
    await task.start('别删了，解释一下');
    final results = client.requests.last
        .where((m) => m['role'] == 'tool')
        .toList();
    expect(results.map((m) => m['tool_call_id']), ['a', 'b']);
    for (final result in results) {
      expect(jsonDecode(result['content'] as String)['status'], 'not_executed');
    }
    expect(executor.commands, isEmpty);
    expect(task.entries.where((e) => e.command).single.interruption, '未执行');
    task.dispose();
  });

  test('执行中停止后立即续聊，保留部分输出并忽略旧轮迟到结果', () async {
    final client = _Client()..replies.add(_call('pwd'));
    final executor = _Executor()..pending = Completer<AiCommandResult>();
    final next = _Client()..replies.add(_done);
    var clients = 0;
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: () => clients++ == 0 ? client : next,
    );
    final initial = task.start('检查');
    await Future<void>.delayed(Duration.zero);
    task.stop();
    await task.start('刚才运行到哪了');
    final result = jsonDecode(
      next.requests.single.singleWhere((m) => m['role'] == 'tool')['content']
          as String,
    );
    expect(result['status'], 'interrupted');
    expect(result['output'], 'server output');
    expect(result['exitCode'], isNull);
    executor.pending!.complete(const AiCommandResult('迟到结果', 0));
    await initial;
    expect(task.entries.where((e) => e.command).single.output, 'server output');
    expect(task.entries.last.text, '检查完成');
    task.dispose();
  });

  test('模型请求失败后可续聊，保留错误发生前的对话', () async {
    final client = _Client()..pending = Completer<AiReply>();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client,
    );
    final first = task.start('第一问');
    client.pending!.completeError(const AiFailure('网络中断'));
    await first;
    client.pending = null;
    client.replies.add(_done);
    await task.start('重试刚才的问题');
    expect(task.failure, isNull);
    expect(jsonEncode(client.requests.last), contains('第一问'));
    expect(jsonEncode(client.requests.last), contains('网络中断'));
    expect(task.entries.where((e) => e.notice == true).single.text, '网络中断');
    task.dispose();
  });

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

  test('审批模式默认选择：三种模式可持久化并在新建任务时生效', () {
    const emptySettings = AiSettings();
    expect(emptySettings.defaultApprovalMode, AiApprovalMode.manual);
    expect(
      AiSettings.fromJson(emptySettings.toJson()).defaultApprovalMode,
      AiApprovalMode.manual,
    );
    expect(
      AiSettings.fromJson({'defaultApprovalMode': 'unknown'})
          .defaultApprovalMode,
      AiApprovalMode.manual,
    );

    for (final mode in AiApprovalMode.values) {
      final settings = AiSettings(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o',
        defaultApprovalMode: mode,
      );
      final json = settings.toJson();
      expect(json['defaultApprovalMode'], mode.name);
      final restored = AiSettings.fromJson(json);
      expect(restored.defaultApprovalMode, mode);
      expect(settings.withModel('another').defaultApprovalMode, mode);

      final task = AiTaskController(
        settings: () => settings,
        executorFactory: _Executor.new,
        connected: () => true,
        clientFactory: () => _Client(),
      );
      expect(task.approvalMode, mode);
      task.dispose();
    }
  });

  test('默认模型与审批模型可解析到其他服务商', () {
    const settings = AiSettings(
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'openai-key',
      model: 'gpt-test',
      provider: 'openai',
      protocol: AiProtocol.openai,
      approvalModel: 'claude-test',
      approvalProvider: 'anthropic',
      profiles: [
        AiProviderProfile(
          id: 'openai',
          name: 'OpenAI',
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'openai-key',
          defaultModel: 'gpt-test',
          approvalModel: '',
          protocol: AiProtocol.openai,
        ),
        AiProviderProfile(
          id: 'anthropic',
          name: 'Anthropic',
          baseUrl: 'https://api.anthropic.com/v1',
          apiKey: 'anthropic-key',
          defaultModel: 'claude-test',
          approvalModel: 'claude-test',
          protocol: AiProtocol.anthropic,
        ),
      ],
    );
    expect(settings.settingsFor('openai').apiKey, 'openai-key');
    expect(settings.settingsFor('openai').model, 'gpt-test');
    final approval = settings.approvalSettings!;
    expect(approval.baseUrl, 'https://api.anthropic.com/v1');
    expect(approval.apiKey, 'anthropic-key');
    expect(approval.model, 'claude-test');
    expect(approval.protocol, AiProtocol.anthropic);
    expect(approval.provider, 'anthropic');
    expect(AiSettings.fromJson(settings.toJson()).toJson(), settings.toJson());
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
      expect((body['tools'] as List).map((tool) => tool['name']), [
        'run_command',
      ]);
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
  test('API 地址规范化，允许本机和可信内网 HTTP，拒绝带凭据或查询参数', () {
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
    expect(
      const AiSettings(
        baseUrl: 'http://192.168.1.20:11434/v1',
        model: 'm',
      ).endpoint.toString(),
      'http://192.168.1.20:11434/v1/chat/completions',
    );
    expect(
      const AiSettings(
        baseUrl: 'http://ai.internal.example/v1',
        model: 'm',
      ).endpoint.scheme,
      'http',
    );
    for (final url in [
      'https://key@ai.example.com/v1',
      'https://ai.example.com/v1?key=x',
      'https://ai.example.com/v1#fragment',
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

  test('OpenAI SSE 文本增量在完整响应前持续回调', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['stream'], isTrue);
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      for (final content in ['你好', '，这是', '流式回复']) {
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': content},
              },
            ],
          })}\n\n',
        );
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final client = TerminalAiClient();
    final chunks = <String>[];
    final reply = await client.stream(
      AiSettings(baseUrl: 'http://127.0.0.1:${server.port}/v1', model: 'mock'),
      [
        {'role': 'user', 'content': '你好'},
      ],
      onText: chunks.add,
    );
    expect(chunks, ['你好', '，这是', '流式回复']);
    expect(reply.text, '你好，这是流式回复');
    client.cancel();
  });
  test('流式回答中途断开时保留已收到文本并区分连接失败', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.bufferOutput = false;
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '已收到部分回答'},
            },
          ],
        })}\n\n',
      );
      await request.response.flush();
      await received.future.timeout(const Duration(seconds: 5));
      await server.close(force: true);
    });
    final client = TerminalAiClient();
    addTearDown(client.cancel);
    final chunks = <String>[];
    await expectLater(
      client.stream(
        AiSettings(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'mock',
        ),
        [
          {'role': 'user', 'content': '继续'},
        ],
        onText: (delta) {
          chunks.add(delta);
          if (!received.isCompleted) received.complete();
        },
      ),
      throwsA(
        isA<AiFailure>()
            .having((e) => e.message, 'message', contains('流式回复中断'))
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
    expect(chunks, ['已收到部分回答']);
  });

  test('AI 连接中断后自动重新请求，重试期间显示原因，成功后不重复已收文本', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final bodies = <Map>[];
    server.listen((request) async {
      requests++;
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map);
      if (requests == 1) {
        // Headers and one SSE chunk go out, then the socket is cut before
        // the chunked body ends, like a gateway reset mid-reply.
        final socket = await request.response.detachSocket(
          writeHeaders: false,
        );
        final chunk = utf8.encode(
          'data: {"choices":[{"delta":{"content":"半截"}}]}\n\n',
        );
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream; charset=utf-8\r\n'
            'Transfer-Encoding: chunked\r\n\r\n'
            '${chunk.length.toRadixString(16)}\r\n',
          ),
        );
        socket.add(chunk);
        socket.add(utf8.encode('\r\n'));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        socket.destroy();
        return;
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"完整回答"}}]}\n\n'
        'data: [DONE]\n\n',
      );
      await request.response.close();
    });
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'mock',
      ),
      executorFactory: _Executor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    final seen = <(String, String?)>[];
    task.addListener(() => seen.add((task.status, task.failure)));
    await task.start('你好');
    expect(requests, 2);
    expect(bodies[1]['messages'], bodies[0]['messages']);
    expect(
      seen.any(
        (s) =>
            s.$1.startsWith('连接中断，1 秒后重试（1/3）') &&
            (s.$2 ?? '').contains('AI 流式回复中断'),
      ),
      isTrue,
      reason: '重试期间显示中断原因',
    );
    expect(task.failure, isNull);
    expect(task.status, '已完成');
    expect(task.entries.map((e) => e.text), ['你好', '完整回答']);
  });

  test('AI 连接持续中断时重试用尽，显示具体原因与重试次数', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      (await request.response.detachSocket()).destroy();
    });
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'mock',
      ),
      executorFactory: _Executor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    await task.start('你好');
    expect(requests, 1 + aiRetryDelays.length);
    expect(task.running, isFalse);
    expect(task.status, '回复中断');
    expect(
      task.failure,
      allOf(
        startsWith('AI 连接中断：'),
        contains('HttpException'),
        endsWith('（已自动重试 3 次）'),
      ),
    );
    expect(task.entries.last.notice, isTrue);
    expect(task.entries.last.text, task.failure);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('重试等待中停止任务不会再次请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final dropped = Completer<void>();
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      (await request.response.detachSocket()).destroy();
      if (!dropped.isCompleted) dropped.complete();
    });
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'mock',
      ),
      executorFactory: _Executor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    final turn = task.start('你好');
    await dropped.future;
    while (!task.status.startsWith('连接中断')) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    task.stop();
    await turn;
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(requests, 1);
    expect(task.running, isFalse);
  });

  test('增量回调异常不会误报为 AI 网络故障或泄漏异常内容', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
      );
      await request.response.close();
    });
    final client = TerminalAiClient();
    addTearDown(client.cancel);
    await expectLater(
      client.stream(
        AiSettings(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'mock',
        ),
        [
          {'role': 'user', 'content': '你好'},
        ],
        onText: (_) => throw StateError('secret-error-detail'),
      ),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.message,
          'message',
          allOf(contains('StateError'), isNot(contains('secret-error-detail'))),
        ),
      ),
    );
  });

  test('思考等级在回合运行中不可更改，下一回合才采用新档位', () async {
    final client = _Client()..pending = Completer<AiReply>();
    final task = AiTaskController(
      settings: () => _settings,
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client,
    );
    task.setReasoningEffort(AiReasoningEffort.medium);
    final turn = task.start('检查目录');
    await Future<void>.delayed(Duration.zero);
    expect(task.running, isTrue);
    task.setReasoningEffort(AiReasoningEffort.max);
    expect(
      task.reasoningEffort,
      AiReasoningEffort.medium,
      reason: '运行中的回合沿用开始时的档位',
    );
    client.pending!.complete(_done);
    await turn;
    expect(client.configs.single.reasoningEffort, AiReasoningEffort.medium);
    task.setReasoningEffort(AiReasoningEffort.max);
    expect(task.reasoningEffort, AiReasoningEffort.max);
    task.dispose();
  });

  test('真实 OpenAI 请求携带所选思考等级，工具回合沿用，切回自动后不再带字段', () async {
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
    final executor = _Executor();
    final task = AiTaskController(
      settings: () => AiSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'test-key',
        model: 'reasoning-model',
      ),
      executorFactory: () => executor,
      connected: () => true,
      clientFactory: TerminalAiClient.new,
    );
    expect(task.reasoningEffort, AiReasoningEffort.automatic);
    task.setReasoningEffort(AiReasoningEffort.high);
    await task.start('检查目录');

    expect(task.failure, isNull);
    expect(executor.commands, ['pwd']);
    expect(bodies, hasLength(2), reason: '工具结果回传给同一模型');
    for (final body in bodies) {
      expect(body['reasoning_effort'], 'high');
      expect(body['model'], 'reasoning-model');
      expect(body.containsKey('output_config'), isFalse);
    }
    expect(bodies[1]['messages'].last['role'], 'tool');

    task.setReasoningEffort(AiReasoningEffort.automatic);
    await task.start('再检查一次');
    expect(bodies, hasLength(3));
    expect(
      bodies[2].containsKey('reasoning_effort'),
      isFalse,
      reason: '自动档必须与未设置该字段的请求完全一致',
    );
    task.dispose();
  });

  test('真实 Anthropic 请求用 output_config.effort，保留签名思考与 4096 输出上限', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    final content = <Map<String, dynamic>>[
      {
        'type': 'thinking',
        'thinking': '先检查环境。',
        'signature': 'fixture-signature',
      },
      {'type': 'text', 'text': '检查中。'},
      {
        'type': 'tool_use',
        'id': 'tool-1',
        'name': 'run_command',
        'input': {
          'command': 'pwd',
          'reason': '检查环境',
          'requires_approval': false,
        },
      },
    ];
    server.listen((request) async {
      expect(request.uri.path, '/v1/messages');
      expect(request.headers.value('x-api-key'), 'anthropic-test-key');
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      bodies.add(body);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'type': 'message',
          'role': 'assistant',
          'stop_reason': bodies.length == 1 ? 'tool_use' : 'end_turn',
          'content': bodies.length == 1
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
      clientFactory: TerminalAiClient.new,
    );
    task.setReasoningEffort(AiReasoningEffort.xhigh);
    await task.start('检查当前环境');

    expect(task.failure, isNull);
    expect(executor.commands, ['pwd']);
    expect(bodies, hasLength(2));
    for (final body in bodies) {
      expect(body['output_config'], {'effort': 'xhigh'});
      expect(body['max_tokens'], 4096, reason: '思考等级不改变既有输出上限');
      expect(
        body.containsKey('thinking'),
        isFalse,
        reason: '本功能只发 effort，不自行开启 thinking',
      );
      expect(body.containsKey('reasoning_effort'), isFalse);
    }
    expect(
      (bodies[1]['messages'] as List)[1]['content'],
      content,
      reason: '同一模型后续回合原样回传带签名的思考块',
    );

    task.setReasoningEffort(AiReasoningEffort.automatic);
    await task.start('继续');
    expect(bodies, hasLength(3));
    expect(bodies[2].containsKey('output_config'), isFalse);
    expect(bodies[2]['max_tokens'], 4096);
    task.dispose();
  });
}
