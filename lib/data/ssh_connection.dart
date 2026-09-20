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
import 'terminal_ai.dart';
import 'ssh_ai_executor.dart';
import 'remote_commands.dart';
import 'sftp_files.dart';
import '../domain/remote_file.dart';

enum ConnectionStatus { connecting, connected, closed, failed }

class SshConnection extends ChangeNotifier {
  SshConnection({required this.id, required this.host});
  final String id;
  AiCommandExecutor createAiExecutor() => SshAiExecutor((command) async {
    final client = _client;
    if (client == null || status != ConnectionStatus.connected || _closed) {
      throw const AiFailure('SSH 已断开，请重新连接');
    }
    return client.execute(command);
  });
  RemoteFileSystem get files => SftpFiles(_openSftp);
  final Host host;
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
  int _openOutputStreams = 0;
  final List<StreamSubscription<String>> _subscriptions = [];
  String get statusLabel => switch (status) {
    ConnectionStatus.connecting => '正在连接',
    ConnectionStatus.connected => '已连接',
    ConnectionStatus.closed => '已断开',
    ConnectionStatus.failed => '连接失败',
  };
  Future<void> connect(
    Credentials credentials,
    HostRepository repository,
    TrustHost prompt, {
    bool openShell = true,
  }) async {
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
      if (_closed) {
        socket.destroy();
        return;
      }
      final client = SSHClient(
        socket,
        username: host.username,
        handshakeTimeout: const Duration(minutes: 5),
        authTimeout: const Duration(seconds: 30),
        identities: identities,
        onPasswordRequest: host.authMethod == AuthMethod.password
            ? () => credentials.password
            : null,
        keepAliveInterval: const Duration(seconds: 20),
        onVerifyHostKey: (type, bytes) async {
          if (_closed) return false;
          try {
            return await repository.verifyHost(host, type, utf8.decode(bytes), (
              t,
              f,
            ) async {
              final accepted = await prompt(t, f);
              return !_closed && accepted;
            });
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
            if (_shell == null) _remoteClosed();
          },
          onError: (Object e) {
            if (status == ConnectionStatus.connected) _fail(e);
          },
        ),
      );
      await client.authenticated;
      if (_closed) return;
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
      if (_closed) {
        shell.close();
        return;
      }
      _shell = shell;
      terminal.onOutput = (data) {
        if (status == ConnectionStatus.connected) {
          commandHistory.observeInput(data);
          inputGeneration.value++;
          shell.write(Uint8List.fromList(utf8.encode(data)));
        }
      };
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        if (status == ConnectionStatus.connected) {
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
                terminal.write,
                onError: (Object e) => _fail(e),
                onDone: () {
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
          onError: (Object e) => _fail(e),
        ),
      );
    } catch (e) {
      if (!_closed) _fail(verificationError ?? e);
    }
  }

  void send(String data) => terminal.onOutput?.call(data);

  Future<SftpClient> _openSftp() async {
    final client = _client;
    if (client == null || _closed) throw StateError('SSH is disconnected');
    final sftp = await client.sftp();
    if (_closed) {
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
      if (_closed) return const [];
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
      if (_closed || query.exitCode != 0) return const [];
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

  Future<void> _readCommandHistory() async {
    try {
      final sftp = await (_sftp ??= _openSftp()).timeout(
        const Duration(seconds: 5),
      );
      _remoteHome ??= await sftp
          .absolute('.')
          .timeout(const Duration(seconds: 5));
      final histories = <({int modified, List<String> commands})>[];
      for (final name in ['.bash_history', '.zsh_history']) {
        SftpFile? file;
        try {
          final path = '$_remoteHome/$name';
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
      if (!_closed && !_disposed) {
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
    if (status != ConnectionStatus.connected) return const [];
    try {
      final sftp = await (_sftp ??= _openSftp()).timeout(
        const Duration(seconds: 5),
      );
      if (path == '~' || path.startsWith('~/')) {
        _remoteHome ??= await sftp
            .absolute('.')
            .timeout(const Duration(seconds: 5));
        path = '$_remoteHome${path.substring(1)}';
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
      return result;
    } catch (_) {
      // Servers may disable SFTP. Completion must not interrupt terminal input.
      return const [];
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
    _closed = true;
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
    final client = _client;
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
    super.dispose();
  }
}
