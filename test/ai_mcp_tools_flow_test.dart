import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/mcp_client.dart';
import 'package:harbor_ssh/domain/ai_mcp.dart';
import 'package:harbor_ssh/ui/ai_mcp_settings.dart';
import 'package:harbor_ssh/ui/theme.dart';

const _serverId = 'mcp-flow';
const _secret = 'secret-bearer-token';
const _session = 'session-flow';
const _path = '/mcp';

/// The stock widget-test binding answers every [HttpClient] request with a
/// synthetic 400. This file exists to drive a real loopback MCP server through
/// the settings UI, so the binding must leave [HttpClient] alone. It is
/// instantiated once at the top of [main], before `testWidgets` initializes the
/// binding, and never changes the suite-wide `HttpOverrides`.
class _RealIoTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _RealIoTestBinding();

  testWidgets('MCP 工具查看：真实会话、刷新、空态、401 恢复和关闭清理', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = (await tester.runAsync(_McpFixture.start))!;
    addTearDown(() {
      fixture.close().ignore();
    });
    fixture.tools = [_tool('alpha', description: '第一个工具'), _tool('beta')];

    var servers = <AiMcpServer>[_serverAt(fixture.port)];
    final changes = <List<AiMcpServer>>[];
    final clients = <_TrackingClient>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: StatefulBuilder(
              builder: (context, setState) => AiMcpSettingsEditor(
                servers: servers,
                onChanged: (next) {
                  changes.add(next);
                  setState(() => servers = next);
                },
                clientFactory: (server) {
                  final client = _TrackingClient(server);
                  clients.add(client);
                  return client;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final more = find.byKey(const ValueKey('ai-mcp-more-$_serverId'));
    final toolsItem = find.byKey(const ValueKey('ai-mcp-tools-$_serverId'));
    final dialog = find.byKey(const ValueKey('ai-mcp-tools-dialog'));
    final refresh = find.byKey(const ValueKey('ai-mcp-tools-refresh'));
    final close = find.byKey(const ValueKey('ai-mcp-tools-close'));

    Future<void> openTools() async {
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(toolsItem, findsOneWidget, reason: '更多菜单提供查看工具');
      await _tapInRealAsync(tester, toolsItem, frames: 3);
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> refreshTools() async {
      expect(refresh, findsOneWidget);
      expect(
        tester.widget<TextButton>(refresh).onPressed,
        isNotNull,
        reason: '空闲时刷新可点',
      );
      await _tapInRealAsync(tester, refresh);
    }

    await openTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tool-alpha')),
      reason: '真实 MCP 会话返回工具',
    );
    await _pumpUntilGone(
      tester,
      find.byKey(const ValueKey('ai-mcp-tools-loading')),
      reason: '读取结束后离开加载态',
    );
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('MCP 工具')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('本地 MCP')),
      findsOneWidget,
      reason: '弹窗展示当前服务名',
    );
    expect(
      find.descendant(of: dialog, matching: find.text('发现 2 个工具')),
      findsOneWidget,
      reason: '真实工具数量',
    );
    final alpha = find.byKey(const ValueKey('ai-mcp-tool-alpha'));
    final beta = find.byKey(const ValueKey('ai-mcp-tool-beta'));
    expect(
      find.descendant(of: alpha, matching: find.text('第一个工具')),
      findsOneWidget,
    );
    expect(beta, findsOneWidget);
    expect(
      find.descendant(of: beta, matching: find.textContaining('null')),
      findsNothing,
      reason: '无描述的工具不伪造说明',
    );
    expect(fixture.methods, [
      'initialize',
      'notifications/initialized',
      'tools/list',
    ]);
    expect(fixture.toolCalls, isEmpty, reason: '查看工具不是工具调用');
    expect(changes, isEmpty, reason: '查看工具不改服务配置');
    await _waitUntil(tester, () => clients.single.closeFinished);
    await _waitUntil(
      tester,
      () => fixture.deletedSessions.isNotEmpty,
      reason: '成功读取后关闭并清理 MCP 会话',
    );

    // 刷新返回完全不同的列表：旧工具不能残留，数量同步更新。
    fixture.tools = [_tool('gamma', description: '刷新后的工具')];
    await refreshTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tool-gamma')),
      reason: '刷新返回新工具',
    );
    await _pumpUntilGone(
      tester,
      find.byKey(const ValueKey('ai-mcp-tool-alpha')),
      reason: '旧工具不残留',
    );
    expect(beta, findsNothing);
    expect(
      find.descendant(of: dialog, matching: find.text('发现 1 个工具')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('刷新后的工具')),
      findsOneWidget,
    );
    await _waitUntil(tester, () => clients.last.closeFinished);
    expect(fixture.toolCalls, isEmpty);
    expect(changes, isEmpty);

    // 0 个工具时明确空态，而不是显示上一次的结果。
    fixture.tools = [];
    await refreshTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tools-empty')),
      reason: '空工具列表显示空态',
    );
    expect(
      find.descendant(of: dialog, matching: find.text('该服务没有提供任何工具。')),
      findsOneWidget,
    );
    expect(_toolEntries(), findsNothing);
    expect(
      find.descendant(of: dialog, matching: find.text('发现 0 个工具')),
      findsOneWidget,
    );

    // 401：失败可见，且错误里不出现配置的请求头值。
    fixture.mode = _FixtureMode.unauthorized;
    await refreshTools();
    final error = find.byKey(const ValueKey('ai-mcp-tools-error'));
    await _pumpUntil(tester, error, reason: '401 失败可见');
    expect(_toolEntries(), findsNothing, reason: '失败不冒充旧列表');
    final errorText = tester.widget<Text>(error).data ?? '';
    expect(errorText, contains('HTTP 401'));
    expect(errorText, isNot(contains(_secret)));
    expect(errorText, isNot(contains('Bearer')));
    expect(_visibleText(tester), isNot(contains(_secret)));
    expect(
      _visibleText(tester),
      isNot(contains(_secret.substring(_secret.length - 12))),
    );
    expect(fixture.toolCalls, isEmpty);
    await _waitUntil(tester, () => clients.last.closeFinished);

    // 恢复后刷新重新读取并展示工具，错误和空态都消失。
    fixture.mode = _FixtureMode.normal;
    fixture.tools = [_tool('delta', description: '恢复后的工具')];
    await refreshTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tool-delta')),
      reason: '失败后刷新可恢复',
    );
    await _pumpUntilGone(tester, error, reason: '恢复后错误消失');
    expect(find.byKey(const ValueKey('ai-mcp-tools-empty')), findsNothing);
    expect(
      find.descendant(of: dialog, matching: find.text('恢复后的工具')),
      findsOneWidget,
    );

    // 关闭按钮：中止在途读取、关闭客户端和会话，晚到响应不得触发已销毁
    // 弹窗的 setState。
    fixture.holdNextList();
    final heldBeforeClose = fixture.heldListCalls;
    await refreshTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tools-loading')),
      reason: '保持中的读取处于加载态',
    );
    await _waitUntil(
      tester,
      () => fixture.heldListCalls > heldBeforeClose,
      reason: '服务器已保持工具列表响应',
    );
    final closeActive = clients.last;
    expect(
      tester.widget<TextButton>(refresh).onPressed,
      isNull,
      reason: '读取期间刷新禁用',
    );
    await _tapInRealAsync(tester, close);
    await _pumpUntilGone(tester, dialog, reason: '关闭按钮关闭弹窗');
    await _waitUntil(
      tester,
      () => closeActive.cancelCalls > 0 && closeActive.closeFinished,
      reason: '关闭中止并释放在途客户端',
    );
    fixture.releaseHeldList();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Escape 走同一条清理路径。
    fixture.holdNextList();
    final beforeEscape = clients.length;
    final heldBeforeEscape = fixture.heldListCalls;
    await openTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tools-loading')),
      reason: 'Escape 前读取在途',
    );
    await _waitUntil(tester, () => clients.length > beforeEscape);
    await _waitUntil(
      tester,
      () => fixture.heldListCalls > heldBeforeEscape,
      reason: '服务器已保持 Escape 前的工具列表响应',
    );
    final escapeActive = clients.last;
    await _pressKeyInRealAsync(tester, LogicalKeyboardKey.escape);
    await _pumpUntilGone(tester, dialog, reason: 'Escape 关闭弹窗');
    await _waitUntil(
      tester,
      () => escapeActive.cancelCalls > 0 && escapeActive.closeFinished,
      reason: 'Escape 中止并释放在途客户端',
    );
    fixture.releaseHeldList();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 遮罩关闭同样中止在途请求。
    fixture.holdNextList();
    final beforeBarrier = clients.length;
    final heldBeforeBarrier = fixture.heldListCalls;
    await openTools();
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('ai-mcp-tools-loading')),
      reason: '点遮罩前读取在途',
    );
    await _waitUntil(tester, () => clients.length > beforeBarrier);
    await _waitUntil(
      tester,
      () => fixture.heldListCalls > heldBeforeBarrier,
      reason: '服务器已保持遮罩前的工具列表响应',
    );
    final barrierActive = clients.last;
    await _tapAtInRealAsync(tester, const Offset(8, 8));
    await _pumpUntilGone(tester, dialog, reason: '点遮罩关闭弹窗');
    await _waitUntil(
      tester,
      () => barrierActive.cancelCalls > 0 && barrierActive.closeFinished,
      reason: '遮罩中止并释放在途客户端',
    );
    fixture.releaseHeldList();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _waitUntil(
      tester,
      () => clients.every((client) => client.closeFinished),
      reason: '所有查看会话都已释放',
    );

    // 只读查看全程没有改动配置，也没有出现工具调用。
    expect(changes, isEmpty);
    expect(servers.single.enabled, isTrue);
    expect(
      servers.single.headers['Authorization'],
      'Bearer $_secret',
      reason: '请求头原样保留',
    );
    expect(
      fixture.authorizationHeaders,
      isNotEmpty,
      reason: '真实请求到达本地 MCP 服务器',
    );
    expect(
      fixture.authorizationHeaders.every((value) => value == 'Bearer $_secret'),
      isTrue,
      reason: '请求使用配置的鉴权头且未被查看流程改写',
    );
    expect(fixture.toolCalls, isEmpty);

    await tester.runAsync(fixture.close);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Finder _toolEntries() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('ai-mcp-tool-');
});

String _visibleText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    buffer.writeln(text.data ?? text.textSpan?.toPlainText() ?? '');
  }
  for (final text in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    buffer.writeln(text.data ?? text.textSpan?.toPlainText() ?? '');
  }
  return buffer.toString();
}

/// Starts a UI action inside [WidgetTester.runAsync] so any HTTP exchange it
/// triggers (dialog read, refresh, close) is created on the real event loop
/// rather than the widget-test fake clock. Requires an already-bound widget
/// tree; only the frames needed to hand off to the transport are pumped here.
Future<void> _tapInRealAsync(
  WidgetTester tester,
  Finder finder, {
  int frames = 1,
}) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < frames; i++) {
      await tester.pump();
    }
  });
}

Future<void> _pressKeyInRealAsync(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.runAsync(() async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  });
}

Future<void> _tapAtInRealAsync(WidgetTester tester, Offset offset) async {
  await tester.runAsync(() async {
    await tester.tapAt(offset);
    await tester.pump();
  });
}

/// Yields to the real event loop, then pumps a frame. Real socket callbacks
/// make progress only during [WidgetTester.runAsync]; the pump turns the
/// resulting setState into a rendered frame.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets, reason: reason);
}

Future<void> _pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  required String reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsNothing, reason: reason);
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = '等待状态',
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: reason);
}

AiMcpServer _serverAt(int port) => AiMcpServer(
  id: _serverId,
  name: '本地 MCP',
  url: 'http://127.0.0.1:$port$_path',
  headers: const {'Authorization': 'Bearer $_secret'},
);

Map<String, Object?> _tool(String name, {String? description}) => {
  'name': name,
  'description': ?description,
  'inputSchema': {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
  },
};

Map<String, Object?> _response(Object? id, Map<String, Object?> result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

Map<String, Object?> _initResult() => {
  'protocolVersion': mcpProtocolVersion,
  'capabilities': {'tools': <String, Object?>{}},
  'serverInfo': {'name': 'flow-fixture', 'version': '1.0'},
};

enum _FixtureMode { normal, unauthorized, holdList }

/// A loopback MCP server that speaks the real streamable-HTTP handshake.
///
/// It answers exactly the methods the settings UI is allowed to use, records
/// every method so a stray `tools/call` fails the flow, and can switch to a
/// 401 response or hold `tools/list` open until released. Held responses are
/// written after a client was cancelled on purpose: the late write must be
/// harmless, just like a slow real server.
class _McpFixture {
  _McpFixture._(this._http) {
    _http.listen(_handle);
  }

  static Future<_McpFixture> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _McpFixture._(http);
  }

  final HttpServer _http;
  final methods = <String>[];
  final toolCalls = <Map<String, dynamic>>[];
  final deletedSessions = <String?>[];
  final authorizationHeaders = <String?>[];

  List<Map<String, Object?>> tools = [];
  _FixtureMode mode = _FixtureMode.normal;
  int heldListCalls = 0;

  Completer<void> _held = Completer<void>();
  Future<void>? _closing;

  int get port => _http.port;

  Future<void> close() => _closing ??= _http.close(force: true).then((_) {});

  void holdNextList() {
    mode = _FixtureMode.holdList;
    _held = Completer<void>();
  }

  void releaseHeldList() {
    mode = _FixtureMode.normal;
    if (!_held.isCompleted) _held.complete();
  }

  Future<void> _handle(HttpRequest request) async {
    authorizationHeaders.add(request.headers.value('authorization'));
    if (request.uri.path != _path) {
      await _respond(request, HttpStatus.notFound);
      return;
    }
    if (request.method == 'DELETE') {
      deletedSessions.add(request.headers.value('mcp-session-id'));
      await _respond(request, HttpStatus.noContent);
      return;
    }
    if (request.method != 'POST') {
      await _respond(request, HttpStatus.methodNotAllowed);
      return;
    }

    Map<String, dynamic> body;
    try {
      body = await _readBody(request);
    } catch (_) {
      await _respond(request, HttpStatus.badRequest);
      return;
    }
    final method = body['method'] as String? ?? '';
    methods.add(method);

    if (mode == _FixtureMode.unauthorized) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.set(
        'www-authenticate',
        'Bearer realm="flow-fixture", error="invalid_token"',
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'unauthorized'}));
      await _closeResponse(request);
      return;
    }

    if (method == 'initialize') {
      await _sendJson(
        request,
        _response(body['id'], _initResult()),
        headers: {'Mcp-Session-Id': _session},
      );
      return;
    }
    if (method == 'notifications/initialized') {
      await _respond(request, HttpStatus.accepted);
      return;
    }
    if (method == 'tools/list') {
      final hold = mode == _FixtureMode.holdList;
      if (hold) {
        heldListCalls++;
        await _held.future;
      }
      await _sendJson(request, _response(body['id'], {'tools': tools}));
      return;
    }
    if (method == 'tools/call') {
      toolCalls.add(Map<String, dynamic>.from(body['params'] as Map));
      await _sendJson(
        request,
        _response(body['id'], {
          'content': [
            {'type': 'text', 'text': 'fixture'},
          ],
          'isError': false,
        }),
      );
      return;
    }
    await _sendJson(request, {
      'jsonrpc': '2.0',
      'id': body['id'],
      'error': {'code': -32601, 'message': 'method not found'},
    });
  }

  Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  Future<void> _respond(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await _closeResponse(request);
  }

  Future<void> _closeResponse(HttpRequest request) async {
    try {
      await request.response.close();
    } catch (_) {
      // 桌面端在客户端 cancel 后提前关闭连接；关闭失败只说明对端已经放弃。
    }
  }

  Future<void> _sendJson(
    HttpRequest request,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) async {
    try {
      request.response.statusCode = HttpStatus.ok;
      for (final entry in headers.entries) {
        request.response.headers.set(entry.key, entry.value);
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    } catch (_) {
      // 取消后的晚到响应写回已关闭的连接，属于预期路径。
    }
  }
}

/// Delegates every byte to the real [McpClient]; only observes the lifecycle
/// calls the dialog is required to make.
class _TrackingClient extends McpClient {
  _TrackingClient(super.server);

  int cancelCalls = 0;
  int closeCalls = 0;
  int _closesInFlight = 0;

  /// True once every [close] call (including the session DELETE) finished.
  bool get closeFinished => closeCalls > 0 && _closesInFlight == 0;

  @override
  void cancel() {
    cancelCalls++;
    super.cancel();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    _closesInFlight++;
    try {
      await super.close();
    } finally {
      _closesInFlight--;
    }
  }
}
