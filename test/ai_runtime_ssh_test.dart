import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/ssh_ai_executor.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/network_identity.dart';
import 'package:harbor_ssh/domain/port_forward.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';

import 'support.dart';

const _password = 'fixture-password';
const _scope = 'real-host|runtime';

Host _host() => const Host(
  id: 'ai-forward',
  name: '内网目标',
  address: '10.20.30.40',
  port: 22,
  username: 'tester',
);

const _supplement = '用户补充：只回答必要内容。';

Future<void> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) fail('条件在 $timeout 内未满足');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _writeJson(HttpRequest request, Object body) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

class _ModelServer {
  _ModelServer._(this._server);
  final HttpServer _server;
  final requests = <Map<String, dynamic>>[];
  final errors = <Object>[];
  Future<void> Function(HttpRequest request, int index)? onRequest;

  int get port => _server.port;

  static Future<_ModelServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final model = _ModelServer._(server);
    server.listen((request) async {
      try {
        final body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        model.requests.add(body);
        await model.onRequest?.call(request, model.requests.length);
      } catch (error) {
        model.errors.add(error);
        await _writeJson(request, {});
      }
    });
    return model;
  }

  Future<void> close() => _server.close(force: true);
}

Map<String, dynamic> _textReply(String text) => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': text},
    },
  ],
};

Map<String, dynamic> _toolReply(String name, Map<String, dynamic> args) => {
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'forward-1',
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(args)},
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> _systemMessage(Map<String, dynamic> body) =>
    Map<String, dynamic>.from(
      (body['messages'] as List).firstWhere((m) => m['role'] == 'system')
          as Map,
    );

Future<HostRepository> _repository(
  Host host,
  int port, {
  String activeId = 'office',
  MemoryStore? preferences,
}) async {
  final repository = HostRepository(
    preferences: preferences ?? MemoryStore(),
    secrets: MemoryStore(),
  );
  await repository.saveNetworkIdentities(
    NetworkIdentities(
      activeId: activeId,
      identities: [
        NetworkIdentity(
          id: 'office',
          name: '办公室网络',
          overrides: {
            host.id: EndpointOverride(address: '127.0.0.1', port: port),
          },
        ),
        NetworkIdentity(
          id: 'tunnel',
          name: '隧道网络',
          overrides: {
            host.id: EndpointOverride(address: '127.0.0.1', port: port),
          },
        ),
      ],
    ),
  );
  return repository;
}

Future<(Process, Map<String, dynamic>)> _startFixture() async {
  final python = Platform.environment['HARBOR_TEST_PYTHON'] ?? 'python';
  final process = await Process.start(python, ['tool/ai_forward_fixture.py']);
  final ready = Completer<Map<String, dynamic>>();
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (!ready.isCompleted) {
          ready.complete(
            Map<String, dynamic>.from(jsonDecode(line) as Map),
          );
        }
      });
  process.stderr.transform(utf8.decoder).listen((line) {
    if (!ready.isCompleted) ready.completeError(StateError(line));
  });
  final config = await ready.future.timeout(const Duration(seconds: 30));
  return (process, config);
}

void main() {
  final enabled = Platform.environment['HARBOR_SSH_INTEGRATION'] == '1';

  group(
    '真实 loopback SSH 的 AI 转发与主机上下文',
    () {
      late Process fixture;
      late int sshPort;
      late int targetPort;

      setUpAll(() async {
        final started = await _startFixture();
        fixture = started.$1;
        sshPort = started.$2['port'] as int;
        targetPort = started.$2['targetPort'] as int;
      });

      tearDownAll(() async {
        fixture.kill();
        await fixture.exitCode;
      });

      test('实际绑定回环端口、返回真实 URL、保存规则并刷新修订号', () async {
        final host = _host();
        final repository = await _repository(host, sshPort);
        final connection = SshConnection(id: 'real-forward', host: host);
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
          openShell: false,
        );
        expect(connection.status, ConnectionStatus.connected);
        expect(connection.connectedEndpoint, ('127.0.0.1', sshPort));

        final executor = connection.createAiExecutor();
        expect(executor, isA<AiSessionExecutor>());
        final session = executor as AiSessionExecutor;
        final context = session.systemContext;
        expect(context, contains('办公室网络'));
        expect(context, contains('127.0.0.1'));
        expect(context, contains('$sshPort'));
        expect(context, contains('私有'));
        expect(context, isNot(contains('10.20.30.40')));
        expect(context, contains(aiPortForwardToolName));

        final result = await session.createPortForward(
          AiForwardRequest(
            name: '真实转发',
            localPort: 0,
            targetPort: targetPort,
          ),
          save: true,
        );
        expect(result.localPort, inInclusiveRange(1, 65535));
        expect(result.url, 'http://127.0.0.1:${result.localPort}/');
        expect(result.saved, isTrue);
        expect(result.route, contains('127.0.0.1:${result.localPort}'));

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(result.url));
          final response = await request.close();
          expect(response.statusCode, 200);
          expect(await utf8.decoder.bind(response).join(), 'forwarded-ok\n');
        } finally {
          client.close(force: true);
        }

        final rules = await connection.portForwardStore!.load();
        expect(rules, hasLength(1));
        expect(rules.single.id, result.ruleId);
        expect(rules.single.bindHost, '127.0.0.1');
        expect(rules.single.type, PortForwardType.local);
        expect(rules.single.targetHost, '127.0.0.1');
        expect(rules.single.targetPort, targetPort);
        expect(connection.savedPortForwardRevision, 1);
        expect(connection.portForwards.activeCount, 1);
      });

      test('两台同主机会话并发保存规则都保留', () async {
        final host = _host();
        final preferences = MemoryStore();
        final repository = await _repository(
          host,
          sshPort,
          preferences: preferences,
        );
        final first = SshConnection(id: 'concurrent-a', host: host);
        final second = SshConnection(id: 'concurrent-b', host: host);
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        await first.connect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
          openShell: false,
        );
        await second.connect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
          openShell: false,
        );
        final firstSession = first.createAiExecutor() as AiSessionExecutor;
        final secondSession = second.createAiExecutor() as AiSessionExecutor;
        expect(
          identical(
            first.portForwardStore!.preferences,
            second.portForwardStore!.preferences,
          ),
          isTrue,
        );
        expect(first.portForwardStore!.hostId, second.portForwardStore!.hostId);
        final saved = await Future.wait([
          firstSession.createPortForward(
            AiForwardRequest(
              name: '并发规则 A',
              localPort: 0,
              targetPort: targetPort,
            ),
            save: true,
          ),
          secondSession.createPortForward(
            AiForwardRequest(
              name: '并发规则 B',
              localPort: 0,
              targetPort: targetPort,
            ),
            save: true,
          ),
        ]);
        expect(saved.every((item) => item.saved), isTrue);
        final rules = await first.portForwardStore!.load();
        expect(rules, hasLength(2));
        expect(rules.map((rule) => rule.id), containsAll(saved.map((r) => r.ruleId)));
        expect(first.savedPortForwardRevision, 1);
        expect(second.savedPortForwardRevision, 1);
      });

      test('保存失败如实报告且不留下未追踪的监听', () async {
        final host = _host();
        final preferences = MemoryStore();
        final repository = await _repository(
          host,
          sshPort,
          preferences: preferences,
        );
        final connection = SshConnection(id: 'real-save-fail', host: host);
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
          openShell: false,
        );
        final session = connection.createAiExecutor() as AiSessionExecutor;
        preferences.failWrites = true;
        await expectLater(
          session.createPortForward(
            AiForwardRequest(
              name: '无法保存',
              localPort: 0,
              targetPort: targetPort,
            ),
            save: true,
          ),
          throwsA(
            isA<AiFailure>()
                .having((error) => error.message, 'message', contains('保存规则失败'))
                .having(
                  (error) => error.message,
                  'message',
                  contains('disk unavailable'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('转发已停止'),
                ),
          ),
        );
        expect(connection.savedPortForwardRevision, 0);
        expect(connection.portForwards.activeCount, 0);

        preferences.failWrites = false;
        final saved = await session.createPortForward(
          AiForwardRequest(
            name: '恢复保存',
            localPort: 0,
            targetPort: targetPort,
          ),
          save: true,
        );
        expect(saved.saved, isTrue);
        expect(connection.savedPortForwardRevision, 1);
      });

      test('完整 AI 对话使用真实端点上下文，恢复历史时刷新为当前网络身份', () async {
        final host = _host();
        final repository = await _repository(host, sshPort);
        final connection = SshConnection(id: 'real-context', host: host);
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
          openShell: false,
        );
        final model = await _ModelServer.start();
        addTearDown(model.close);
        model.onRequest = (request, index) async {
          await _writeJson(request, _textReply('第 $index 轮真实完成'));
        };
        final root = await Directory.systemTemp.createTemp('harbor-ai-ssh');
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
        final settings = AiSettings(
          baseUrl: 'http://127.0.0.1:${model.port}/v1',
          model: 'ssh-runtime-model',
          systemPrompt: _supplement,
        );
        final first = AiTaskController(
          settings: () => settings,
          executorFactory: connection.createAiExecutor,
          connected: () => connection.status == ConnectionStatus.connected,
          historyStore: store,
          historyScope: _scope,
        );
        await first.start('第一轮真实问题');
        expect(model.errors, isEmpty);
        final id = first.activeConversationId!;
        await first.loadHistory();
        first.dispose();

        final firstSystem =
            _systemMessage(model.requests.first)['content'] as String;
        expect(firstSystem, contains(aiSystemPrompt));
        expect(firstSystem, contains(_supplement));
        expect(firstSystem, contains('办公室网络'));
        expect(firstSystem, contains('127.0.0.1'));
        expect(firstSystem, contains('$sshPort'));
        expect(firstSystem, contains('私有'));
        expect(firstSystem, isNot(contains('10.20.30.40')));

        await repository.saveNetworkIdentities(
          NetworkIdentities(
            activeId: 'tunnel',
            identities: [
              NetworkIdentity(
                id: 'office',
                name: '办公室网络',
                overrides: {
                  host.id: EndpointOverride(
                    address: '127.0.0.1',
                    port: sshPort,
                  ),
                },
              ),
              NetworkIdentity(
                id: 'tunnel',
                name: '隧道网络',
                overrides: {
                  host.id: EndpointOverride(
                    address: '127.0.0.1',
                    port: sshPort,
                  ),
                },
              ),
            ],
          ),
        );
        connection.close();
        await connection.reconnect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
        );
        await _eventually(
          () => connection.status == ConnectionStatus.connected,
        );

        final second = AiTaskController(
          settings: () => settings,
          executorFactory: connection.createAiExecutor,
          connected: () => connection.status == ConnectionStatus.connected,
          historyStore: store,
          historyScope: _scope,
        );
        addTearDown(second.dispose);
        await second.loadHistory();
        await second.openConversation(id);
        await second.start('继续第二轮真实问题');
        expect(model.errors, isEmpty);
        final resumed = _systemMessage(model.requests.last)['content'] as String;
        expect(resumed, contains('隧道网络'));
        expect(resumed, contains('127.0.0.1'));
        expect(resumed, isNot(contains('办公室网络')));
        expect(jsonEncode(model.requests.last), contains('第一轮真实问题'));
        expect(second.entries.last.text, '第 2 轮真实完成');
      });

      test('转发完整 AI 工具流程：强制同意、保存选项与实际 URL 回传', () async {
        final host = _host();
        final repository = await _repository(host, sshPort);
        final connection = SshConnection(id: 'real-tool', host: host);
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: _password),
          repository,
          (_, _) async => true,
          openShell: false,
        );
        final model = await _ModelServer.start();
        addTearDown(model.close);
        model.onRequest = (request, index) async {
          await _writeJson(
            request,
            index == 1
                ? _toolReply('create_port_forward', {
                    'name': 'AI 真实转发',
                    'local_port': 0,
                    'target_host': '127.0.0.1',
                    'target_port': targetPort,
                    'reason': '访问仅服务器侧可见的 HTTP 服务',
                  })
                : _textReply('已通过真实转发访问'),
          );
        };
        final task = AiTaskController(
          settings: () => AiSettings(
            baseUrl: 'http://127.0.0.1:${model.port}/v1',
            model: 'ssh-runtime-model',
          ),
          executorFactory: connection.createAiExecutor,
          connected: () => connection.status == ConnectionStatus.connected,
          approvalMode: AiApprovalMode.auto,
        );
        addTearDown(task.dispose);
        final run = task.start('创建端口转发并访问');
        await _eventually(() => task.pending != null);
        expect(task.pending!.name, 'create_port_forward');
        expect(task.pending!.requiresApproval, isTrue);
        expect(connection.portForwards.activeCount, 0);
        task.approve(true, saveForward: true);
        await run;
        expect(model.errors, isEmpty);
        expect(task.failure, isNull);
        final entry = task.entries.firstWhere((item) => item.command);
        expect(entry.output, contains('127.0.0.1'));
        expect(entry.output, contains('规则已保存到主机端口转发列表'));
        final rules = await connection.portForwardStore!.load();
        expect(rules, hasLength(1));
        expect(rules.single.bindHost, '127.0.0.1');
        expect(connection.savedPortForwardRevision, 1);
        expect(connection.portForwards.activeCount, 1);
        final toolMessage = (model.requests[1]['messages'] as List).firstWhere(
          (message) => message['role'] == 'tool',
        );
        final result =
            jsonDecode(toolMessage['content'] as String) as Map<String, dynamic>;
        expect(result['status'], 'ok');
        expect(result['saved'], isTrue);
        expect(result['url'], startsWith('http://127.0.0.1:'));
        expect(result['localPort'], inInclusiveRange(1, 65535));
      });
    },
    skip: enabled ? null : '设置 HARBOR_SSH_INTEGRATION=1 运行真实 SSH 测试',
  );

  test('取消转发创建后撤销已绑定的监听并如实报错', () async {
    final started = Completer<AiForwardResult>();
    final stopped = <String>[];
    final executor = SshAiExecutor(
      (_) async => throw StateError('未使用'),
      systemContext: '',
      startForward: (request, {required save}) => started.future,
      stopForward: (ruleId) async => stopped.add(ruleId),
    );
    final pending = executor.createPortForward(
      const AiForwardRequest(
        name: '取消中的转发',
        localPort: 0,
        targetPort: 8080,
      ),
      save: false,
    );
    executor.cancel();
    started.complete(
      const AiForwardResult(
        ruleId: 'rule-cancelled',
        name: '取消中的转发',
        localPort: 42000,
        targetHost: '127.0.0.1',
        targetPort: 8080,
        url: 'http://127.0.0.1:42000/',
        saved: false,
      ),
    );
    await expectLater(
      pending,
      throwsA(
        isA<AiFailure>().having(
          (error) => error.message,
          'message',
          contains('端口转发已撤销'),
        ),
      ),
    );
    expect(stopped, ['rule-cancelled']);
  });
}
