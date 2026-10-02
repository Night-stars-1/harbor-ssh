import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../domain/host.dart';
import '../domain/command_history.dart';
import '../domain/path_completion.dart';
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
  AiCommandExecutor createAiExecutor() => SshAiExecutor((command) async {
    final client = _client;
    if (client == null || status != ConnectionStatus.connected || _closed) {
      throw const AiFailure('SSH 已断开，请重新连接');
    }
    return client.execute(command);
  });
  RemoteFileSystem get files => SftpFiles(_openSftp);
  late Host _host;
  Host get host => _host;
  final Terminal terminal = Terminal(maxLines: 10000);
  final inputGeneration = ValueNotifier<int>(0);
  ConnectionStatus status = ConnectionStatus.connecting;
  String? error;
  SSHClient? _client;
  SSHSession? _shell;
  Future<SftpClient>? _sftp;
  String? _remoteHome;
  CommandHistory? _commandHistory;
  CommandHistory get commandHistory =>
      _commandHistory ??= CommandHistory(terminal);
  Future<void>? _historyLoad;
  Future<List<String>>? _availableCommands;
  DateTime? _commandsLoadedAt;
  bool _closed = false;
  bool _disposed = false;
  int _generation = 0;
  int _openOutputStreams = 0;
  final List<StreamSubscription<String>> _subscriptions = [];
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
    );
  }

  Future<void> connect(
    Credentials credentials,
    HostRepository repository,
    TrustHost prompt, {
    bool openShell = true,
    ConfirmHostKeyChange? confirmKeyChange,
  }) async {
    final generation = _generation;
    if (!_current(generation)) return;
    Object? verificationError;
    try {
      final identities = host.authMethod == AuthMethod.privateKey
          ? SSHKeyPair.fromPem(
              credentials.privateKey,
              credentials.passphrase.isEmpty ? null : credentials.passphrase,
            )
          : null;
      final socket = await SSHSocket.connect(
        host.address,
        host.port,
        timeout: const Duration(seconds: 15),
      );
      if (!_current(generation)) {
        socket.destroy();
        return;
      }
      final client = SSHClient(
        socket,
        username: host.username,
        algorithms: harborSshAlgorithms,
        handshakeTimeout: const Duration(minutes: 5),
        authTimeout: const Duration(seconds: 30),
        identities: identities,
        onPasswordRequest: host.authMethod == AuthMethod.password
            ? () => credentials.password
            : null,
        keepAliveInterval: const Duration(seconds: 20),
        onVerifyHostKey: (type, bytes) async {
          if (!_current(generation)) return false;
          try {
            return await repository.verifyHost(
              host,
              type,
              utf8.decode(bytes),
              (t, f) async {
                if (!_current(generation)) return false;
                final accepted = await prompt(t, f);
                return _current(generation) && accepted;
              },
              confirmKeyChange: confirmKeyChange == null
                  ? null
                  : (t, f, previousKey) async {
                      if (!_current(generation)) return false;
                      final accepted = await confirmKeyChange(
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
      _client = client;
      unawaited(
        client.done.then(
          (_) {
            if (!_current(generation)) return;
            unawaited(portForwards.close());
            if (_shell == null) _remoteClosed();
          },
          onError: (Object e) {
            if (_current(generation) && status == ConnectionStatus.connected) {
              _fail(e);
            }
          },
        ),
      );
      await client.authenticated;
      if (!_current(generation)) return;
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
      if (_current(generation)) _fail(verificationError ?? e);
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
    final client = _client;
    _client = null;
    if (client != null) {
      // Peer disconnects can make flushing the final close packet fail.
      unawaited(client.close().catchError((Object _) {}));
    }
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
