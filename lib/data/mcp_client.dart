import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/ai_mcp.dart';

/// Protocol revision implemented by [McpClient].
///
/// Streamable HTTP sessions (`Mcp-Session-Id`), the `MCP-Protocol-Version`
/// header, and the initialize/initialized handshake all exist in this
/// revision. Newer servers that negotiated a different supported revision keep
/// working because the negotiated value is echoed back.
const mcpProtocolVersion = '2025-06-18';

/// Revisions this client understands well enough to talk to.
const mcpSupportedProtocolVersions = {
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
  '2025-11-25',
  '2026-07-28',
};

/// A transport or protocol failure reported by [McpClient].
///
/// Messages never contain request header values, so they are safe to show in
/// UI or logs. [retryable] marks failures where repeating the call may work.
class McpFailure implements Exception {
  const McpFailure(this.message, {this.code, this.retryable = false});

  final String message;

  /// JSON-RPC error code when the server rejected the request.
  final int? code;
  final bool retryable;

  @override
  String toString() => message;
}

/// One tool advertised by an MCP server.
class McpTool {
  McpTool(this.name, this.description, Map<String, dynamic> inputSchema)
    : inputSchema = Map<String, dynamic>.unmodifiable(inputSchema);

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  @override
  String toString() => 'McpTool($name)';
}

/// JSON-RPC request id no longer belongs to a live server session. Internal:
/// callers see a retried request or an [McpFailure].
class _McpSessionExpired implements Exception {
  const _McpSessionExpired();
}

/// The in-flight call was cancelled through [McpClient.cancel] or close.
class _McpCancelled implements Exception {
  const _McpCancelled();
}

class _McpResult {
  const _McpResult(this.value);
  final Map<String, dynamic> value;
}

/// Streamable HTTP MCP client.
///
/// A client owns one logical session with one [AiMcpServer]. Requests are
/// issued lazily: the first [listTools] or [callTool] performs `initialize`,
/// posts `notifications/initialized`, and then the actual call. A server that
/// expires the session with HTTP 404 causes one transparent re-initialization
/// followed by a single retry for setup and read-only listings; a dispatched
/// [callTool] is never replayed (see its documentation).
///
/// Calls are meant to be issued one at a time per client. [cancel] aborts the
/// in-flight HTTP exchange and sends the MCP `notifications/cancelled`
/// notification best-effort.
class McpClient {
  McpClient(
    this.server, {
    this.requestTimeout = const Duration(seconds: 60),
    this.auxiliaryTimeout = const Duration(seconds: 5),
  });

  static const _maxRequestBytes = 8 * 1024 * 1024;
  static const _maxResponseBytes = 8 * 1024 * 1024;
  static const _maxToolPages = 50;
  static const _maxSseDataLines = 10000;
  static const _clientName = 'harbor-ssh';
  static const _clientVersion = '1.0';
  static const _sessionHeader = 'Mcp-Session-Id';
  static const _protocolHeader = 'MCP-Protocol-Version';

  final AiMcpServer server;
  final Duration requestTimeout;

  /// Hard deadline for advisory POSTs (cancellation, ping replies) and the
  /// session DELETE. Expiry aborts the private exchange and closes its client.
  final Duration auxiliaryTimeout;

  HttpClient? _http;
  String? _sessionId;
  String _protocolVersion = mcpProtocolVersion;
  bool _initialized = false;
  bool _closed = false;
  Future<void>? _initializing;
  int _lastId = 0;

  /// Incremented by [cancel] and [close]. A handshake that observes a newer
  /// value must not continue to `notifications/initialized`.
  int _cancelledAt = 0;

  /// Signal for the call currently owning the HTTP connection, if any.
  Completer<void>? _cancelSignal;
  int? _activeId;
  HttpClientRequest? _activeRequest;
  StreamSubscription<dynamic>? _activeSubscription;

  /// Private clients for auxiliary exchanges; [close] terminates survivors.
  final Set<HttpClient> _auxiliaryClients = {};

  Uri get _endpoint {
    try {
      server.validate();
    } on FormatException catch (error) {
      // The client exposes one error family to request callers; settings
      // editors still call validate() directly and get FormatException.
      throw McpFailure(error.message);
    }
    return Uri.parse(server.url.trim());
  }

  HttpClient get _httpClient {
    final existing = _http;
    if (existing != null) return existing;
    return _http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
  }

  /// Lists every tool the server advertises, following `nextCursor` pages.
  ///
  /// Duplicate names are collapsed, preserving first-seen order. This is also
  /// the connection test: it performs no tool call and has no side effects
  /// beyond starting the session.
  Future<List<McpTool>> listTools() async {
    _checkOpen();
    // One epoch spans initialization and every page, so cancellation cannot
    // silently resume the same logical listing on a later page.
    final epoch = _cancelledAt;
    final tools = <String, McpTool>{};
    final seenCursors = <String>{};
    String? cursor;
    for (var page = 0; page < _maxToolPages; page++) {
      _ensureStillWanted(epoch);
      final result = await _call(
        'tools/list',
        cursor == null ? null : {'cursor': cursor},
        cancellationEpoch: epoch,
      );
      _ensureStillWanted(epoch);
      final rawTools = result['tools'];
      if (rawTools is! List) {
        throw const McpFailure('MCP 服务器返回了无效的工具列表');
      }
      for (final rawTool in rawTools) {
        if (rawTool is! Map) {
          throw const McpFailure('MCP 服务器返回了无效的工具信息');
        }
        final name = rawTool['name'];
        if (name is! String || name.trim().isEmpty) {
          throw const McpFailure('MCP 服务器返回了无效的工具名称');
        }
        if (tools.containsKey(name)) continue;
        final description = rawTool['description'];
        final schema = rawTool['inputSchema'];
        if (schema != null && schema is! Map) {
          throw McpFailure('工具「$name」的输入参数定义无效');
        }
        tools[name] = McpTool(
          name,
          description is String ? description : '',
          schema is Map
              ? Map<String, dynamic>.from(schema)
              : const <String, dynamic>{},
        );
      }
      final next = result['nextCursor'];
      if (next is! String || next.trim().isEmpty) {
        cursor = null;
        break;
      }
      if (!seenCursors.add(next)) {
        throw const McpFailure('MCP 服务器返回了重复的分页游标');
      }
      cursor = next;
      if (page == _maxToolPages - 1) {
        throw const McpFailure('MCP 工具列表分页过多');
      }
    }
    _ensureStillWanted(epoch);
    return tools.values.toList(growable: false);
  }

  /// Calls one tool and returns a normalized result.
  ///
  /// The map always contains `content` (a list of content blocks), `text` (the
  /// text blocks joined by newlines), and `isError`. `structuredContent` is
  /// present only when the server returned it. A tool-level error is a normal
  /// result with `isError: true`; protocol and transport problems throw
  /// [McpFailure].
  ///
  /// If the server drops the session while the call is in flight (HTTP 404),
  /// the call is not replayed: it may already have executed. The failure says
  /// so, the stale session is discarded, and the next request performs a new
  /// handshake.
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    _checkOpen();
    final epoch = _cancelledAt;
    if (name.trim().isEmpty) {
      throw const McpFailure('工具名称不能为空');
    }
    final result = await _call(
      'tools/call',
      {'name': name, 'arguments': arguments},
      cancellationEpoch: epoch,
      // A dispatched tool call may already have run on the server; a 404 only
      // proves the session is gone, not that the call was skipped.
      replayAfterDispatch: false,
    );
    _ensureStillWanted(epoch);
    return _normalizeToolResult(result, name);
  }

  /// Aborts the in-flight request, if any, and reports cancellation to the
  /// server. Later calls start a fresh HTTP request on the same session.
  void cancel() {
    _cancelledAt++;
    final signal = _cancelSignal;
    _cancelSignal = null;
    final id = _activeId;
    _activeId = null;
    final wasInitialized = _initialized;
    final session = _sessionId;
    final request = _activeRequest;
    _activeRequest = null;
    final subscription = _activeSubscription;
    _activeSubscription = null;
    if (signal != null && !signal.isCompleted) signal.complete();
    try {
      request?.abort();
    } catch (_) {
      // The request may already be finished; cancellation is best-effort.
    }
    subscription?.cancel().ignore();
    if (id != null && wasInitialized) {
      unawaited(_notifyCancelled(id, session: session));
    }
  }

  /// Ends the session and releases the HTTP connections.
  ///
  /// Sends `DELETE` with the session id (servers may answer 405) and never
  /// throws because of a server-side failure. Calling it twice is harmless.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelledAt++;
    final signal = _cancelSignal;
    _cancelSignal = null;
    final id = _activeId;
    _activeId = null;
    final wasInitialized = _initialized;
    final session = _sessionId;
    _sessionId = null;
    _initialized = false;
    final request = _activeRequest;
    _activeRequest = null;
    final subscription = _activeSubscription;
    _activeSubscription = null;
    if (signal != null && !signal.isCompleted) signal.complete();
    try {
      request?.abort();
    } catch (_) {}
    subscription?.cancel().ignore();
    if (id != null && wasInitialized) {
      unawaited(_notifyCancelled(id, session: session));
    }
    if (session != null) {
      await _deleteSession(session);
    }
    // Advisory notifications may still be running; never leave their private
    // clients behind after close returns.
    for (final client in _auxiliaryClients.toList(growable: false)) {
      client.close(force: true);
    }
    _auxiliaryClients.clear();
    _http?.close(force: true);
    _http = null;
  }

  void _checkOpen() {
    if (_closed) throw const McpFailure('MCP 客户端已关闭');
  }

  Future<void> _ensureInitialized() async {
    _checkOpen();
    if (_initialized) return;
    final pending = _initializing;
    if (pending != null) return pending;
    final future = _initialize();
    _initializing = future;
    try {
      await future;
    } finally {
      if (identical(_initializing, future)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    _checkOpen();
    final epoch = _cancelledAt;
    // A fresh handshake must not carry a leftover session id; servers reject
    // initialize requests that arrive with someone else's session.
    _sessionId = null;
    _protocolVersion = mcpProtocolVersion;
    final id = ++_lastId;
    final result = await _post(
      {
        'jsonrpc': '2.0',
        'id': id,
        'method': 'initialize',
        'params': {
          'protocolVersion': mcpProtocolVersion,
          'capabilities': const <String, Object?>{},
          'clientInfo': const {
            'name': _clientName,
            'version': _clientVersion,
          },
        },
      },
      expectResult: true,
      expectedId: id,
      captureSession: true,
    );
    _ensureStillWanted(epoch);
    final version = result.value['protocolVersion'];
    if (version is! String || version.trim().isEmpty) {
      throw const McpFailure('MCP 服务器未返回协议版本');
    }
    final negotiated = version.trim();
    if (!mcpSupportedProtocolVersions.contains(negotiated)) {
      throw McpFailure('MCP 服务器协议版本 $negotiated 不受支持');
    }
    _protocolVersion = negotiated;
    _ensureStillWanted(epoch);
    await _notify('notifications/initialized');
    // Cancellation or close between the initialize reply and here must not
    // leave the session marked ready (or send initialized after abort).
    _ensureStillWanted(epoch);
    _initialized = true;
  }

  void _ensureStillWanted(int epoch) {
    if (_closed) throw const McpFailure('MCP 客户端已关闭');
    if (epoch != _cancelledAt) throw const McpFailure('MCP 请求已取消');
  }

  /// Forgets the current session so the next call performs a new handshake.
  void _restartSession() {
    _initialized = false;
    _sessionId = null;
    _protocolVersion = mcpProtocolVersion;
  }

  /// Performs one request after ensuring the session exists.
  ///
  /// A 404 while a session id is attached is the protocol's session-expired
  /// signal. Setup work and read-only listings may be repeated on a fresh
  /// session; a dispatched [callTool] is never replayed because the server may
  /// already have executed its side effects before answering 404.
  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic>? params, {
    required int cancellationEpoch,
    bool replayAfterDispatch = true,
  }) async {
    _checkOpen();
    _ensureStillWanted(cancellationEpoch);
    try {
      await _ensureInitialized();
    } on _McpSessionExpired {
      // The session expired during setup, before this request was sent.
      _restartSession();
      await _initializeOnce();
    }
    // Even a completed `_ensureInitialized` await yields to the event loop;
    // cancellation during that gap must stop the request before dispatch.
    _ensureStillWanted(cancellationEpoch);
    try {
      return await _request(method, params);
    } on _McpSessionExpired {
      _restartSession();
      if (!replayAfterDispatch) {
        throw const McpFailure(
          'MCP 会话已失效，本次工具调用未自动重试；请确认服务器状态后重新执行',
        );
      }
      await _initializeOnce();
      _ensureStillWanted(cancellationEpoch);
      try {
        return await _request(method, params);
      } on _McpSessionExpired {
        throw const McpFailure('MCP 会话已失效，请重新连接服务器');
      }
    }
  }

  /// Starts a brand new session after the server dropped the previous one.
  Future<void> _initializeOnce() async {
    try {
      await _ensureInitialized();
    } on _McpSessionExpired {
      throw const McpFailure('MCP 会话已失效，请重新连接服务器');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic>? params,
  ) async {
    _checkOpen();
    final id = ++_lastId;
    final result = await _post(
      {
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null && params.isNotEmpty) 'params': params,
      },
      expectResult: true,
      expectedId: id,
    );
    return result.value;
  }

  Future<void> _notify(String method, [Map<String, dynamic>? params]) async {
    await _post(
      {
        'jsonrpc': '2.0',
        'method': method,
        'params': ?params,
      },
      expectResult: false,
    );
  }

  /// Posts one JSON-RPC message and reads either a JSON or SSE response.
  Future<_McpResult> _post(
    Map<String, Object?> body, {
    required bool expectResult,
    int? expectedId,
    bool captureSession = false,
  }) async {
    _checkOpen();
    final endpoint = _endpoint;
    final http = _httpClient;
    final cancel = Completer<void>();
    _cancelSignal = cancel;
    final activeId = expectResult ? expectedId : null;
    if (activeId != null) _activeId = activeId;
    HttpClientRequest? localRequest;
    try {
      void stopIfCancelled({
        HttpClientRequest? request,
        HttpClientResponse? response,
      }) {
        if (!cancel.isCompleted) return;
        if (response != null) _closeResponse(response);
        if (request != null) {
          _abortRequest(request);
          if (identical(_activeRequest, request)) _activeRequest = null;
        }
        throw const _McpCancelled();
      }

      final work = () async {
        final request = await http.openUrl('POST', endpoint);
        localRequest = request;
        _activeRequest = request;
        stopIfCancelled(request: request);
        _applyHeaders(request, body);
        List<int> payload;
        try {
          payload = utf8.encode(jsonEncode(body));
        } catch (_) {
          throw const McpFailure('MCP 请求参数无法编码');
        }
        if (payload.length > _maxRequestBytes) {
          throw const McpFailure('MCP 请求内容过大');
        }
        request.contentLength = payload.length;
        request.add(payload);
        final response = await request.close();
        if (identical(_activeRequest, request)) _activeRequest = null;
        stopIfCancelled(response: response);
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          _discard(response);
          throw const McpFailure('MCP 服务器返回了重定向，已阻止请求头被转发');
        }
        if (status == HttpStatus.notFound && _sessionId != null) {
          _discard(response);
          throw const _McpSessionExpired();
        }
        if (status < 200 || status >= 300) {
          final detail = await _readErrorDetail(response);
          throw McpFailure(_httpError(status, detail), code: status);
        }
        if (captureSession) _captureSession(response);
        if (!expectResult) {
          _discard(response);
          return const _McpResult(<String, dynamic>{});
        }
        final expected = expectedId ?? (body['id'] as int);
        final mime = response.headers.contentType?.mimeType.toLowerCase();
        if (mime == 'text/event-stream') {
          return _readEventStream(response, expected);
        }
        return _readJson(response, expected);
      }();
      return await _raceWithCancel(work, cancel).timeout(requestTimeout);
    } on TimeoutException {
      // Mark the abandoned work cancelled before returning: a late openUrl
      // must not dispatch the request after the caller already saw a timeout.
      if (!cancel.isCompleted) cancel.complete();
      _abortRequest(localRequest);
      _abortSubscription();
      throw McpFailure(
        'MCP 请求超时（${requestTimeout.inSeconds} 秒），请检查服务器状态',
        retryable: true,
      );
    } on _McpCancelled {
      throw const McpFailure('MCP 请求已取消');
    } on _McpSessionExpired {
      rethrow;
    } on McpFailure {
      rethrow;
    } on HandshakeException {
      throw const McpFailure('无法验证 MCP 服务器证书');
    } on SocketException {
      throw const McpFailure('无法连接 MCP 服务器，请检查地址和网络');
    } on HttpException {
      if (_closed || cancel.isCompleted) {
        throw const McpFailure('MCP 请求已取消');
      }
      throw const McpFailure('MCP 服务器连接中断', retryable: true);
    } on FormatException {
      if (_closed || cancel.isCompleted) {
        throw const McpFailure('MCP 请求已取消');
      }
      throw const McpFailure('MCP 服务器返回了无效的数据');
    } finally {
      if (identical(_cancelSignal, cancel)) _cancelSignal = null;
      if (activeId != null && _activeId == activeId) _activeId = null;
      if (localRequest != null && identical(_activeRequest, localRequest)) {
        _activeRequest = null;
      }
    }
  }

  Future<T> _raceWithCancel<T>(Future<T> work, Completer<void> cancel) {
    if (cancel.isCompleted) {
      return Future<T>.error(const _McpCancelled());
    }
    final cancelled = cancel.future.then<T>((_) => throw const _McpCancelled());
    return Future.any<T>([work, cancelled]);
  }

  void _applyHeaders(
    HttpClientRequest request,
    Map<String, Object?> body, {
    String? sessionOverride,
  }) {
    for (final entry in server.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    // Transport-owned headers are applied last; validate() already rejects
    // user headers that try to replace them.
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/event-stream',
    );
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'Harbor-SSH');
    request.headers.set(_protocolHeader, _protocolVersion);
    request.followRedirects = false;
    final session = sessionOverride ?? _sessionId;
    if (session != null) request.headers.set(_sessionHeader, session);
    final method = body['method'];
    if (method is String && method.isNotEmpty) {
      request.headers.set('Mcp-Method', method);
      final name = _requestName(body);
      if (name != null) request.headers.set('Mcp-Name', name);
    }
  }

  /// Mirrors `params.name`/`params.uri` for routing-aware proxies, but only
  /// when the value is plain printable ASCII as the metadata headers require.
  String? _requestName(Map<String, Object?> body) {
    final params = body['params'];
    if (params is! Map) return null;
    final name = params['name'] ?? params['uri'];
    if (name is! String || name.isEmpty) return null;
    for (final unit in name.codeUnits) {
      if (unit < 0x20 || unit > 0x7e) return null;
    }
    return name;
  }

  void _captureSession(HttpClientResponse response) {
    final raw = response.headers.value(_sessionHeader);
    if (raw == null) return;
    final session = raw.trim();
    final valid =
        session.isNotEmpty &&
        session.length <= 1024 &&
        session.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);
    if (!valid) {
      throw const McpFailure('MCP 服务器返回了无效的会话标识');
    }
    _sessionId = session;
  }

  Future<_McpResult> _readJson(
    HttpClientResponse response,
    int expectedId,
  ) {
    final bytes = <int>[];
    final completer = Completer<_McpResult>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (bytes.length + chunk.length > _maxResponseBytes) {
          completer.completeError(const McpFailure('MCP 服务器响应过大'));
          subscription.cancel().ignore();
          return;
        }
        bytes.addAll(chunk);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
      onDone: () {
        if (completer.isCompleted) return;
        try {
          completer.complete(_parseJsonBody(bytes, expectedId));
        } catch (error, stack) {
          completer.completeError(error, stack);
        }
      },
      cancelOnError: true,
    );
    _activeSubscription = subscription;
    return completer.future.whenComplete(() {
      if (identical(_activeSubscription, subscription)) {
        _activeSubscription = null;
      }
    });
  }

  _McpResult _parseJsonBody(List<int> bytes, int expectedId) {
    if (bytes.isEmpty) {
      throw const McpFailure('MCP 服务器未返回响应');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on FormatException {
      throw const McpFailure('MCP 服务器返回了无效的数据');
    }
    return _selectResponse(decoded, expectedId);
  }

  _McpResult _selectResponse(Object? decoded, int expectedId) {
    if (decoded is Map) {
      return _responseFromMessage(
        Map<String, dynamic>.from(decoded),
        expectedId,
      );
    }
    if (decoded is List) {
      for (final item in decoded) {
        if (item is! Map) continue;
        final message = Map<String, dynamic>.from(item);
        final id = message['id'];
        if (_sameId(id, expectedId)) {
          return _responseFromMessage(message, expectedId);
        }
      }
      for (final item in decoded) {
        if (item is! Map) continue;
        final message = Map<String, dynamic>.from(item);
        if (message['method'] == null && message['id'] == null) {
          throw _rpcFailure(message['error']);
        }
      }
      throw const McpFailure('MCP 服务器未返回匹配的响应');
    }
    throw const McpFailure('MCP 服务器返回了无效的数据');
  }

  _McpResult _responseFromMessage(
    Map<String, dynamic> message,
    int expectedId,
  ) {
    if (message['method'] is String) {
      // A server request cannot appear as the reply to our request; ignore
      // notifications and answer protocol pings elsewhere.
      if (message['id'] != null) {
        unawaited(_answerServerRequest(message));
      }
      throw const McpFailure('MCP 服务器返回了意外消息');
    }
    if (!_sameId(message['id'], expectedId)) {
      throw const McpFailure('MCP 服务器未返回匹配的响应');
    }
    final error = message['error'];
    if (error != null) throw _rpcFailure(error);
    final result = message['result'];
    if (result is Map) {
      return _McpResult(Map<String, dynamic>.from(result));
    }
    if (result == null) return const _McpResult(<String, dynamic>{});
    throw const McpFailure('MCP 服务器返回了无效的结果');
  }

  Future<_McpResult> _readEventStream(
    HttpClientResponse response,
    int expectedId,
  ) async {
    final completer = Completer<_McpResult>();
    // A StringBuffer keeps appends amortized; never rebuild an unbounded
    // partial line with string concatenation.
    final pending = StringBuffer();
    var pendingCr = false;
    var data = <String>[];
    var dataChars = 0;
    var receivedBytes = 0;
    var stopped = false;
    StreamSubscription<String>? subscription;

    void stop() {
      if (stopped) return;
      stopped = true;
      subscription?.cancel().ignore();
    }

    void fail(Object error, [StackTrace? stack]) {
      if (completer.isCompleted) return;
      completer.completeError(error, stack);
      stop();
    }

    void dispatch() {
      if (data.isEmpty || completer.isCompleted || stopped) return;
      final payload = data.join('\n');
      data = <String>[];
      dataChars = 0;
      try {
        for (final message in _decodeSseMessages(payload)) {
          _handleServerMessage(message, expectedId, completer);
          if (completer.isCompleted) break;
        }
      } catch (error, stack) {
        fail(error, stack);
        return;
      }
      if (completer.isCompleted) stop();
    }

    void handleLine(String line) {
      if (line.isEmpty) {
        dispatch();
        return;
      }
      if (line.startsWith(':')) return;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field != 'data') {
        // `event`, `id` and `retry` carry no MCP payload of their own.
        return;
      }
      if (data.length >= _maxSseDataLines ||
          dataChars + value.length > _maxResponseBytes) {
        fail(const McpFailure('MCP 服务器响应过大'));
        return;
      }
      data.add(value);
      dataChars += value.length;
    }

    void feed(String chunk) {
      if (stopped || completer.isCompleted) return;
      if (chunk.isEmpty) return;
      try {
        var index = 0;
        var start = 0;
        if (pendingCr) {
          // The flag belongs to the immediately following chunk only; a CR
          // followed by ordinary text must not swallow a later LF.
          pendingCr = false;
          if (chunk.startsWith('\n')) {
            index = 1;
            start = 1;
          }
        }
        while (index < chunk.length) {
          final unit = chunk.codeUnitAt(index);
          if (unit == 0x0a || unit == 0x0d) {
            pending.write(chunk.substring(start, index));
            if (pending.length > _maxResponseBytes) {
              fail(const McpFailure('MCP 服务器响应过大'));
              return;
            }
            final line = pending.toString();
            pending.clear();
            handleLine(line);
            if (stopped || completer.isCompleted) return;
            if (unit == 0x0d) {
              if (index + 1 < chunk.length) {
                if (chunk.codeUnitAt(index + 1) == 0x0a) index++;
              } else {
                pendingCr = true;
              }
            }
            start = index + 1;
          }
          index++;
        }
        final tail = chunk.substring(start);
        if (pending.length + tail.length > _maxResponseBytes) {
          fail(const McpFailure('MCP 服务器响应过大'));
          return;
        }
        pending.write(tail);
      } catch (error, stack) {
        fail(error, stack);
      }
    }

    // Count raw bytes before decoding so a server cannot exceed the response
    // budget through multi-byte characters.
    final bounded = response.map((chunk) {
      receivedBytes += chunk.length;
      if (receivedBytes > _maxResponseBytes) {
        throw const McpFailure('MCP 服务器响应过大');
      }
      return chunk;
    });
    subscription = bounded.transform(utf8.decoder).listen(
      feed,
      onError: (Object error, StackTrace stack) {
        fail(error, stack);
      },
      onDone: () {
        if (stopped || completer.isCompleted) return;
        if (pending.isNotEmpty) {
          final line = pending.toString();
          pending.clear();
          handleLine(line);
        }
        pendingCr = false;
        if (stopped || completer.isCompleted) return;
        dispatch();
        if (!completer.isCompleted) {
          fail(const McpFailure('MCP 服务器未返回结果'));
        }
      },
      cancelOnError: true,
    );
    _activeSubscription = subscription;
    try {
      return await completer.future;
    } finally {
      if (identical(_activeSubscription, subscription)) {
        _activeSubscription = null;
      }
      subscription.cancel().ignore();
    }
  }

  Iterable<Object?> _decodeSseMessages(String payload) sync* {
    final text = payload.trim();
    if (text.isEmpty) return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        yield* decoded;
      } else {
        yield decoded;
      }
      return;
    } on FormatException {
      // Some servers put several JSON-RPC messages on separate lines inside a
      // single event, which is also what older SSE implementations emit.
    }
    for (final line in payload.split('\n')) {
      final candidate = line.trim();
      if (candidate.isEmpty) continue;
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is List) {
          yield* decoded;
        } else {
          yield decoded;
        }
      } on FormatException {
        throw const McpFailure('MCP 服务器返回了无效的事件数据');
      }
    }
  }

  void _handleServerMessage(
    Object? message,
    int expectedId,
    Completer<_McpResult> completer,
  ) {
    if (message is! Map) return;
    final method = message['method'];
    if (method is String) {
      if (message['id'] != null) {
        unawaited(_answerServerRequest(Map<String, dynamic>.from(message)));
      }
      return;
    }
    if (!_sameId(message['id'], expectedId) || completer.isCompleted) return;
    final error = message['error'];
    if (error != null) {
      completer.completeError(_rpcFailure(error));
      return;
    }
    final result = message['result'];
    if (result is Map) {
      completer.complete(_McpResult(Map<String, dynamic>.from(result)));
    } else if (result == null) {
      completer.complete(const _McpResult(<String, dynamic>{}));
    } else {
      completer.completeError(const McpFailure('MCP 服务器返回了无效的结果'));
    }
  }

  /// Answers the only request a server may reasonably send an undeclared
  /// client: `ping`. Everything else is ignored because no client capability
  /// (sampling, roots, elicitation) was advertised.
  Future<void> _answerServerRequest(Map<String, dynamic> message) async {
    if (message['method'] != 'ping' || message['id'] == null) return;
    await _fireAndForget({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': const <String, dynamic>{},
    });
  }

  Future<void> _notifyCancelled(int requestId, {String? session}) async {
    await _fireAndForget({
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
      'params': {'requestId': requestId, 'reason': '用户已取消'},
    }, session: session);
  }

  /// Best-effort POST whose failures never reach the user.
  Future<void> _fireAndForget(
    Map<String, Object?> body, {
    String? session,
  }) => _auxiliaryExchange('POST', body: body, session: session);

  Future<void> _deleteSession(String session) =>
      _auxiliaryExchange('DELETE', session: session);

  /// Runs one advisory or cleanup exchange on a private client with a hard
  /// deadline. On expiry the request is aborted and the client closed instead
  /// of merely abandoning the future.
  Future<void> _auxiliaryExchange(
    String method, {
    Map<String, Object?>? body,
    String? session,
  }) async {
    final timeout = auxiliaryTimeout;
    final http = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    _auxiliaryClients.add(http);
    HttpClientRequest? request;
    var finished = false;
    try {
      final exchange = () async {
        final pending = await http.openUrl(method, _endpoint);
        request = pending;
        pending.followRedirects = false;
        _applyHeaders(
          pending,
          body ?? const <String, Object?>{},
          sessionOverride: session,
        );
        if (body != null) {
          final payload = utf8.encode(jsonEncode(body));
          if (payload.length > _maxRequestBytes) {
            throw const McpFailure('MCP 请求内容过大');
          }
          pending.contentLength = payload.length;
          pending.add(payload);
        }
        final response = await pending.close();
        await response.drain<void>();
      }();
      await exchange.timeout(timeout, onTimeout: () {});
      finished = true;
    } catch (_) {
      // Notifications/deletion are best-effort; failures must not surface.
    } finally {
      if (!finished) {
        try {
          request?.abort();
        } catch (_) {}
      }
      _auxiliaryClients.remove(http);
      http.close(force: true);
    }
  }

  Map<String, dynamic> _normalizeToolResult(
    Map<String, dynamic> result,
    String toolName,
  ) {
    final rawContent = result['content'];
    final content = <Map<String, dynamic>>[];
    if (rawContent != null) {
      if (rawContent is! List) {
        throw McpFailure('工具「$toolName」返回了无效的内容');
      }
      for (final block in rawContent) {
        if (block is! Map) {
          throw McpFailure('工具「$toolName」返回了无效的内容');
        }
        content.add(Map<String, dynamic>.from(block));
      }
    }
    final structured = result['structuredContent'];
    if (structured != null && structured is! Map) {
      throw McpFailure('工具「$toolName」返回了无效的结构化内容');
    }
    final rawError = result['isError'];
    final text = content
        .where((block) => block['type'] == 'text' && block['text'] is String)
        .map((block) => block['text'] as String)
        .join('\n');
    return {
      'content': content,
      'text': text,
      'isError': rawError is bool ? rawError : false,
      if (structured is Map)
        'structuredContent': Map<String, dynamic>.from(structured),
    };
  }

  Future<String?> _readErrorDetail(HttpClientResponse response) async {
    try {
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 64 * 1024) break;
      }
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isEmpty) return null;
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        // Proxy HTML and plain text bodies can echo anything; drop them.
        return null;
      }
      if (decoded is! Map) return null;
      final error = decoded['error'];
      if (error is Map) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) {
          return _truncate(_redactSecrets(message.trim()));
        }
      }
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) {
        return _truncate(_redactSecrets(message.trim()));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _httpError(int status, String? detail) {
    final base = switch (status) {
      400 => 'MCP 服务器拒绝了请求（HTTP 400）',
      401 || 403 => 'MCP 服务器拒绝了认证（HTTP $status），请检查请求头',
      404 => 'MCP 服务器地址不存在（HTTP 404）',
      405 => 'MCP 服务器不支持流式 HTTP 请求（HTTP 405）',
      429 => 'MCP 服务器请求过于频繁（HTTP 429）',
      >= 500 => 'MCP 服务器内部错误（HTTP $status）',
      _ => 'MCP 请求失败（HTTP $status）',
    };
    return detail == null ? base : '$base：$detail';
  }

  McpFailure _rpcFailure(Object? error) {
    if (error is Map) {
      final code = error['code'];
      final message = error['message'];
      final text = message is String && message.trim().isNotEmpty
          ? _truncate(_redactSecrets(message.trim()))
          : '请求被服务器拒绝';
      return McpFailure(
        'MCP 服务器错误：$text',
        code: code is int ? code : null,
      );
    }
    return const McpFailure('MCP 服务器错误：请求被服务器拒绝');
  }

  /// Removes configured header values (and long token parts) from text that a
  /// server controls, so a diagnostic cannot echo the credentials it received.
  String _redactSecrets(String text) {
    var result = text;
    for (final value in server.headers.values) {
      if (value.isEmpty) continue;
      if (value.length >= 4) {
        result = result.replaceAll(value, '***');
      }
      for (final part in value.split(RegExp(r'\s+'))) {
        if (part.length >= 8) result = result.replaceAll(part, '***');
      }
    }
    return result;
  }

  static String _truncate(String value) =>
      value.length <= 200 ? value : '${value.substring(0, 200)}…';

  static bool _sameId(Object? value, int expected) =>
      value is int ? value == expected : value is String && value == '$expected';

  static void _discard(HttpClientResponse response) {
    response.drain<void>().ignore();
  }

  /// Stops reading an abandoned response and drops its connection.
  static void _closeResponse(HttpClientResponse response) {
    response
        .listen(
          (_) {},
          onError: (Object _) {},
          cancelOnError: true,
        )
        .cancel()
        .ignore();
  }

  void _abortRequest(HttpClientRequest? request) {
    if (request == null) return;
    try {
      request.abort();
    } catch (_) {}
  }

  void _abortSubscription() {
    final subscription = _activeSubscription;
    _activeSubscription = null;
    subscription?.cancel().ignore();
  }
}
