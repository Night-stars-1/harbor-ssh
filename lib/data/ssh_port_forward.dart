import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../domain/port_forward.dart';
import 'port_forward_manager.dart';

const _connectTimeout = Duration(seconds: 15);

/// All tunnels share the authenticated client; no credentials are read here.
Future<PortForwardHandle> startSshPortForward(
  SSHClient client,
  PortForwardRule rule, {
  void Function(Object error)? onConnectionError,
}) async {
  rule.validate();
  if (client.isClosed) throw StateError('SSH 会话已断开');
  if (rule.type == PortForwardType.dynamic) {
    return _DynamicHandle(
      await client.forwardDynamic(
        bindHost: rule.bindHost,
        bindPort: rule.bindPort,
      ),
    );
  }
  final handle = _TcpForward(client, rule, onConnectionError);
  await handle.open();
  return handle;
}

class _DynamicHandle implements PortForwardHandle {
  _DynamicHandle(this.forward);
  final SSHDynamicForward forward;
  @override
  int get port => forward.port;
  @override
  Future<void> close() => forward.close();
}

class _TcpForward implements PortForwardHandle {
  _TcpForward(this.client, this.rule, this.onConnectionError);
  final SSHClient client;
  final PortForwardRule rule;
  final void Function(Object)? onConnectionError;
  ServerSocket? _server;
  SSHRemoteForward? _remote;
  StreamSubscription<dynamic>? _listener;
  final _bridges = <_Bridge>{};
  bool _closed = false;
  bool _cancelled = false;
  Future<bool>? _cancelRequest;
  @override
  int get port => _server?.port ?? _remote!.port;

  Future<void> open() async {
    if (rule.type == PortForwardType.local) {
      _server = await ServerSocket.bind(rule.bindHost, rule.bindPort);
      _listener = _server!.listen(_acceptLocal, onError: _report);
    } else {
      _remote = await client
          .forwardRemote(host: rule.bindHost, port: rule.bindPort)
          .timeout(
            _connectTimeout,
            onTimeout: () {
              // Without a reply the allocated remote port is unknown. Closing the
              // transport is the only way to guarantee it cannot become orphaned.
              unawaited(client.close().catchError((Object _) {}));
              throw TimeoutException('服务器未响应转发请求，SSH 会话已断开');
            },
          );
      if (_remote == null) {
        throw StateError('服务器拒绝远程转发，请检查端口占用及 AllowTcpForwarding 设置');
      }
      _listener = _remote!.connections.listen(_acceptRemote, onError: _report);
    }
  }

  void _report(Object error) {
    if (!_closed && !client.isClosed) onConnectionError?.call(error);
  }

  _Bridge? _newBridge() {
    if (_closed || client.isClosed || _bridges.length >= 128) return null;
    final bridge = _Bridge();
    _bridges.add(bridge);
    return bridge;
  }

  Future<void> _acceptLocal(Socket socket) async {
    final bridge = _newBridge();
    if (bridge == null) {
      socket.destroy();
      return;
    }
    bridge.socket = socket;
    try {
      final opening = client.forwardLocal(
        rule.targetHost,
        rule.targetPort,
        localHost: socket.remoteAddress.address,
        localPort: socket.remotePort,
      );
      SSHForwardChannel channel;
      try {
        channel = await opening.timeout(_connectTimeout);
      } on TimeoutException {
        unawaited(
          opening.then((late) => late.destroy()).catchError((Object _) {}),
        );
        rethrow;
      }
      if (bridge.closed) {
        channel.destroy();
        return;
      }
      bridge.channel = channel;
      await bridge.pipe();
    } catch (error) {
      _report(error);
    } finally {
      bridge.destroy();
      _bridges.remove(bridge);
    }
  }

  Future<void> _acceptRemote(SSHForwardChannel channel) async {
    final bridge = _newBridge();
    if (bridge == null) {
      channel.destroy();
      return;
    }
    bridge.channel = channel;
    try {
      final socket = await Socket.connect(
        rule.targetHost,
        rule.targetPort,
        timeout: _connectTimeout,
      );
      if (bridge.closed) {
        socket.destroy();
        return;
      }
      bridge.socket = socket;
      await bridge.pipe();
    } catch (error) {
      _report(error);
    } finally {
      bridge.destroy();
      _bridges.remove(bridge);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_remote != null && !client.isClosed && !_cancelled) {
      final request = _cancelRequest ??= client
          .cancelForwardRemote(_remote!)
          .then((result) {
            _cancelled = result;
            return result;
          });
      try {
        _cancelled = await request.timeout(_connectTimeout);
      } catch (_) {
        if (!client.isClosed) rethrow;
      } finally {
        // Keep a pending timeout request to observe its eventual result on
        // retry, rather than sending two concurrent cancellation requests.
        unawaited(
          request.then(
            (_) {
              _cancelRequest = null;
            },
            onError: (Object _) {
              _cancelRequest = null;
            },
          ),
        );
      }
      if (!_cancelled && !client.isClosed) {
        throw StateError('服务器拒绝停止远程监听');
      }
    }
    _closed = true;
    for (final bridge in _bridges.toList()) {
      bridge.destroy();
    }
    _bridges.clear();
    await _server?.close();
    await _listener?.cancel();
  }
}

class _Bridge {
  Socket? socket;
  SSHForwardChannel? channel;
  bool closed = false;

  Future<void> pipe() async {
    final tcp = socket!;
    final ssh = channel!;
    tcp.setOption(SocketOption.tcpNoDelay, true);
    // addStream propagates backpressure. Each EOF only closes the opposite
    // write side, so request/response protocols can reply after a half-close.
    await Future.wait<void>([
      () async {
        await ssh.sink.addStream(tcp);
        await ssh.sink.close();
      }(),
      () async {
        await tcp.addStream(ssh.stream);
        await tcp.close();
      }(),
    ], eagerError: true);
  }

  void destroy() {
    if (closed) return;
    closed = true;
    socket?.destroy();
    channel?.destroy();
  }
}
