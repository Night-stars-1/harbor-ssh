import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../domain/host.dart';
import '../domain/command_history.dart';
import '../domain/path_completion.dart';
import '../domain/port_forward.dart';
import 'host_repository.dart';
import 'ssh_algorithms.dart';
import 'public_key_install.dart';
import 'terminal_ai.dart';
import 'ssh_ai_executor.dart';
import 'remote_commands.dart';
import 'remote_metrics.dart';
import 'sftp_files.dart';
import 'port_forward_manager.dart';
import 'ssh_port_forward.dart';
import '../domain/remote_file.dart';

enum ConnectionStatus { connecting, connected, closed, failed }

/// How a literal endpoint address may be reached from this device. Only used
/// to word model guidance; it is never treated as proof of availability.
enum _AiReachability { public, private, unknown }

class SshConnection extends ChangeNotifier {
  SshConnection({required this.id, required Host host}) {
    _host = host;
  }
  final String id;
  late final PortForwardManager portForwards = PortForwardManager((rule) {
    final client = _client;
    if (client == null || _closed || status != ConnectionStatus.connected) {
      throw StateError('SSH 会话已断开，请重新连接');
    }
    return startSshPortForward(
      client,
      rule,
      onConnectionError: (error) =>
          portForwards.reportConnectionError(rule.id, error),
    );
  });
  AiCommandExecutor createAiExecutor() => SshAiExecutor(
    (command) async {
      final client = _client;
      if (client == null || status != ConnectionStatus.connected || _closed) {
        throw const AiFailure('SSH 已断开，请重新连接');
      }
      return client.execute(command);
    },
    systemContext: _aiSystemContext(),
    startForward: _aiCreatePortForward,
    stopForward: (ruleId) => portForwards.stop(ruleId),
  );
  RemoteFileSystem get files => SftpFiles(_openSftp);
  late Host _host;
  Host get host => _host;
  final Terminal terminal = Terminal(maxLines: 10000);
  final inputGeneration = ValueNotifier<int>(0);
  ConnectionStatus status = ConnectionStatus.connecting;
  String? error;
  SSHClient? _client;
  final _routeClients = <SSHClient>[];
  SSHSocket? _pendingSocket;
  SSHSession? _shell;
  Future<SftpClient>? _sftp;
  String? _remoteHome;
  CommandHistory? _commandHistory;
  CommandHistory get commandHistory =>
      _commandHistory ??= CommandHistory(terminal);
  Future<void>? _historyLoad;
  Future<List<String>>? _availableCommands;
  DateTime? _commandsLoadedAt;
  HostRepository? _repository;
  String _endpointAddress = '';
  int? _endpointPort;
  String _networkLabel = '';
  int _savedPortForwardRevision = 0;
  static int _aiForwardSequence = 0;
  bool _closed = false;
  bool _disposed = false;
  int _generation = 0;
  int _openOutputStreams = 0;
  final List<StreamSubscription<String>> _subscriptions = [];

  /// Address and port actually dialled for [host], after the active network
  /// identity's overrides. Null before the target hop is resolved.
  (String, int)? get connectedEndpoint =>
      _endpointPort == null ? null : (_endpointAddress, _endpointPort!);

  /// Preferences-backed rule store for this host's current connection.
  PortForwardStore? get portForwardStore {
    final repository = _repository;
    return repository == null
        ? null
        : PortForwardStore(repository.preferences, host.id);
  }

  /// Incremented after a rule is durably saved, so workspaces can refresh.
  int get savedPortForwardRevision => _savedPortForwardRevision;
  String get statusLabel => switch (status) {
    ConnectionStatus.connecting => '正在连接',
    ConnectionStatus.connected => '已连接',
    ConnectionStatus.closed => '已断开',
    ConnectionStatus.failed => '连接失败',
  };

  bool _current(int generation) =>
      !_disposed && !_closed && generation == _generation;

  /// Keep the session identity, terminal buffer and pane while replacing only
  /// its closed transport. Old asynchronous callbacks cannot affect the retry.
  Future<void> reconnect(
    Credentials credentials,
    HostRepository repository,
    TrustHost prompt, {
    Host? host,
    ConfirmHostKeyChange? confirmKeyChange,
    TrustJumpHost? trustJumpHost,
    ConfirmJumpHostKeyChange? confirmJumpHostKeyChange,
  }) async {
    if (_disposed ||
        status == ConnectionStatus.connecting ||
        status == ConnectionStatus.connected) {
      return;
    }
    _release();
    final generation = _generation;
    _closed = false;
    _host = host ?? _host;
    _remoteHome = null;
    _historyLoad = null;
    _availableCommands = null;
    _commandsLoadedAt = null;
    _openOutputStreams = 0;
    error = null;
    status = ConnectionStatus.connecting;
    _notify();
    await portForwards.reopen();
    if (!_current(generation)) return;
    await connect(
      credentials,
      repository,
      prompt,
      confirmKeyChange: confirmKeyChange,
      trustJumpHost: trustJumpHost,
      confirmJumpHostKeyChange: confirmJumpHostKeyChange,
    );
  }

  Future<void> connect(
    Credentials credentials,
    HostRepository repository,
    TrustHost prompt, {
    bool openShell = true,
    ConfirmHostKeyChange? confirmKeyChange,
    TrustJumpHost? trustJumpHost,
    ConfirmJumpHostKeyChange? confirmJumpHostKeyChange,
  }) async {
    final generation = _generation;
    if (!_current(generation)) return;
    Object? verificationError;
    Host? connectingHost;
    try {
      final route = resolveSshRoute(
        host,
        host.jumpHostId.isEmpty ? const [] : await repository.loadHosts(),
      );
      if (!_current(generation)) return;
      // Read at dial time so switching identity applies to the next connect,
      // reconnects included, without touching sessions already open.
      final network = await repository.loadNetworkIdentities();
      if (!_current(generation)) return;
      _repository = repository;
      _networkLabel = network.active?.name ?? '';
      final credentialsByHost = <String, Credentials>{host.id: credentials};
      for (final hop in route.take(route.length - 1)) {
        final stored = await repository.loginCredentials(hop);
        if (!_current(generation)) return;
        if (stored == null) {
          throw StateError('中转主机「${hop.name}」缺少登录凭证，请先配置它的密码或私钥。');
        }
        credentialsByHost[hop.id] = stored;
      }
      SSHClient? previous;
      for (final hop in route) {
        connectingHost = hop;
        final hopCredentials = credentialsByHost[hop.id]!;
        final isTarget = hop.id == host.id;
        final identities = hop.authMethod == AuthMethod.privateKey
            ? SSHKeyPair.fromPem(
                hopCredentials.privateKey,
                hopCredentials.passphrase.isEmpty
                    ? null
                    : hopCredentials.passphrase,
              )
            : null;
        final (address, port) = network.endpointOf(hop);
        if (isTarget) {
          _endpointAddress = address;
          _endpointPort = port;
        }
        final socket = previous == null
            ? await SSHSocket.connect(
                address,
                port,
                timeout: const Duration(seconds: 15),
              )
            : await previous
                  .forwardLocal(address, port)
                  .timeout(const Duration(seconds: 15));
        if (!_current(generation)) {
          socket.destroy();
          return;
        }
        _pendingSocket = socket;
        final client = SSHClient(
          socket,
          username: hop.username,
          algorithms: harborSshAlgorithms,
          handshakeTimeout: const Duration(minutes: 5),
          authTimeout: const Duration(seconds: 30),
          identities: identities,
          onPasswordRequest: hop.authMethod == AuthMethod.password
              ? () => hopCredentials.password
              : null,
          keepAliveInterval: const Duration(seconds: 20),
          onVerifyHostKey: (type, bytes) async {
            if (!_current(generation)) return false;
            try {
              return await repository.verifyHost(
                hop,
                type,
                utf8.decode(bytes),
                (t, f) async {
                  if (!_current(generation)) return false;
                  final accepted = isTarget
                      ? await prompt(t, f)
                      : await (trustJumpHost?.call(hop, t, f) ??
                            Future.value(false));
                  return _current(generation) && accepted;
                },
                confirmKeyChange:
                    (isTarget
                        ? confirmKeyChange == null
                        : confirmJumpHostKeyChange == null)
                    ? null
                    : (t, f, previousKey) async {
                        if (!_current(generation)) return false;
                        final accepted = isTarget
                            ? await confirmKeyChange!(t, f, previousKey)
                            : await confirmJumpHostKeyChange!(
                                hop,
                                t,
                                f,
                                previousKey,
                              );
                        return _current(generation) && accepted;
                      },
              );
            } catch (e) {
              verificationError = e;
              return false;
            }
          },
        );
        _pendingSocket = null;
        _routeClients.add(client);
        if (isTarget) _client = client;
        unawaited(
          client.done.then(
            (_) {
              if (!_current(generation)) return;
              if (!isTarget) {
                if (status == ConnectionStatus.connected) {
                  _fail(StateError('中转主机「${hop.name}」已断开。'));
                }
                return;
              }
              unawaited(portForwards.close());
              if (_shell == null) _remoteClosed();
            },
            onError: (Object e) {
              if (_current(generation) &&
                  status == ConnectionStatus.connected) {
                _fail(isTarget ? e : StateError('中转主机「${hop.name}」已断开：$e'));
              }
            },
          ),
        );
        await client.authenticated;
        if (!_current(generation)) return;
        previous = client;
      }
      final client = _client!;
      if (!openShell) {
        status = ConnectionStatus.connected;
        _notify();
        return;
      }
      final shell = await client
          .shell(
            pty: SSHPtyConfig(
              width: terminal.viewWidth,
              height: terminal.viewHeight,
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (!_current(generation)) {
        shell.close();
        return;
      }
      _shell = shell;
      terminal.onOutput = (data) {
        if (_current(generation) && status == ConnectionStatus.connected) {
          commandHistory.observeInput(data);
          inputGeneration.value++;
          shell.write(Uint8List.fromList(utf8.encode(data)));
        }
      };
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        if (_current(generation) && status == ConnectionStatus.connected) {
          shell.resizeTerminal(width, height, pixelWidth, pixelHeight);
        }
      };
      _openOutputStreams = 2;
      for (final stream in [shell.stdout, shell.stderr]) {
        _subscriptions.add(
          stream
              .cast<List<int>>()
              .transform(const Utf8Decoder(allowMalformed: true))
              .listen(
                (data) {
                  if (_current(generation)) terminal.write(data);
                },
                onError: (Object e) {
                  if (_current(generation)) _fail(e);
                },
                onDone: () {
                  if (!_current(generation)) return;
                  _openOutputStreams--;
                  if (_openOutputStreams == 0) _remoteClosed();
                },
              ),
        );
      }
      status = ConnectionStatus.connected;
      _notify();
      unawaited(
        shell.done.then(
          (_) {}, // Output streams may still contain the final packet.
          onError: (Object e) {
            if (_current(generation)) _fail(e);
          },
        ),
      );
    } catch (e) {
      if (_current(generation)) {
        final failure = verificationError ?? e;
        final failedHost = connectingHost;
        _fail(
          failedHost != null && failedHost.id != host.id
              ? StateError('中转主机「${failedHost.name}」连接失败：$failure')
              : failure,
        );
      }
    }
  }

  void send(String data) => terminal.onOutput?.call(data);

  Future<SftpClient> _openSftp() async {
    final client = _client;
    if (client == null || _closed) throw StateError('SSH is disconnected');
    final sftp = await client.sftp();
    if (_closed || _client != client) {
      await sftp.close();
      throw StateError('SSH is disconnected');
    }
    return sftp;
  }

  Future<void> loadCommandHistory() {
    // Initialize the echo observer even if SFTP is unavailable.
    commandHistory;
    if (status != ConnectionStatus.connected) return Future.value();
    return _historyLoad ??= _readCommandHistory();
  }

  Future<List<String>> listAvailableCommands() {
    if (status != ConnectionStatus.connected || _closed) {
      return Future.value(const []);
    }
    if (_availableCommands == null ||
        _commandsLoadedAt == null ||
        DateTime.now().difference(_commandsLoadedAt!) >
            const Duration(minutes: 1)) {
      _commandsLoadedAt = DateTime.now();
      _availableCommands = _readAvailableCommands();
    }
    return _availableCommands!;
  }

  Future<List<String>> _readAvailableCommands() async {
    final generation = _generation;
    final client = _client;
    if (client == null) return const [];
    SSHSession? query;
    try {
      final opening = client.execute(remoteCommandCatalogQuery);
      try {
        query = await opening.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        unawaited(
          opening
              .then((lateSession) => lateSession.close())
              .catchError((Object _) {}),
        );
        rethrow;
      }
      if (!_current(generation)) return const [];
      final bytes = BytesBuilder(copy: false);
      await Future.wait<void>([
        query.stdout.forEach((chunk) {
          if (bytes.length + chunk.length > 524288) {
            throw StateError('Command catalog is too large');
          }
          bytes.add(chunk);
        }),
        query.stderr.drain<void>(),
        query.done.then((_) {}),
      ]).timeout(const Duration(seconds: 5));
      if (!_current(generation) || query.exitCode != 0) return const [];
      return parseRemoteCommands(
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
      );
    } catch (_) {
      // Restricted servers may reject exec requests. History stays available.
      return const [];
    } finally {
      query?.close();
    }
  }

  /// Read host load through a separate exec channel; never writes to the
  /// user's PTY and never interpolates user input.
  ///
  /// Returns null whenever the probe cannot be trusted: no live connection, a
  /// non-Linux host, a non-zero exit status, a timeout, or output that fails
  /// strict validation.
  Future<RemoteMetricsSample?> readRemoteMetrics() async {
    final generation = _generation;
    final client = _client;
    if (client == null || _closed || status != ConnectionStatus.connected) {
      return null;
    }
    SSHSession? query;
    try {
      final opening = client.execute(remoteMetricsQuery);
      try {
        query = await opening.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        unawaited(
          opening
              .then((lateSession) => lateSession.close())
              .catchError((Object _) {}),
        );
        rethrow;
      }
      if (!_current(generation)) return null;
      unawaited(query.stdin.close().catchError((Object _) {}));
      final bytes = BytesBuilder(copy: false);
      await Future.wait<void>([
        query.stdout.forEach((chunk) {
          // Per-core, per-process and per-mount rows are all legitimate, so the
          // cap only has to stop a runaway probe; the probe itself is bounded.
          if (bytes.length + chunk.length > 262144) {
            throw StateError('Remote metrics output is too large');
          }
          bytes.add(chunk);
        }),
        query.stderr.drain<void>(),
        query.done.then((_) {}),
      ]).timeout(const Duration(seconds: 5));
      if (!_current(generation) || query.exitCode != 0) return null;
      return parseRemoteMetrics(
        utf8.decode(bytes.takeBytes(), allowMalformed: true),
      );
    } catch (_) {
      // Restricted servers may reject exec requests; the status bar simply
      // reports that metrics are unavailable.
      return null;
    } finally {
      query?.close();
    }
  }

  Future<void> _readCommandHistory() async {
    final generation = _generation;
    try {
      final sftp = await (_sftp ??= _openSftp()).timeout(
        const Duration(seconds: 5),
      );
      final home =
          _remoteHome ??
          await sftp.absolute('.').timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      _remoteHome = home;
      final histories = <({int modified, List<String> commands})>[];
      for (final name in ['.bash_history', '.zsh_history']) {
        SftpFile? file;
        try {
          final path = '$home/$name';
          final attributes = await sftp
              .stat(path)
              .timeout(const Duration(seconds: 3));
          final size = attributes.size ?? 0;
          if (size == 0) continue;
          // Bound memory and network usage even for very large history files.
          final offset = size > 131072 ? size - 131072 : 0;
          final opening = sftp.open(path);
          try {
            file = await opening.timeout(const Duration(seconds: 3));
          } on TimeoutException {
            unawaited(
              opening
                  .then((lateFile) => lateFile.close())
                  .catchError((Object _) {}),
            );
            rethrow;
          }
          final bytes = await file
              .readBytes(offset: offset, length: size - offset)
              .timeout(const Duration(seconds: 3));
          var content = utf8.decode(bytes, allowMalformed: true);
          if (offset > 0) {
            final newline = content.indexOf('\n');
            content = newline < 0 ? '' : content.substring(newline + 1);
          }
          histories.add((
            modified: attributes.modifyTime ?? 0,
            commands: parseCommandHistory(content, zsh: name == '.zsh_history'),
          ));
        } catch (_) {
          // A missing/private history file must not affect terminal input.
        } finally {
          if (file != null) {
            try {
              await file.close().timeout(const Duration(seconds: 2));
            } catch (_) {}
          }
        }
      }
      histories.sort((a, b) => a.modified.compareTo(b.modified));
      if (_current(generation)) {
        commandHistory.mergeOlder(
          histories.expand((history) => history.commands),
        );
      }
    } catch (_) {
      // Keep current-session history when the server does not support SFTP.
    }
  }

  /// Read through a separate SFTP channel; never run commands in the user's PTY.
  Future<List<RemotePathEntry>> listDirectory(String path) async {
    final generation = _generation;
    if (status != ConnectionStatus.connected) return const [];
    try {
      final sftp = await (_sftp ??= _openSftp()).timeout(
        const Duration(seconds: 5),
      );
      if (path == '~' || path.startsWith('~/')) {
        final home =
            _remoteHome ??
            await sftp.absolute('.').timeout(const Duration(seconds: 5));
        if (!_current(generation)) return const [];
        _remoteHome = home;
        path = '$home${path.substring(1)}';
      }
      final entries = await sftp
          .listdir(path)
          .timeout(const Duration(seconds: 5));
      final result = <RemotePathEntry>[];
      for (final entry in entries) {
        final name = entry.filename;
        if (name == '.' ||
            name == '..' ||
            name.contains('/') ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
          continue;
        }
        var isDirectory = entry.attr.isDirectory;
        if (entry.attr.isSymbolicLink) {
          try {
            isDirectory =
                (await sftp
                        .stat('$path/$name')
                        .timeout(const Duration(seconds: 2)))
                    .isDirectory;
          } catch (_) {
            continue;
          }
        }
        result.add(RemotePathEntry(name, isDirectory: isDirectory));
      }
      return _current(generation) ? result : const [];
    } catch (_) {
      // Servers may disable SFTP. Completion must not interrupt terminal input.
      return const [];
    }
  }

  /// Installs [publicKey] into the login account's `~/.ssh/authorized_keys`
  /// through a separate SFTP channel.
  ///
  /// Returns true when the key was appended and false when the very same key
  /// was already present. Only that remote file is touched: the saved
  /// credentials, the host entry and the user's terminal stay untouched, and
  /// no shell or exec channel is opened.
  ///
  /// Throws a [FormatException] when [publicKey] is not one valid OpenSSH line
  /// (nothing is sent in that case) and a [PublicKeyInstallFailure] otherwise;
  /// its `unknown` flag tells the caller whether the remote file may have
  /// changed, which a timeout or a dropped channel cannot rule out.
  Future<bool> installPublicKey(String publicKey) async {
    // Validation comes first so a malformed key never reaches the network.
    final key = validatedOpenSshPublicKey(publicKey);
    if (status != ConnectionStatus.connected || _closed) {
      throw const PublicKeyInstallFailure('SSH 未连接，公钥未安装');
    }
    try {
      return await SftpFiles(_openSftp).installAuthorizedKey(key);
    } on StateError {
      // The SFTP channel could not be opened, so nothing was written.
      throw const PublicKeyInstallFailure('SSH 连接已断开，公钥未安装');
    }
  }

  /// Persists [rule] for this host and bumps [savedPortForwardRevision] only
  /// after the write succeeds. Throws with the real storage reason otherwise.
  Future<void> savePortForwardRule(PortForwardRule rule) async {
    final store = portForwardStore;
    if (store == null) {
      throw StateError('尚未读取主机配置，无法保存端口转发规则');
    }
    rule.validate();
    await store.upsert(rule);
    _savedPortForwardRevision++;
    _notify();
  }

  Future<AiForwardResult> _aiCreatePortForward(
    AiForwardRequest request, {
    required bool save,
  }) async {
    if (_client == null ||
        _closed ||
        status != ConnectionStatus.connected) {
      throw const AiFailure('SSH 已断开，请重新连接');
    }
    request.validate();
    final rule = PortForwardRule(
      id:
          'ai-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
          '${_aiForwardSequence++}',
      name: request.name.trim(),
      type: PortForwardType.local,
      bindHost: '127.0.0.1',
      bindPort: request.localPort,
      targetHost: request.targetHost.trim(),
      targetPort: request.targetPort,
    );
    await portForwards.start(rule);
    final state = portForwards.state(rule.id);
    final actualPort = state.port;
    if (state.status != PortForwardStatus.running ||
        actualPort == null ||
        actualPort < 1 ||
        actualPort > 65535) {
      await portForwards.stop(rule.id);
      throw AiFailure(
        state.error == null
            ? '端口转发启动失败'
            : '端口转发启动失败：${_forwardMessage(state.error!)}',
      );
    }
    final uri = rule.browserUri(actualPort: actualPort);
    if (uri == null) {
      await portForwards.stop(rule.id);
      throw const AiFailure('无法生成本机回环浏览器地址');
    }
    var saved = false;
    if (save) {
      try {
        await savePortForwardRule(rule);
        saved = true;
      } catch (error) {
        // The rule is not durable, so do not leave an untracked listener.
        await portForwards.stop(rule.id);
        final state = portForwards.state(rule.id);
        throw AiFailure(
          '转发已建立但保存规则失败：${_forwardMessage(error)}；'
          '${state.active ? '撤销转发失败：${_forwardMessage(state.error ?? '未知原因')}' : '转发已停止'}',
        );
      }
    }
    return AiForwardResult(
      ruleId: rule.id,
      name: rule.name,
      localPort: actualPort,
      targetHost: rule.targetHost,
      targetPort: rule.targetPort,
      url: uri.toString(),
      saved: saved,
    );
  }

  /// Host metadata for the model. Every host-provided value is JSON-quoted so
  /// a crafted hostname can never read as an instruction, and reachability is
  /// only ever described from the address literal, never asserted.
  String _aiSystemContext() {
    final endpoint = connectedEndpoint;
    final reachability = _addressReachability(endpoint?.$1);
    final buffer = StringBuffer()
      ..writeln('主机名称：${jsonEncode(host.name)}');
    if (endpoint == null) {
      buffer.writeln('实际 SSH 地址：未知（连接尚未完成）');
    } else {
      buffer
        ..writeln('实际 SSH 地址：${jsonEncode(endpoint.$1)}')
        ..writeln('实际 SSH 端口：${endpoint.$2}');
    }
    if (_networkLabel.isNotEmpty) {
      buffer.writeln('当前网络身份：${jsonEncode(_networkLabel)}');
    }
    final urlHost = _safeUrlHost(endpoint?.$1);
    buffer.writeln(
      '地址类型：${switch (reachability) {
        _AiReachability.public => '按字面属于公网地址',
        _AiReachability.private => '私有、回环、链路本地、CGNAT 地址或本地名称',
        _AiReachability.unknown => '无法从地址字面判断',
      }}。该判断不代表主机已开机、服务已监听或防火墙已放行。',
    );
    switch (reachability) {
      case _AiReachability.private:
        buffer.write(
          '浏览器通常无法直接打开该地址，不要声称 http://$urlHost:<服务端口> 可直接访问。'
          '需要访问服务器上的 HTTP 服务时，'
          '调用 $aiPortForwardToolName 把目标端口映射到本机 127.0.0.1，'
          '并只使用工具结果中实际分配的端口和 URL。',
        );
      case _AiReachability.public:
        buffer.write(
          '如需浏览器访问服务器上的服务，可按 http://$urlHost:<服务端口> 组织地址'
          '（例如服务监听 8080 时使用 http://$urlHost:8080，IPv6 地址已加方括号），'
          '但必须说明是否真正可达取决于监听和防火墙，未验证前不要断言可用。'
          '实际不可达时，经用户确认后可调用 $aiPortForwardToolName。',
        );
      case _AiReachability.unknown:
        buffer.write(
          '不要臆测该地址能否从本机直接访问，也不要断言 http://$urlHost:<服务端口> 可用。'
          '需要浏览器访问时先验证；无法直接访问时，经用户确认后调用 $aiPortForwardToolName，'
          '并使用工具结果中实际分配的端口和 URL。',
        );
    }
    buffer.write('\n每次 $aiPortForwardToolName 调用都必须等待用户确认；是否保存规则只由用户决定。');
    return buffer.toString();
  }

  static String _safeUrlHost(String? address) {
    final value = address?.trim() ?? '';
    // Only a conservative host literal is echoed into prose. Anything else is
    // replaced so host data can never read as an instruction or inject text.
    if (!RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) return '<该地址>';
    return value.contains(':') ? '[$value]' : value;
  }

  static String _forwardMessage(Object error) {
    final text = error is FormatException
        ? error.message
        : error.toString().replaceFirst(
            RegExp(r'^(Bad state: |Exception: |FormatException: )'),
            '',
          );
    return text.length <= 300 ? text : '${text.substring(0, 300)}…';
  }

  static _AiReachability _addressReachability(String? address) {
    final value = address?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return _AiReachability.unknown;
    final literal = value.startsWith('[') && value.endsWith(']')
        ? value.substring(1, value.length - 1)
        : value;
    final ip = InternetAddress.tryParse(literal);
    if (ip == null) {
      if (value == 'localhost' ||
          const ['.local', '.lan', '.internal', '.home', '.localhost'].any(
            (suffix) => value.endsWith(suffix),
          )) {
        return _AiReachability.private;
      }
      return _AiReachability.unknown;
    }
    if (ip.isLoopback || ip.isLinkLocal) return _AiReachability.private;
    if (ip.type == InternetAddressType.IPv6) {
      final bytes = ip.rawAddress;
      if (bytes.length == 16 &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff &&
          bytes.take(10).every((byte) => byte == 0)) {
        return _ipv4Reachability(bytes.sublist(12));
      }
      if (bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc) {
        return _AiReachability.private;
      }
      return ip.isMulticast || bytes.every((byte) => byte == 0)
          ? _AiReachability.unknown
          : _AiReachability.public;
    }
    final bytes = ip.rawAddress;
    return _ipv4Reachability(bytes);
  }

  static _AiReachability _ipv4Reachability(List<int> bytes) {
    if (bytes.length != 4) return _AiReachability.unknown;
    if (bytes[0] == 10 ||
        bytes[0] == 127 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
        (bytes[0] == 169 && bytes[1] == 254)) {
      return _AiReachability.private;
    }
    if (bytes[0] == 0 || bytes[0] >= 224) return _AiReachability.unknown;
    return _AiReachability.public;
  }

  void _remoteClosed() {
    if (_closed || status != ConnectionStatus.connected) return;
    close();
  }

  void _fail(Object exception) {
    if (_closed) return;
    error = exception.toString();
    status = ConnectionStatus.failed;
    _release();
    _notify();
  }

  void close() {
    if (_closed) return;
    status = ConnectionStatus.closed;
    _release();
    _notify();
  }

  void _release() {
    _generation++;
    _closed = true;
    _endpointAddress = '';
    _endpointPort = null;
    unawaited(portForwards.close());
    final sftp = _sftp;
    _sftp = null;
    if (sftp != null) {
      unawaited(
        sftp.then((client) => client.close()).catchError((Object _) {}),
      );
    }
    terminal.onOutput = null;
    terminal.onResize = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _shell?.close();
    _shell = null;
    _client = null;
    _pendingSocket?.destroy();
    _pendingSocket = null;
    for (final client in _routeClients.reversed) {
      // Peer disconnects can make flushing the final close packet fail.
      unawaited(client.close().catchError((Object _) {}));
    }
    _routeClients.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _commandHistory?.dispose();
    _release();
    inputGeneration.dispose();
    portForwards.dispose();
    super.dispose();
  }
}
