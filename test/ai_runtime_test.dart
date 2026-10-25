import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';

import 'support.dart';

const _supplement = '用户补充：回答保持简短。';
const _lookupSchema = {
  'type': 'object',
  'properties': {
    'query': {'type': 'string'},
  },
  'required': ['query'],
  'additionalProperties': false,
};
const _countSchema = {
  'type': 'object',
  'properties': {
    'by': {'type': 'integer', 'minimum': 1, 'maximum': 100},
  },
  'required': ['by'],
  'additionalProperties': false,
};
const _argvSchema = {
  'type': 'object',
  'properties': {
    'command': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
  'required': ['command'],
  'additionalProperties': false,
};

Map<String, dynamic> _textReply(String text) => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': text},
    },
  ],
};

Map<String, dynamic> _toolReply(
  String name,
  Map<String, dynamic> arguments, {
  String id = 'call-1',
}) => {
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': id,
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(arguments)},
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _anthropicToolReply(
  String name,
  Map<String, dynamic> arguments,
) => {
  'type': 'message',
  'role': 'assistant',
  'stop_reason': 'tool_use',
  'content': [
    {'type': 'tool_use', 'id': 'anthropic-call-1', 'name': name, 'input': arguments},
  ],
};

Map<String, dynamic> _anthropicTextReply(String text) => {
  'type': 'message',
  'role': 'assistant',
  'stop_reason': 'end_turn',
  'content': [
    {'type': 'text', 'text': text},
  ],
};

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

Future<void> _writeJson(HttpRequest request, Object body, {int status = 200}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

class _ModelServer {
  _ModelServer._(this._server);
  final HttpServer _server;
  final requests = <Map<String, dynamic>>[];
  final errors = <Object>[];
  Future<void> Function(
    HttpRequest request,
    Map<String, dynamic> body,
    int index,
  )?
  onRequest;

  int get port => _server.port;

  static Future<_ModelServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final model = _ModelServer._(server);
    server.listen((request) async {
      Map<String, dynamic> body;
      try {
        body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
      } catch (error) {
        model.errors.add(error);
        await _writeJson(request, {}, status: 500);
        return;
      }
      model.requests.add(body);
      final index = model.requests.length;
      try {
        await model.onRequest?.call(request, body, index);
      } catch (error) {
        model.errors.add(error);
        await _writeJson(request, {}, status: 500);
      }
    });
    return model;
  }

  Future<void> close() => _server.close(force: true);
}

class _McpFixture {
  _McpFixture._(this._server);
  final HttpServer _server;
  final calls = <(String, Map<String, dynamic>)>[];
  final errors = <Object>[];
  int listCalls = 0;
  bool toolError = false;
  Completer<void>? holdFirstList;

  static const session = 'runtime-session';
  static const secret = 'mcp-super-secret-token';

  int get port => _server.port;
  String get url => 'http://127.0.0.1:$port/mcp';

  static Future<_McpFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mcp = _McpFixture._(server);
    server.listen((request) async {
      try {
        if (request.method == 'DELETE') {
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
          return;
        }
        expect(request.headers.value('authorization'), 'Bearer $secret');
        final body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        final method = body['method'] as String;
        if (method == 'initialize') {
          request.response.headers.set('Mcp-Session-Id', session);
          await _writeJson(request, {
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'protocolVersion': '2025-06-18',
              'capabilities': {
                'tools': <String, Object?>{},
              },
              'serverInfo': {'name': 'runtime-fixture', 'version': '0.1'},
            },
          });
          return;
        }
        expect(request.headers.value('mcp-session-id'), session);
        if (method == 'notifications/initialized') {
          request.response.statusCode = HttpStatus.accepted;
          await request.response.close();
          return;
        }
        if (method == 'tools/list') {
          mcp.listCalls++;
          if (mcp.listCalls == 1 && mcp.holdFirstList != null) {
            await mcp.holdFirstList!.future;
          }
          await _writeJson(request, {
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'tools': [
                {
                  'name': 'lookup',
                  'description': '查询一个词',
                  'inputSchema': _lookupSchema,
                },
                {
                  'name': 'count',
                  'description': '计数',
                  'inputSchema': _countSchema,
                },
                {
                  'name': 'argv',
                  'description': '接受命令数组',
                  'inputSchema': _argvSchema,
                },
              ],
            },
          });
          return;
        }
        if (method == 'tools/call') {
          final params = body['params'] as Map;
          final name = params['name'] as String;
          final arguments = Map<String, dynamic>.from(
            params['arguments'] as Map,
          );
          mcp.calls.add((name, arguments));
          final query = arguments['query'] ?? arguments['by'];
          await _writeJson(request, {
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'content': [
                {
                  'type': 'text',
                  'text': mcp.toolError ? 'fixture tool error' : 'found:$query',
                },
              ],
              'isError': mcp.toolError,
            },
          });
          return;
        }
        await _writeJson(request, {
          'jsonrpc': '2.0',
          'id': body['id'],
          'error': {'code': -32601, 'message': 'unsupported'},
        });
      } catch (error) {
        mcp.errors.add(error);
        await _writeJson(request, {}, status: 500);
      }
    });
    return mcp;
  }

  Future<void> close() => _server.close(force: true);
}

class _SessionExecutor implements AiSessionExecutor {
  _SessionExecutor({this.systemContext = ''});
  @override
  String systemContext;
  final commands = <String>[];
  final forwards = <(AiForwardRequest, bool)>[];
  bool cancelled = false;
  var _serial = 0;

  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    commands.add(command);
    onOutput('ok');
    return const AiCommandResult('ok', 0);
  }

  @override
  void cancel() => cancelled = true;

  @override
  Future<AiForwardResult> createPortForward(
    AiForwardRequest request, {
    required bool save,
  }) async {
    forwards.add((request, save));
    final port = 41000 + _serial++;
    return AiForwardResult(
      ruleId: 'rule-$port',
      name: request.name,
      localPort: port,
      targetHost: request.targetHost,
      targetPort: request.targetPort,
      url: 'http://127.0.0.1:$port/',
      saved: save,
    );
  }
}

AiSettings _settings(
  _ModelServer model, {
  String systemPrompt = _supplement,
  List<AiMcpServer> mcpServers = const [],
  AiProtocol protocol = AiProtocol.openai,
}) => AiSettings(
  baseUrl: 'http://127.0.0.1:${model.port}/v1',
  model: 'runtime-model',
  protocol: protocol,
  systemPrompt: systemPrompt,
  mcpServers: mcpServers,
);

AiMcpServer _mcpServerFixture(_McpFixture mcp) => AiMcpServer(
  id: 'mcp-1',
  name: '本地 MCP',
  url: mcp.url,
  headers: {'Authorization': 'Bearer ${_McpFixture.secret}'},
);

List<Map> _toolFunctions(Map<String, dynamic> body) => [
  for (final tool in body['tools'] as List) tool['function'] as Map,
];

Map<String, dynamic> _systemMessage(Map<String, dynamic> body) =>
    Map<String, dynamic>.from(
      (body['messages'] as List).firstWhere((m) => m['role'] == 'system')
          as Map,
    );

void main() {
  test('MCP 工具动态发现、完整 schema、强制同意且不泄露请求头', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index == 1
            ? _toolReply('lookup', {'query': 'alpha'})
            : _textReply('MCP 完成'),
      );
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);

    final run = task.start('查询 alpha');
    await _eventually(() => task.pending != null);
    final pending = task.pending!;
    expect(pending.name, 'lookup');
    expect(pending.requiresApproval, isTrue);
    expect(pending.command, contains('MCP'));
    expect(pending.command, contains('lookup'));
    expect(mcp.calls, isEmpty, reason: '未同意前绝不能调用 MCP 工具');
    expect(task.running, isTrue);

    task.approve(true, expectedCallId: 'stale-id');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(task.pending, isNotNull, reason: '过期点击不能批准后来的调用');
    expect(mcp.calls, isEmpty);

    final first = model.requests.single;
    final system = _systemMessage(first)['content'] as String;
    expect(system, contains(aiSystemPrompt));
    expect(system, contains(_supplement));
    expect(jsonEncode(first), isNot(contains(_McpFixture.secret)));
    final functions = _toolFunctions(first);
    final names = functions.map((item) => item['name']).toList();
    expect(
      names,
      containsAll(['run_command', 'create_port_forward', 'lookup', 'count']),
    );
    expect(
      functions.firstWhere((item) => item['name'] == 'lookup')['parameters'],
      _lookupSchema,
    );
    expect(
      functions.firstWhere((item) => item['name'] == 'count')['parameters'],
      _countSchema,
    );

    task.approve(true);
    await run;
    expect(mcp.errors, isEmpty);
    expect(model.errors, isEmpty);
    expect(task.failure, isNull);
    expect(mcp.calls, hasLength(1));
    expect(mcp.calls.single.$1, 'lookup');
    expect(mcp.calls.single.$2, {'query': 'alpha'});
    expect(task.entries.last.text, 'MCP 完成');
    final commandEntry = task.entries.firstWhere((entry) => entry.command);
    expect(commandEntry.output, contains('found:alpha'));
    final toolMessage = (model.requests[1]['messages'] as List).firstWhere(
      (message) => message['role'] == 'tool',
    );
    final toolResult =
        jsonDecode(toolMessage['content'] as String) as Map<String, dynamic>;
    expect(toolResult['untrusted'], isTrue);
    expect(toolResult['status'], 'ok');
  });

  test('Anthropic 同样发送并执行动态 MCP 工具，JSON 回退路径可用', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index == 1
            ? _anthropicToolReply('lookup', {'query': 'anthropic'})
            : _anthropicTextReply('Anthropic 完成'),
      );
    };
    final task = AiTaskController(
      settings: () => _settings(
        model,
        mcpServers: [_mcpServerFixture(mcp)],
        protocol: AiProtocol.anthropic,
      ),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    final run = task.start('Anthropic 查询');
    await _eventually(() => task.pending != null);
    expect(task.pending!.name, 'lookup');
    final first = model.requests.single;
    expect(first['system'], isA<String>());
    expect(first['system'] as String, contains(_supplement));
    final tools = (first['tools'] as List).cast<Map>();
    expect(
      tools.map((tool) => tool['name']),
      containsAll(['run_command', 'create_port_forward', 'lookup', 'count']),
    );
    expect(
      tools.firstWhere((tool) => tool['name'] == 'lookup')['input_schema'],
      _lookupSchema,
    );
    expect(jsonEncode(first), isNot(contains(_McpFixture.secret)));
    expect(mcp.calls, isEmpty);
    task.approve(true);
    await run;
    expect(model.errors, isEmpty);
    expect(mcp.errors, isEmpty);
    expect(mcp.calls.single.$1, 'lookup');
    expect(mcp.calls.single.$2, {'query': 'anthropic'});
    expect(task.entries.last.text, 'Anthropic 完成');
    final userTurn = (model.requests[1]['messages'] as List).last as Map;
    final toolResult = (userTurn['content'] as List)
        .cast<Map>()
        .firstWhere((block) => block['type'] == 'tool_result');
    final content =
        jsonDecode(toolResult['content'] as String) as Map<String, dynamic>;
    expect(content['untrusted'], isTrue);
    expect(content['status'], 'ok');
  });

  test('MCP 参数不符合服务端 schema 时拒绝执行', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(request, _toolReply('lookup', {'query': 5}));
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    await task.start('错误参数');
    expect(task.failure, contains('无效的执行请求'));
    expect(mcp.calls, isEmpty);
    expect(task.pending, isNull);
  });

  test('MCP 工具可合法使用 command 数组等任意参数类型', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index == 1
            ? _toolReply('argv', {
                'command': ['uname', '-a'],
              })
            : _textReply('数组参数完成'),
      );
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    final run = task.start('使用数组参数');
    await _eventually(() => task.pending != null);
    expect(task.pending!.name, 'argv');
    task.approve(true);
    await run;
    expect(task.failure, isNull);
    expect(mcp.calls.single.$1, 'argv');
    expect(mcp.calls.single.$2, {
      'command': ['uname', '-a'],
    });
    expect(task.entries.last.text, '数组参数完成');
  });

  test('跨回合重复的模型调用 ID 不能复用旧审批令牌', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index <= 2
            ? _toolReply('lookup', {'query': 'nonce'}, id: 'duplicate-id')
            : _textReply('令牌测试完成'),
      );
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);

    final firstRun = task.start('第一回合');
    await _eventually(() => task.pending != null);
    final staleId = task.pending!.id;
    task.stop();
    await firstRun;

    final secondRun = task.start('第二回合');
    await _eventually(() => task.pending != null);
    final currentId = task.pending!.id;
    expect(currentId, isNot(staleId));
    task.approve(true, expectedCallId: staleId);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(task.pending, isNotNull, reason: '旧令牌不能批准新回合的同名调用');
    expect(mcp.calls, isEmpty);
    task.approve(true, expectedCallId: currentId);
    await secondRun;
    expect(mcp.calls, hasLength(1));
  });

  test('旧回合 MCP 发现被停止后，新回合客户端不被旧 finally 关闭', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    final hold = Completer<void>();
    mcp.holdFirstList = hold;
    model.onRequest = (request, body, index) async {
      await _writeJson(request, _textReply('新回合完成'));
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);

    final firstRun = task.start('第一回合');
    await _eventually(() => mcp.listCalls >= 1);
    task.stop();
    final secondRun = task.start('第二回合');
    await _eventually(() => model.requests.isNotEmpty);
    final names = _toolFunctions(
      model.requests.single,
    ).map((item) => item['name']);
    expect(names, contains('lookup'));
    await secondRun;
    expect(task.failure, isNull);
    expect(task.entries.last.text, '新回合完成');
    hold.complete();
    await firstRun;
    expect(task.failure, isNull);
    expect(task.running, isFalse);
  });

  test('拒绝 MCP 调用后不产生副作用并保留真实中断状态', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(request, _toolReply('lookup', {'query': 'beta'}));
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);

    final run = task.start('不要执行');
    await _eventually(() => task.pending != null);
    task.approve(false);
    await run;
    expect(task.running, isFalse);
    expect(task.pending, isNull);
    expect(mcp.calls, isEmpty);
    final entry = task.entries.firstWhere((item) => item.command);
    expect(entry.interruption, '未执行');
    expect(entry.started, isNot(true));
  });

  test('自动审批与切换自动模式都不能批准 MCP 或端口转发', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index == 1
            ? _toolReply('lookup', {'query': 'gamma'})
            : _textReply('完成'),
      );
    };
    final executor = _SessionExecutor();
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: () => executor,
      connected: () => true,
      approvalMode: AiApprovalMode.auto,
    );
    addTearDown(task.dispose);

    final run = task.start('自动模式测试');
    await _eventually(() => task.pending != null);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(task.pending, isNotNull, reason: '自动模式不得批准 MCP 调用');
    expect(mcp.calls, isEmpty);
    task.setApprovalMode(AiApprovalMode.manual);
    task.setApprovalMode(AiApprovalMode.auto);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(task.pending, isNotNull, reason: '切换自动模式不得批准 MCP 调用');
    expect(mcp.calls, isEmpty);
    task.approve(true);
    await run;
    expect(mcp.calls, hasLength(1));
    expect(task.entries.last.text, '完成');

    final forwardModel = await _ModelServer.start();
    addTearDown(forwardModel.close);
    forwardModel.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index == 1
            ? _toolReply('create_port_forward', {
                'name': '改造成本地转发',
                'local_port': 0,
                'target_host': '127.0.0.1',
                'target_port': 8080,
                'reason': '访问仅内网可见的服务',
              })
            : _textReply('转发就绪'),
      );
    };
    final forwardExecutor = _SessionExecutor();
    final forwardTask = AiTaskController(
      settings: () => _settings(forwardModel),
      executorFactory: () => forwardExecutor,
      connected: () => true,
      approvalMode: AiApprovalMode.auto,
    );
    addTearDown(forwardTask.dispose);
    final forwardRun = forwardTask.start('需要端口转发');
    await _eventually(() => forwardTask.pending != null);
    expect(forwardTask.pending!.name, 'create_port_forward');
    expect(forwardTask.pending!.command, contains('本地端口转发'));
    expect(forwardTask.pending!.command, contains('自动分配'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(forwardExecutor.forwards, isEmpty, reason: '自动模式不得创建转发');
    forwardTask.approve(
      true,
      saveForward: true,
      expectedCallId: 'stale-id',
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(forwardTask.pending, isNotNull);
    expect(forwardExecutor.forwards, isEmpty);
    forwardTask.approve(
      true,
      saveForward: true,
      expectedCallId: forwardTask.pending!.id,
    );
    await forwardRun;
    expect(forwardExecutor.forwards, hasLength(1));
    expect(forwardExecutor.forwards.single.$2, isTrue);
    expect(forwardTask.entries.last.text, '转发就绪');
    final forwardEntry = forwardTask.entries.firstWhere(
      (entry) => entry.command,
    );
    expect(forwardEntry.output, contains('http://127.0.0.1:41000/'));
    expect(forwardEntry.output, contains('规则已保存到主机端口转发列表'));
  });

  test('只读模式不提供 MCP 或转发工具，模型请求也不会执行', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(request, _textReply('只读完成'));
    };
    final executor = _SessionExecutor();
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: () => executor,
      connected: () => true,
      approvalMode: AiApprovalMode.readOnly,
    );
    addTearDown(task.dispose);
    await task.start('只读检查');
    expect(mcp.listCalls, 0, reason: '只读模式不应发现 MCP 工具');
    final functions = _toolFunctions(model.requests.single);
    expect(
      functions.map((item) => item['name']),
      ['list_directory', 'read_file', 'search_text', 'system_info'],
    );
    expect(executor.forwards, isEmpty);

    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        _toolReply('create_port_forward', {
          'name': '不该创建',
          'local_port': 0,
          'target_host': '127.0.0.1',
          'target_port': 8080,
          'reason': '只读模式尝试',
        }),
      );
    };
    await task.start('只读模式尝试转发');
    expect(task.failure, contains('无效的执行请求'));
    expect(executor.forwards, isEmpty);
    expect(mcp.calls, isEmpty);
  });

  test('MCP 工具级错误保留为不可信结果，普通失败只影响该工具', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start()..toolError = true;
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(
        request,
        index == 1
            ? _toolReply('lookup', {'query': 'missing'})
            : _textReply('已知晓错误'),
      );
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    final run = task.start('读取一个不存在的词');
    await _eventually(() => task.pending != null);
    task.approve(true);
    await run;
    expect(task.failure, isNull);
    expect(task.entries.last.text, '已知晓错误');
    final toolMessage = (model.requests[1]['messages'] as List).firstWhere(
      (message) => message['role'] == 'tool',
    );
    final toolResult =
        jsonDecode(toolMessage['content'] as String) as Map<String, dynamic>;
    expect(toolResult['status'], 'tool_error');
    expect(toolResult['untrusted'], isTrue);
    expect(
      '${(toolResult['result'] as Map)['isError']}',
      'true',
    );
    final entry = task.entries.firstWhere((item) => item.command);
    expect(entry.interruption, 'MCP 工具返回错误');
  });

  test('请求重试不会重放已执行的 MCP 工具副作用', () async {
    final model = await _ModelServer.start();
    final mcp = await _McpFixture.start();
    addTearDown(model.close);
    addTearDown(mcp.close);
    model.onRequest = (request, body, index) async {
      if (index == 1) {
        await _writeJson(request, _toolReply('lookup', {'query': 'once'}));
        return;
      }
      if (index == 2) {
        // Simulate a gateway reset after one SSE chunk: the client retries the
        // same request, which must not re-run the tool above.
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
      await _writeJson(request, _textReply('重试完成'));
    };
    final task = AiTaskController(
      settings: () => _settings(model, mcpServers: [_mcpServerFixture(mcp)]),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    final run = task.start('只执行一次');
    await _eventually(() => task.pending != null);
    task.approve(true);
    await run;
    expect(model.requests, hasLength(3));
    expect(mcp.calls, hasLength(1), reason: '重试只能是请求重发，不能重放工具');
    expect(
      jsonEncode(model.requests[1]['messages']),
      jsonEncode(model.requests[2]['messages']),
    );
    expect(task.entries.last.text, '重试完成');
  });

  test('启用的 MCP 服务器发现失败显示可操作原因而不是静默忽略', () async {
    final model = await _ModelServer.start();
    addTearDown(model.close);
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = unused.port;
    await unused.close();
    model.onRequest = (request, body, index) async {
      await _writeJson(request, _textReply('继续进行'));
    };
    final task = AiTaskController(
      settings: () => _settings(
        model,
        mcpServers: [
          AiMcpServer(
            id: 'dead',
            name: '失效服务器',
            url: 'http://127.0.0.1:$deadPort/mcp',
            headers: const {'Authorization': 'Bearer never-print-me'},
          ),
        ],
      ),
      executorFactory: _SessionExecutor.new,
      connected: () => true,
    );
    addTearDown(task.dispose);
    await task.start('没有 MCP 也要继续');
    expect(task.failure, isNull);
    expect(task.entries.last.text, '继续进行');
    final notice = task.entries.firstWhere((entry) => entry.notice == true);
    expect(notice.text, contains('失效服务器'));
    expect(notice.text, contains('工具列表获取失败'));
    expect(notice.text, contains('设置'));
    expect(notice.text, isNot(contains('never-print-me')));
  });

  test('恢复历史时刷新当前主机上下文与可编辑提示，不复用旧地址', () async {
    final model = await _ModelServer.start();
    addTearDown(model.close);
    model.onRequest = (request, body, index) async {
      await _writeJson(request, _textReply('第 $index 轮完成'));
    };
    final root = await Directory.systemTemp.createTemp('harbor-ai-runtime');
    addTearDown(() async {
      for (var attempt = 0; attempt < 20; attempt++) {
        try {
          if (await root.exists()) await root.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final store = AiConversationStore(
      secrets: MemoryStore(),
      directory: () async => root,
    );
    const scope = 'runtime-host';
    const oldContext =
        '主机名称："旧主机"\n实际 SSH 地址："10.0.0.5"\n地址类型：私有地址';
    const newContext =
        '主机名称："新主机"\n实际 SSH 地址："192.168.1.9"\n地址类型：私有地址';

    final first = AiTaskController(
      settings: () => _settings(model),
      executorFactory: () => _SessionExecutor(systemContext: oldContext),
      connected: () => true,
      historyStore: store,
      historyScope: scope,
    );
    await first.start('第一轮问题');
    final id = first.activeConversationId!;
    await first.loadHistory();
    first.dispose();

    final secondExecutor = _SessionExecutor(systemContext: newContext);
    final second = AiTaskController(
      settings: () => _settings(model),
      executorFactory: () => secondExecutor,
      connected: () => true,
      historyStore: store,
      historyScope: scope,
    );
    addTearDown(second.dispose);
    await second.loadHistory();
    await second.openConversation(id);
    await second.start('继续第二轮');
    expect(model.errors, isEmpty);
    final resumed = model.requests.last;
    final system = _systemMessage(resumed)['content'] as String;
    expect(system, contains(aiSystemPrompt));
    expect(system, contains(_supplement));
    expect(system, contains('192.168.1.9'));
    expect(system, contains('新主机'));
    expect(system, isNot(contains('10.0.0.5')));
    expect(system, isNot(contains('旧主机')));
    expect(jsonEncode(resumed), contains('第一轮问题'));
    expect(second.entries.last.text, '第 2 轮完成');
  });
}
