import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/mcp_client.dart';
import 'package:harbor_ssh/domain/ai_mcp.dart';

const _session = 'session-alpha';
const _secret = 'secret-bearer-token';

AiMcpServer _serverAt(
  int port, {
  String path = '/mcp',
  Map<String, String> headers = const {'Authorization': 'Bearer $_secret'},
}) => AiMcpServer(
  id: 'mcp-1',
  name: '本地 MCP',
  url: 'http://127.0.0.1:$port$path',
  headers: headers,
);

Map<String, Object?> _initResult({String version = '2025-06-18'}) => {
  'protocolVersion': version,
  'capabilities': {
    'tools': <String, Object?>{},
  },
  'serverInfo': {'name': 'fixture', 'version': '0.1'},
};

Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

Future<void> _sendJson(
  HttpRequest request,
  Map<String, Object?> body, {
  int status = 200,
  Map<String, String> headers = const {},
}) async {
  request.response.statusCode = status;
  for (final entry in headers.entries) {
    request.response.headers.set(entry.key, entry.value);
  }
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<void> _sendAccepted(HttpRequest request) async {
  request.response.statusCode = HttpStatus.accepted;
  await request.response.close();
}

void _writeHttpChunk(Socket socket, String text) {
  final bytes = utf8.encode(text);
  socket.add(utf8.encode('${bytes.length.toRadixString(16)}\r\n'));
  socket.add(bytes);
  socket.add(utf8.encode('\r\n'));
}

Matcher _doesNotLeakSecret(String secret) => allOf(
  isNot(contains(secret)),
  isNot(contains(secret.substring(0, 40))),
  isNot(contains(secret.substring(secret.length - 40))),
);

Map<String, Object?> _response(Object? id, Map<String, Object?> result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

Map<String, Object?> _error(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};

void main() {
  test('完整会话：初始化、分页工具列表、调用工具并删除会话', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    final deletedSessions = <String?>[];
    final toolCalls = <Map>[];
    server.listen((request) async {
      expect(request.uri.path, '/mcp');
      if (request.method == 'DELETE') {
        deletedSessions.add(request.headers.value('mcp-session-id'));
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      expect(request.method, 'POST');
      expect(request.headers.value('authorization'), 'Bearer $_secret');
      expect(
        request.headers.value('accept'),
        allOf(contains('application/json'), contains('text/event-stream')),
      );
      expect(
        request.headers.value('content-type'),
        contains('application/json'),
      );
      expect(request.headers.value('mcp-protocol-version'), '2025-06-18');
      final body = await _readBody(request);
      final method = body['method'] as String;
      methods.add(method);
      if (method == 'initialize') {
        expect(request.headers.value('mcp-session-id'), isNull);
        expect(body['params']['clientInfo']['name'], 'harbor-ssh');
        expect(body['params']['protocolVersion'], '2025-06-18');
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      expect(request.headers.value('mcp-session-id'), _session);
      if (method == 'notifications/initialized') {
        expect(body.containsKey('id'), isFalse);
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        final params = body['params'] as Map?;
        final cursor = params?['cursor'];
        if (cursor == null) {
          await _sendJson(
            request,
            _response(body['id'], {
              'tools': [
                {
                  'name': 'alpha',
                  'description': '第一个工具',
                  'inputSchema': {
                    'type': 'object',
                    'properties': {
                      'q': {'type': 'string'},
                    },
                  },
                },
                {'name': 'beta', 'description': '第二个工具'},
              ],
              'nextCursor': 'cursor-2',
            }),
          );
        } else {
          expect(cursor, 'cursor-2');
          await _sendJson(
            request,
            _response(body['id'], {
              'tools': [
                {'name': 'alpha', 'description': '重复工具'},
                {'name': 'gamma'},
              ],
            }),
          );
        }
        return;
      }
      if (method == 'tools/call') {
        toolCalls.add(Map<String, dynamic>.from(body['params'] as Map));
        await _sendJson(
          request,
          _response(body['id'], {
            'content': [
              {'type': 'text', 'text': '第一段'},
              {'type': 'text', 'text': '第二段'},
            ],
            'structuredContent': {'answer': 42},
          }),
        );
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    final tools = await client.listTools();
    expect(methods, [
      'initialize',
      'notifications/initialized',
      'tools/list',
      'tools/list',
    ]);
    // 连接测试只列工具，不能产生工具调用等副作用。
    expect(toolCalls, isEmpty);
    expect(tools.map((tool) => tool.name).toList(), ['alpha', 'beta', 'gamma']);
    final alpha = tools.first;
    expect(alpha.description, '第一个工具');
    expect(alpha.inputSchema['type'], 'object');
    expect(tools[1].inputSchema, isEmpty);
    expect(tools[2].description, '');

    final result = await client.callTool('alpha', {'q': '值'});
    expect(toolCalls.single['name'], 'alpha');
    expect(toolCalls.single['arguments'], {'q': '值'});
    expect(result['isError'], isFalse);
    expect(result['text'], '第一段\n第二段');
    expect((result['content'] as List).length, 2);
    expect((result['structuredContent'] as Map)['answer'], 42);

    await client.close();
    expect(deletedSessions, [_session]);
    await expectLater(client.listTools(), throwsA(isA<McpFailure>()));
  });

  test('SSE 响应：忽略注释和通知，支持分片、CRLF 与同一事件多行消息', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.bufferOutput = false;
      try {
        if (method == 'tools/list') {
          final payload =
              ': keep-alive\r\n\r\n'
              'event: message\r\n'
              'id: 7\r\n'
              'data: ${jsonEncode({
                'jsonrpc': '2.0',
                'method': 'notifications/progress',
                'params': {'progress': 50},
              })}\r\n\r\n'
              'data: ${jsonEncode(_response(body['id'], {
                'tools': [
                  {'name': 'remote', 'description': '远端工具'},
                ],
              }))}\r\n\r\n';
          final bytes = utf8.encode(payload);
          final half = bytes.length ~/ 2;
          request.response.add(bytes.sublist(0, half));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          request.response.add(bytes.sublist(half));
          await request.response.close();
          return;
        }
        if (method == 'tools/call') {
          // 一个事件的多个 data 行共同构成事件数据。
          final payload =
              'data: ${jsonEncode({
                'jsonrpc': '2.0',
                'method': 'notifications/progress',
                'params': {'progress': 100},
              })}\n'
              'data: ${jsonEncode(_response(body['id'], {
                'content': [
                  {'type': 'text', 'text': '中文结果'},
                ],
                'isError': true,
              }))}\n\n';
          final bytes = utf8.encode(payload);
          final split = bytes.length - 5;
          request.response.add(bytes.sublist(0, split));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          request.response.add(bytes.sublist(split));
          await request.response.close();
          return;
        }
        fail('未预期的 MCP 方法 $method');
      } catch (_) {
        // 客户端收到结果后会主动断开流，写入可能失败。
      }
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    final tools = await client.listTools();
    expect(tools.single.name, 'remote');
    expect(tools.single.description, '远端工具');
    final result = await client.callTool('remote', {});
    expect(result['isError'], isTrue);
    expect(result['text'], '中文结果');
    expect(result.containsKey('structuredContent'), isFalse);
  });

  test('重定向被阻止且凭据不会转发到新地址，认证失败不泄露请求头', () async {
    var leaked = 0;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => target.close(force: true));
    target.listen((request) async {
      leaked++;
      await request.drain<void>();
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    final seenHeaders = <String?>[];
    origin.listen((request) async {
      await request.drain<void>();
      seenHeaders.add(request.headers.value('authorization'));
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/mcp',
        );
        await request.response.close();
        return;
      }
      await _sendJson(
        request,
        _error(
          null,
          -32001,
          'unauthorized ${request.headers.value('authorization')}',
        ),
        status: HttpStatus.unauthorized,
      );
    });

    final redirecting = McpClient(
      _serverAt(origin.port, path: '/redirect'),
    );
    addTearDown(redirecting.close);
    await expectLater(
      redirecting.listTools(),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(contains('重定向'), isNot(contains(_secret))),
        ),
      ),
    );
    expect(leaked, 0);
    expect(seenHeaders.single, 'Bearer $_secret');

    final rejecting = McpClient(_serverAt(origin.port, path: '/reject'));
    addTearDown(rejecting.close);
    await expectLater(
      rejecting.listTools(),
      throwsA(
        isA<McpFailure>()
            .having(
              (failure) => failure.message,
              'message',
              contains('认证'),
            )
            .having(
              (failure) => failure.message,
              'message',
              allOf(isNot(contains(_secret)), isNot(contains('Bearer'))),
            ),
      ),
    );
  });

  test('会话过期（404）后自动重新初始化并重试一次', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var initializations = 0;
    final sessionHeaders = <String?>[];
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      sessionHeaders.add(request.headers.value('mcp-session-id'));
      if (method == 'initialize') {
        initializations++;
        final session = 'session-$initializations';
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        if (request.headers.value('mcp-session-id') == 'session-1') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        expect(request.headers.value('mcp-session-id'), 'session-2');
        await _sendJson(
          request,
          _response(body['id'], {
            'tools': [
              {'name': 'after-restart'},
            ],
          }),
        );
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    final tools = await client.listTools();
    expect(tools.single.name, 'after-restart');
    expect(initializations, 2);
    expect(sessionHeaders, [
      null,
      'session-1',
      'session-1',
      null,
      'session-2',
      'session-2',
    ]);
  });

  test('工具调用遇到会话 404 时不重放，下一次请求重新建会话', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var initializations = 0;
    var toolCalls = 0;
    final methods = <String>[];
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      methods.add(method);
      if (method == 'initialize') {
        initializations++;
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': 'session-$initializations'},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/call') {
        toolCalls++;
        expect(request.headers.value('mcp-session-id'), 'session-1');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      if (method == 'tools/list') {
        expect(request.headers.value('mcp-session-id'), 'session-2');
        await _sendJson(
          request,
          _response(body['id'], {
            'tools': [
              {'name': 'ok'},
            ],
          }),
        );
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    await expectLater(
      client.callTool('danger', {}),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          allOf(contains('未自动重试'), isNot(contains('Bearer'))),
        ),
      ),
    );
    // 404 之后不得重放工具调用，也不得先行初始化。
    expect(initializations, 1);
    expect(toolCalls, 1);
    expect(methods.where((method) => method == 'tools/call').length, 1);
    final tools = await client.listTools();
    expect(tools.single.name, 'ok');
    expect(initializations, 2);
  });

  test('初始化阶段取消后不会再发送 initialized 通知', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final initSeen = Completer<void>();
    final methods = <String>[];
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      methods.add(method);
      if (method == 'initialize') {
        if (!initSeen.isCompleted) initSeen.complete();
        // Hold the reply so the client can abort during the handshake.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        try {
          await _sendJson(
            request,
            _response(body['id'], _initResult()),
            headers: {'Mcp-Session-Id': _session},
          );
        } catch (_) {
          // The client already aborted the request.
        }
        return;
      }
      fail('取消后不应再发送 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    final pending = client.listTools();
    await initSeen.future;
    final expectation = expectLater(
      pending,
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('已取消'),
        ),
      ),
    );
    client.cancel();
    await expectation;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(methods, ['initialize']);
  });

  test('已初始化时在分发前取消，不会发送 tools/call', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    final toolCalls = Completer<void>();
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      methods.add(method);
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        await _sendJson(request, _response(body['id'], {'tools': []}));
        return;
      }
      if (method == 'tools/call') {
        if (!toolCalls.isCompleted) toolCalls.complete();
        await _sendJson(
          request,
          _response(body['id'], {'content': [], 'isError': false}),
        );
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    expect(await client.listTools(), isEmpty);

    // Session already initialized: cancellation lands in the gap between the
    // public call and dispatch, so tools/call must never reach the server.
    final pending = client.callTool('side_effect', {});
    final expectation = expectLater(
      pending,
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('已取消'),
        ),
      ),
    );
    client.cancel();
    await expectation;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(toolCalls.isCompleted, isFalse);
    expect(methods, [
      'initialize',
      'notifications/initialized',
      'tools/list',
    ]);
  });

  test('取消在途请求会立即失败并发送取消通知', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final toolRequest = Completer<int>();
    final cancellation = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'notifications/cancelled') {
        expect(request.headers.value('mcp-session-id'), _session);
        expect(request.headers.value('mcp-protocol-version'), '2025-06-18');
        if (!cancellation.isCompleted) {
          cancellation.complete(
            Map<String, dynamic>.from(body['params'] as Map),
          );
        }
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        if (!toolRequest.isCompleted) {
          toolRequest.complete(body['id'] as int);
        }
        // 保持连接直到客户端取消，模拟慢工具列表。
        try {
          await cancellation.future.timeout(const Duration(seconds: 5));
        } catch (_) {}
        try {
          await _sendJson(
            request,
            _response(body['id'], {
              'tools': [
                {'name': 'late'},
              ],
            }),
          );
        } catch (_) {}
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    final pending = client.listTools();
    final requestId = await toolRequest.future;
    final expectation = expectLater(
      pending,
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('已取消'),
        ),
      ),
    );
    client.cancel();
    await expectation;
    final params = await cancellation.future.timeout(
      const Duration(seconds: 5),
    );
    expect(params['requestId'], requestId);
    expect(params['reason'], isNotEmpty);
  });

  test('工具级错误作为结果返回，JSON-RPC 错误抛出 McpFailure', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/call') {
        final name = (body['params'] as Map)['name'];
        if (name == 'warning') {
          await _sendJson(
            request,
            _response(body['id'], {
              'content': [
                {'type': 'text', 'text': '权限不足'},
              ],
              'isError': true,
            }),
          );
          return;
        }
        expect(name, 'explode');
        await _sendJson(
          request,
          _error(
            body['id'],
            -32602,
            '参数无效 ${request.headers.value('authorization')}',
          ),
        );
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    final warning = await client.callTool('warning', {});
    expect(warning['isError'], isTrue);
    expect(warning['text'], '权限不足');

    await expectLater(
      client.callTool('explode', {}),
      throwsA(
        isA<McpFailure>()
            .having((failure) => failure.code, 'code', -32602)
            .having(
              (failure) => failure.message,
              'message',
              allOf(
                contains('参数无效'),
                isNot(contains(_secret)),
                isNot(contains('Bearer')),
              ),
            ),
      ),
    );
  });

  test('不支持的协议版本、无效响应和空工具名都会被拒绝', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      methods.add(method);
      final badVersion = request.uri.path == '/mcp';
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(
            body['id'],
            _initResult(version: badVersion ? '1999-01-01' : '2025-06-18'),
          ),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        expect(request.uri.path, '/invalid');
        request.response.headers.contentType = ContentType.json;
        request.response.write('not-json');
        await request.response.close();
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(_serverAt(server.port));
    addTearDown(client.close);
    await expectLater(
      client.listTools(),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('不受支持'),
        ),
      ),
    );
    expect(methods, ['initialize']);
    final invalid = McpClient(_serverAt(server.port, path: '/invalid'));
    addTearDown(invalid.close);
    await expectLater(
      invalid.listTools(),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('无效的数据'),
        ),
      ),
    );
    expect(methods, [
      'initialize',
      'initialize',
      'notifications/initialized',
      'tools/list',
    ]);
    await expectLater(
      client.callTool('  ', {}),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('工具名称'),
        ),
      ),
    );
  });

  test('超过 200 字符的请求头密钥在截断前被完整脱敏', () async {
    final secret = 'sk-${List.filled(240, 'A').join()}';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      if (request.uri.path == '/http-secret') {
        await _sendJson(
          request,
          _error(null, -32001, 'denied $secret'),
          status: HttpStatus.unauthorized,
        );
        return;
      }
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/call') {
        await _sendJson(
          request,
          _error(body['id'], -32000, 'bad key $secret'),
        );
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(
      _serverAt(server.port, headers: {'X-Api-Key': secret}),
    );
    addTearDown(client.close);
    await expectLater(
      client.callTool('leak', {}),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          _doesNotLeakSecret(secret),
        ),
      ),
    );

    final rejecting = McpClient(
      _serverAt(
        server.port,
        path: '/http-secret',
        headers: {'X-Api-Key': secret},
      ),
    );
    addTearDown(rejecting.close);
    await expectLater(
      rejecting.listTools(),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          _doesNotLeakSecret(secret),
        ),
      ),
    );
  });

  test('SSE 以 CR 结尾后普通文本分片，后续 LF 仍能分发结果', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        final socket = await request.response.detachSocket(
          writeHeaders: false,
        );
        try {
          socket.add(
            utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: text/event-stream; charset=utf-8\r\n'
              'Transfer-Encoding: chunked\r\n\r\n',
            ),
          );
          _writeHttpChunk(socket, ': keepalive\r');
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          _writeHttpChunk(
            socket,
            'data: ${jsonEncode(_response(body['id'], {
              'tools': [
                {'name': 'cr-fragment'},
              ],
            }))}',
          );
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          _writeHttpChunk(socket, '\n\n');
          await socket.flush();
          // Stay open past the client deadline: a parser that misses the
          // blank line must time out instead of being rescued by onDone.
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          socket.destroy();
        } catch (_) {
          // The client may close the stream as soon as it has the result.
        }
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(
      _serverAt(server.port),
      requestTimeout: const Duration(milliseconds: 700),
    );
    addTearDown(client.close);
    final tools = await client.listTools();
    expect(tools.single.name, 'cr-fragment');
  });

  test('无换行的超大 SSE 数据行在超过响应上限时失败', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final block = List.filled(64 * 1024, 'A').join();
    server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'tools/list') {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.bufferOutput = false;
        try {
          request.response.add(utf8.encode('data: '));
          for (var index = 0; index < 150; index++) {
            request.response.add(utf8.encode(block));
            await request.response.flush();
          }
        } catch (_) {
          // The client stops reading at the response budget.
        }
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(
      _serverAt(server.port),
      requestTimeout: const Duration(seconds: 15),
    );
    addTearDown(client.close);
    await expectLater(
      client.listTools(),
      throwsA(
        isA<McpFailure>().having(
          (failure) => failure.message,
          'message',
          contains('过大'),
        ),
      ),
    );
  });

  test('取消通知与 DELETE 无响应时，辅助连接按截止时间终止', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final toolsSeen = Completer<void>();
    final cancelSeen = Completer<void>();
    final deleteSeen = Completer<void>();
    server.listen((request) async {
      if (request.method == 'DELETE') {
        if (!deleteSeen.isCompleted) deleteSeen.complete();
        return;
      }
      final body = await _readBody(request);
      final method = body['method'] as String;
      if (method == 'initialize') {
        await _sendJson(
          request,
          _response(body['id'], _initResult()),
          headers: {'Mcp-Session-Id': _session},
        );
        return;
      }
      if (method == 'notifications/initialized') {
        await _sendAccepted(request);
        return;
      }
      if (method == 'notifications/cancelled') {
        if (!cancelSeen.isCompleted) cancelSeen.complete();
        // Deliberately never answer: the client must enforce its deadline.
        return;
      }
      if (method == 'tools/list') {
        if (!toolsSeen.isCompleted) toolsSeen.complete();
        return;
      }
      fail('未预期的 MCP 方法 $method');
    });

    final client = McpClient(
      _serverAt(server.port),
      auxiliaryTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(client.close);
    final pending = client.listTools();
    await toolsSeen.future;
    final expectation = expectLater(pending, throwsA(isA<McpFailure>()));
    client.cancel();
    await expectation;
    await cancelSeen.future;
    final watch = Stopwatch()..start();
    await client.close();
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    await deleteSeen.future.timeout(const Duration(seconds: 2));
    await expectLater(client.listTools(), throwsA(isA<McpFailure>()));
  });

  test('服务器配置校验、JSON 往返且诊断不包含请求头内容', () {
    const server = AiMcpServer(
      id: 'mcp-1',
      name: '远端 MCP',
      url: 'https://mcp.example.com/mcp',
      headers: {'Authorization': 'Bearer $_secret', 'X-Trace': 'on'},
    );
    server.validate();
    expect(server.toString(), isNot(contains(_secret)));
    expect(server.toString(), isNot(contains('Bearer')));
    final restored = AiMcpServer.fromJson(server.toJson());
    expect(restored, server);
    expect(restored.headers['Authorization'], 'Bearer $_secret');
    expect(restored.enabled, isTrue);

    expect(
      AiMcpServer.fromJson({
        'id': 'mcp-2',
        'name': '容错',
        'url': 'http://127.0.0.1:8080/mcp',
        'headers': {'X-Number': 3, 'X-Text': 'ok'},
      }).headers,
      {'X-Text': 'ok'},
    );
    expect(
      AiMcpServer.fromJson({'id': 'mcp-3'}).url,
      '',
    );

    const loopback = AiMcpServer(
      id: 'mcp-4',
      name: '本机',
      url: 'http://127.0.0.1:3000/mcp',
    );
    loopback.validate();

    for (final entry in {
      'ftp': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'ftp://example.com/mcp',
      ),
      'userinfo': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'https://user:pass@example.com/mcp',
      ),
      'fragment': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'https://example.com/mcp#fragment',
      ),
      'missingHost': const AiMcpServer(id: 'a', name: 'A', url: 'https://'),
    }.entries) {
      expect(
        () => entry.value.validate(),
        throwsA(isA<FormatException>()),
        reason: entry.key,
      );
    }

    for (final entry in {
      'spaceInName': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'https://example.com/mcp',
        headers: {'Bad Name': 'x'},
      ),
      'newline': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'https://example.com/mcp',
        headers: {'X-Test': 'value\r\nInjected: yes'},
      ),
      'reserved': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'https://example.com/mcp',
        headers: {'Content-Type': 'text/plain'},
      ),
      'duplicate': const AiMcpServer(
        id: 'a',
        name: 'A',
        url: 'https://example.com/mcp',
        headers: {'X-Test': '1', 'x-test': '2'},
      ),
      'emptyUrlHost': const AiMcpServer(id: 'a', name: 'A', url: ''),
    }.entries) {
      expect(
        () => entry.value.validate(),
        throwsA(isA<FormatException>()),
        reason: entry.key,
      );
    }
  });
}
