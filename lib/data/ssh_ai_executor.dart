import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';

import 'ai_privilege.dart';
import 'terminal_ai.dart';

const _aiOutputLimit = 16000;
const _privilegeOpenTimeout = Duration(seconds: 15);
const _privilegeAuthTimeout = Duration(seconds: 30);
const _cancelledMessage = '任务已停止';
const _privilegeBusyMessage = '上一条 root 命令仍在执行，请稍后重试';
const _privilegeClosedMessage = 'root 权限通道已关闭，请重新提权';
const _privilegeFailureMessage = '提权失败，请检查密码或服务器 sudo 权限后重试';
const _privilegeTimeoutMessage = '提权超时，请检查连接后重试';
const _privilegePasswordMessage = '密码不能包含换行、回车或 NUL 字符';
const _privilegeCancelledMessage = '提权已取消';

/// One in-flight [SshAiExecutor.elevate] call.
///
/// [SshAiExecutor.revokePrivilege] cancels the current attempt so a late
/// channel open, sudo handshake or READY can never install a root channel
/// after the user rejected (or the turn ended) that authorization. A newer
/// attempt gets its own object, so an old attempt's cleanup can only touch the
/// supervisor it created itself.
class _ElevationAttempt {
  final _cancelled = Completer<void>();

  bool get cancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

class SshAiExecutor implements AiSessionExecutor, AiPrivilegeExecutor {
  SshAiExecutor(
    Future<SSHSession> Function(String) open, {
    this.systemContext = '',
    Future<SSHSession> Function(String command)? openPrivilege,
    Future<AiForwardResult> Function(
      AiForwardRequest request, {
      required bool save,
    })?
    startForward,
    Future<void> Function(String ruleId)? stopForward,
  }) : open = open,
       openPrivilege = openPrivilege ?? open,
       startForward = startForward ?? _noForward,
       stopForward = stopForward ?? _ignoreStop;

  /// Opens the default non-interactive command channel.
  final Future<SSHSession> Function(String) open;

  /// Opens the dedicated channel used for the root supervisor. It must create
  /// a fresh exec channel with a writable stdin; it is never the human shell.
  final Future<SSHSession> Function(String) openPrivilege;

  /// Snapshot of the connected endpoint, regenerated for every AI turn.
  @override
  final String systemContext;

  final Future<AiForwardResult> Function(
    AiForwardRequest request, {
    required bool save,
  })
  startForward;
  final Future<void> Function(String ruleId) stopForward;

  static Future<AiForwardResult> _noForward(
    AiForwardRequest request, {
    required bool save,
  }) async => throw const AiFailure('当前会话未配置端口转发');

  static Future<void> _ignoreStop(String ruleId) async {}

  final _cancelled = Completer<void>();
  SSHSession? _active;
  _RootSupervisor? _root;

  /// The authorization attempt currently allowed to install a root channel.
  /// Unlike a shared boolean, it survives a revoke: the old attempt can still
  /// finish (and clean only its own session), while a new [elevate] starts
  /// immediately with a fresh object.
  _ElevationAttempt? _elevation;

  /// Set once this turn obtained root. It is deliberately not cleared by
  /// [revokePrivilege]: after a lost or revoked channel, commands must fail
  /// instead of silently running with the unprivileged identity.
  bool _rootGranted = false;
  bool _rootBusy = false;

  @override
  bool get elevated => _rootGranted && _root?.ready == true;

  bool _attemptLive(_ElevationAttempt attempt) =>
      identical(_elevation, attempt) &&
      !attempt.cancelled &&
      !_cancelled.isCompleted;

  void _invalidateElevation() {
    final attempt = _elevation;
    _elevation = null;
    attempt?.cancel();
  }

  void _terminate(SSHSession session) {
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {}
    try {
      session.close();
    } catch (_) {}
  }

  @override
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _invalidateElevation();
    final session = _active;
    if (session != null) _terminate(session);
    _closeRoot();
  }

  @override
  void revokePrivilege() {
    // Cancel the authorization that is still opening or authenticating: a
    // late channel or READY from it must not become usable after the user
    // rejected it. Only this attempt is closed; the executor stays alive for
    // ordinary commands and a new authorization.
    _invalidateElevation();
    _closeRoot();
  }

  void _closeRoot() {
    final root = _root;
    _root = null;
    root?.close();
  }

  @override
  Future<void> elevate(String password) async {
    if (_cancelled.isCompleted) throw const AiFailure(_cancelledMessage);
    _validatePassword(password);
    if (elevated) return;
    final active = _elevation;
    if (active != null && !active.cancelled) {
      throw const AiFailure('正在提权，请稍候');
    }
    final attempt = _elevation = _ElevationAttempt();
    try {
      _closeRoot();
      try {
        final token = _randomToken();
        final prompt = '[harbor-ai-sudo-$token]';
        final session = await _openRootChannel(
          _rootCommand(token, prompt),
          attempt,
        );
        if (!_attemptLive(attempt)) {
          // A channel that arrives after revoke is closed before it can ever
          // run sudo or receive a password.
          _terminate(session);
          throw const AiFailure(_privilegeCancelledMessage);
        }
        late final _RootSupervisor supervisor;
        supervisor = _RootSupervisor(session, token);
        supervisor.onClosed = () {
          if (identical(_root, supervisor)) _root = null;
        };
        supervisor.listen();
        _root = supervisor;
        try {
          await supervisor.start(
            password: password,
            cancelled: Future.any<void>([
              _cancelled.future,
              attempt.whenCancelled,
            ]),
          );
        } catch (_) {
          supervisor.close();
          if (identical(_root, supervisor)) _root = null;
          if (_cancelled.isCompleted) {
            throw const AiFailure(_cancelledMessage);
          }
          if (!_attemptLive(attempt)) {
            throw const AiFailure(_privilegeCancelledMessage);
          }
          rethrow;
        }
        if (_cancelled.isCompleted) {
          supervisor.close();
          if (identical(_root, supervisor)) _root = null;
          throw const AiFailure(_cancelledMessage);
        }
        if (!_attemptLive(attempt)) {
          // A revoked attempt must never keep the channel it just opened.
          supervisor.close();
          if (identical(_root, supervisor)) _root = null;
          throw const AiFailure(_privilegeCancelledMessage);
        }
        if (_root?.ready != true) {
          throw const AiFailure(_privilegeClosedMessage);
        }
        _rootGranted = true;
        if (!elevated) throw const AiFailure(_privilegeClosedMessage);
      } on AiFailure catch (error) {
        if (_cancelled.isCompleted) throw const AiFailure(_cancelledMessage);
        if (!_attemptLive(attempt)) {
          throw const AiFailure(_privilegeCancelledMessage);
        }
        // A channel that closes before the supervisor reports root is an
        // authentication failure (including sudo requiretty); keep fixed text.
        if (error.message == _privilegeClosedMessage) {
          throw const AiFailure(_privilegeFailureMessage);
        }
        rethrow;
      } on TimeoutException {
        if (_cancelled.isCompleted) throw const AiFailure(_cancelledMessage);
        if (!_attemptLive(attempt)) {
          throw const AiFailure(_privilegeCancelledMessage);
        }
        throw const AiFailure(_privilegeTimeoutMessage);
      } catch (_) {
        if (_cancelled.isCompleted) throw const AiFailure(_cancelledMessage);
        if (!_attemptLive(attempt)) {
          throw const AiFailure(_privilegeCancelledMessage);
        }
        throw const AiFailure(_privilegeFailureMessage);
      }
    } finally {
      // Only clear the attempt that is still ours: a newer authorization must
      // never be reset by this attempt's cleanup.
      if (identical(_elevation, attempt)) _elevation = null;
    }
  }

  static void _validatePassword(String password) {
    if (password.length > 4096) throw const AiFailure('密码过长');
    if (password.contains('\n') ||
        password.contains('\r') ||
        password.contains('\u0000')) {
      throw const AiFailure(_privilegePasswordMessage);
    }
  }

  static final _random = Random.secure();

  static String _randomToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Builds the one SSH exec command that starts the root supervisor.
  ///
  /// The supervisor is placed in sudo's argv, so a NOPASSWD rule needs no
  /// stdin handshake at all. sudo's shell mode re-escapes arguments for the
  /// login shell; the wrapper is octal-encoded because sudo leaves `$`
  /// unescaped (so any variable in the command would expand in the login
  /// shell instead of the root supervisor). `printf %b` is POSIX and needs no
  /// external decoder.
  static String _rootCommand(String token, String prompt) {
    final payload = _octalPayload(_bootstrapScript(token));
    // Keep the decoded script as one eval argument: unquoted command
    // substitution would word-split and glob it before eval sees it.
    final wrapper = "eval \"`printf '%b' '$payload'`\"";
    return 'sudo -S -p ${_shellQuote(prompt)} -i -- /bin/sh -c '
        '${_shellQuote(wrapper)}';
  }

  static String _octalPayload(String script) {
    final buffer = StringBuffer();
    for (final unit in script.codeUnits) {
      // The supervisor script is ASCII. Refuse rather than silently encoding
      // a code unit printf %b would decode differently.
      if (unit > 0x7f) throw const AiFailure(_privilegeFailureMessage);
      buffer
        ..write(r'\0')
        ..write(unit.toRadixString(8).padLeft(3, '0'));
    }
    return buffer.toString();
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  Future<SSHSession> _openRootChannel(
    String command,
    _ElevationAttempt attempt,
  ) async {
    SSHSession? session;
    var abandoned = false;
    try {
      final opening = openPrivilege(command).then((value) {
        if (abandoned || !_attemptLive(attempt)) _terminate(value);
        return value;
      });
      session = await Future.any([
        opening,
        _cancelled.future.then<SSHSession>(
          (_) => throw const AiFailure(_cancelledMessage),
        ),
        // A revoke must interrupt the opening itself, not wait for the SSH
        // channel timeout while the user has already refused.
        attempt.whenCancelled.then<SSHSession>(
          (_) => throw const AiFailure(_privilegeCancelledMessage),
        ),
      ]).timeout(_privilegeOpenTimeout);
      if (_cancelled.isCompleted) {
        _terminate(session);
        throw const AiFailure(_cancelledMessage);
      }
      if (!_attemptLive(attempt)) {
        _terminate(session);
        throw const AiFailure(_privilegeCancelledMessage);
      }
      return session;
    } on TimeoutException {
      if (session != null) _terminate(session);
      throw const AiFailure('SSH root 通道建立超时，请检查连接后重试');
    } finally {
      abandoned = true;
    }
  }

  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async {
    final root = _root;
    if (_rootGranted || root != null) {
      if (root == null) throw const AiFailure(_privilegeClosedMessage);
      if (!root.ready) throw const AiFailure('root 权限尚未就绪，请等待提权完成');
      return _executeElevated(root, command, onOutput);
    }
    return _executeUnprivileged(command, onOutput);
  }

  Future<AiCommandResult> _executeElevated(
    _RootSupervisor root,
    String command,
    void Function(String) onOutput,
  ) async {
    if (_cancelled.isCompleted) throw const AiFailure(_cancelledMessage);
    if (command.trim().isEmpty) throw const AiFailure('命令为空');
    if (command.contains('\u0000')) throw const AiFailure('命令包含无效字符');
    if (_rootBusy) throw const AiFailure(_privilegeBusyMessage);
    _rootBusy = true;
    final output = StringBuffer();
    var truncated = false;
    void emit(String text) {
      final remaining = _aiOutputLimit - output.length;
      if (text.length > remaining) truncated = true;
      if (remaining <= 0) return;
      final part = text.length > remaining
          ? text.substring(0, remaining)
          : text;
      output.write(part);
      onOutput(part);
    }

    try {
      final Future<int> running;
      try {
        running = root.run(command, emit);
      } on AiFailure {
        _rootBusy = false;
        rethrow;
      }
      // The cancellation branch can win the race below. Attach a listener so a
      // later channel error is never reported as an unhandled async error.
      unawaited(running.then<void>((_) {}, onError: (Object _) {}));
      final exitCode = await Future.any([
        running,
        _cancelled.future.then<int>(
          (_) => throw const AiFailure(_cancelledMessage),
        ),
      ]);
      if (_cancelled.isCompleted) throw const AiFailure(_cancelledMessage);
      return AiCommandResult(
        output.toString(),
        exitCode,
        truncated: truncated,
      );
    } finally {
      _rootBusy = false;
    }
  }

  Future<AiCommandResult> _executeUnprivileged(
    String command,
    void Function(String) onOutput,
  ) async {
    if (_cancelled.isCompleted) throw const AiFailure('任务已停止');
    SSHSession? session;
    final subscriptions = <StreamSubscription<String>>[];
    var abandoned = false;
    try {
      final opening = open(command).then((value) {
        if (abandoned || _cancelled.isCompleted) _terminate(value);
        return value;
      });
      session = await Future.any([
        opening,
        _cancelled.future.then<SSHSession>(
          (_) => throw const AiFailure('任务已停止'),
        ),
      ]).timeout(const Duration(seconds: 15));
      if (_cancelled.isCompleted) throw const AiFailure('任务已停止');
      _active = session;
      final output = StringBuffer();
      var truncated = false;
      final done = <Future<void>>[];
      for (final stream in [session.stdout, session.stderr]) {
        final finished = Completer<void>();
        done.add(finished.future);
        subscriptions.add(
          stream
              .cast<List<int>>()
              .transform(const Utf8Decoder(allowMalformed: true))
              .listen(
                (text) {
                  final remaining = _aiOutputLimit - output.length;
                  if (text.length > remaining) truncated = true;
                  if (remaining <= 0) return;
                  final part = text.length > remaining
                      ? text.substring(0, remaining)
                      : text;
                  output.write(part);
                  onOutput(part);
                },
                onDone: finished.complete,
                onError: finished.completeError,
              ),
        );
      }
      // No interactive stdin: commands such as sudo/read must fail rather than hang.
      unawaited(session.stdin.close().catchError((Object _) {}));
      // Downloads, installs and quiet commands may take arbitrarily long.
      // Keep the channel alive until it exits, disconnects or the user stops it.
      await Future.any([
        Future.wait([...done, session.done]),
        _cancelled.future.then<List<void>>(
          (_) => throw const AiFailure('任务已停止'),
        ),
      ]);
      if (_cancelled.isCompleted) throw const AiFailure('任务已停止');
      return AiCommandResult(
        output.toString(),
        session.exitCode,
        truncated: truncated,
      );
    } on TimeoutException {
      if (session != null) _terminate(session);
      throw const AiFailure('SSH 命令通道建立超时，请检查连接后重试');
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw const AiFailure('SSH 命令执行中断，请检查连接和服务器状态');
    } finally {
      abandoned = true;
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      session?.close();
      _active = null;
    }
  }

  @override
  Future<AiForwardResult> createPortForward(
    AiForwardRequest request, {
    required bool save,
  }) async {
    if (_cancelled.isCompleted) throw const AiFailure('任务已停止');
    request.validate();
    final result = await startForward(request, save: save);
    // The user can stop the turn while the listener is being bound. The
    // tunnel must not outlive a cancelled turn unless the model received its
    // result, so undo it here and report the cancellation truthfully.
    if (_cancelled.isCompleted) {
      try {
        await stopForward(result.ruleId);
      } catch (_) {}
      throw const AiFailure('任务已停止，端口转发已撤销');
    }
    return result;
  }
}

/// Persistent root supervisor running inside `sudo -i /bin/sh -c`.
///
/// Both the command output and its completion frame travel on stdout, so the
/// two cannot be reordered by independent SSH streams. stdout after READY is
/// parsed with a random marker that is held back only while it could still be
/// a split marker, preserving output without newlines or across packets.
/// stderr is never forwarded: during authentication it carries sudo's prompt
/// and errors plus the root login profile, all of which must not reach the
/// model. Every command runs in its own `sh -c` child with stdin attached to
/// `/dev/null`, so a command can neither read the supervisor's frame stream
/// nor keep `cd`/`export` state for the next command.
class _RootSupervisor {
  _RootSupervisor(this.session, this.token);

  final SSHSession session;
  final String token;
  void Function()? onClosed;

  final _readySignal = Completer<void>();
  final _closedSignal = Completer<void>();
  final _promptSignal = Completer<void>();
  final _errorSignal = Completer<void>();

  final _stdoutPending = StringBuffer();
  final _stderrPending = StringBuffer();
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  bool _ready = false;
  bool _disposed = false;
  bool _stdoutDone = false;
  bool _stderrDone = false;
  bool _promptSeen = false;
  bool _passwordSent = false;
  _RootRun? _run;

  bool get ready => _ready && !_disposed;

  String get _promptMarker => '[harbor-ai-sudo-$token]';

  String get _endMarker => '$token END ';

  void listen() {
    // Errors may complete this future during a phase that is no longer
    // awaited; keep a listener so they are never unhandled.
    unawaited(_errorSignal.future.catchError((Object _) {}));
    _stdoutSubscription = session.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          _onStdout,
          onDone: () {
            _stdoutDone = true;
            _maybeClosed();
          },
          onError: (Object _) => _fail(const AiFailure(_privilegeClosedMessage)),
        );
    _stderrSubscription = session.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          _onStderr,
          onDone: () {
            _stderrDone = true;
            _maybeClosed();
          },
          onError: (Object _) => _fail(const AiFailure(_privilegeClosedMessage)),
        );
  }

  Future<void> start({
    required String password,
    required Future<void> cancelled,
  }) async {
    final timer = Timer(_privilegeAuthTimeout, () {
      _fail(const AiFailure(_privilegeTimeoutMessage));
    });
    try {
      // NOPASSWD produces READY without any stdin write; a password rule
      // produces the prompt on stderr. Nothing else is written before one of
      // those happens, so the password can never be consumed as command data.
      await Future.any([
        _readySignal.future,
        _promptSignal.future,
        _errorSignal.future,
        _closedSignal.future,
        cancelled,
      ]);
      if (!ready && _promptSeen) {
        _passwordSent = true;
        // sudo reads exactly one line from stdin in -S mode.
        await _send('$password\n');
        await Future.any([
          _readySignal.future,
          _errorSignal.future,
          _closedSignal.future,
          cancelled,
        ]);
      }
      if (!ready) throw const AiFailure(_privilegeFailureMessage);
    } finally {
      timer.cancel();
    }
  }

  Future<void> _send(String data) async {
    if (_disposed) throw const AiFailure(_privilegeClosedMessage);
    try {
      // The channel's single-subscription sink preserves write order. Do not
      // call session.flush() here: it flushes the shared socket through
      // IOSink.flush(), which marks the sink bound and makes a concurrently
      // processed window-adjust packet throw "StreamSink is bound to a stream".
      session.stdin.add(utf8.encode(data));
    } catch (_) {
      throw const AiFailure(_privilegeClosedMessage);
    }
  }

  void _onStdout(String text) {
    if (_disposed) return;
    _stdoutPending.write(text);
    if (_ready) {
      _drainStdout();
      return;
    }
    final buffer = _stdoutPending.toString();
    final marker = '$token READY ';
    final index = buffer.indexOf(marker);
    if (index < 0) {
      // Root login profile output is discarded. Keep only enough to match a
      // READY line split across chunks.
      if (buffer.length > 65536) {
        final tail = buffer.substring(buffer.length - 256);
        _stdoutPending
          ..clear()
          ..write(tail);
      }
      return;
    }
    final end = buffer.indexOf('\n', index + marker.length);
    if (end < 0) return;
    final uid = buffer.substring(index + marker.length, end).trim();
    if (uid != '0') {
      _stdoutPending.clear();
      _fail(const AiFailure(_privilegeFailureMessage));
      return;
    }
    final remainder = buffer.substring(end + 1);
    _stdoutPending
      ..clear()
      ..write(remainder);
    _ready = true;
    _stderrPending.clear();
    if (!_readySignal.isCompleted) _readySignal.complete();
    // No command has been written yet, so there is normally no remainder.
    _drainStdout();
  }

  void _onStderr(String text) {
    if (_disposed || _ready) return;
    _stderrPending.write(text);
    final snapshot = _stderrPending.toString();
    final index = snapshot.indexOf(_promptMarker);
    if (index >= 0) {
      // A real sudo prompt has no trailing newline: sudo writes the marker
      // and waits. A marker in an echoed/logged line is followed by a
      // newline and must never trigger sending the password.
      final after = snapshot.substring(index + _promptMarker.length);
      if (!after.contains('\n')) {
        // Remove the marker so the same prompt is not mistaken for a retry.
        _stderrPending
          ..clear()
          ..write(snapshot.substring(0, index) + after);
        if (_promptSeen || _passwordSent) {
          _fail(const AiFailure(_privilegeFailureMessage));
          return;
        }
        _promptSeen = true;
        if (!_promptSignal.isCompleted) _promptSignal.complete();
        return;
      }
    }
    if (_stderrPending.length > 8192) {
      final tail = snapshot.substring(snapshot.length - 512);
      _stderrPending
        ..clear()
        ..write(tail);
    }
  }

  /// Forwards everything except a possible partial END marker. This keeps
  /// arbitrary output (no newline, any packet split) intact while still
  /// allowing a marker split across two SSH data packets to be recognized.
  void _drainStdout() {
    while (true) {
      final buffer = _stdoutPending.toString();
      final index = buffer.indexOf(_endMarker);
      if (index < 0) {
        final keep = _partialMarkerSuffix(buffer, _endMarker);
        final forward = buffer.length - keep;
        if (forward <= 0) return;
        final text = buffer.substring(0, forward);
        _stdoutPending
          ..clear()
          ..write(buffer.substring(forward));
        _run?.emit(text);
        return;
      }
      if (index > 0) {
        final text = buffer.substring(0, index);
        _run?.emit(text);
      }
      final rest = buffer.substring(index + _endMarker.length);
      final match = RegExp(r'^([0-9]+)\n').firstMatch(rest);
      if (match == null) {
        _stdoutPending
          ..clear()
          ..write(buffer.substring(index));
        return;
      }
      final code = int.tryParse(match.group(1)!);
      final after = rest.substring(match.end);
      _stdoutPending
        ..clear()
        ..write(after);
      final run = _run;
      _run = null;
      if (run != null) {
        if (code == null) {
          run.fail(const AiFailure(_privilegeFailureMessage));
        } else {
          run.complete(code);
        }
      }
      // Continue in case bytes followed the frame. Normally there are none.
    }
  }

  static int _partialMarkerSuffix(String text, String marker) {
    final limit = min(marker.length - 1, text.length);
    for (var length = limit; length > 0; length--) {
      if (text.endsWith(marker.substring(0, length))) return length;
    }
    return 0;
  }

  Future<int> run(String command, void Function(String) onOutput) async {
    if (!ready) throw const AiFailure(_privilegeClosedMessage);
    if (_run != null) throw const AiFailure(_privilegeBusyMessage);
    final run = _RootRun(onOutput);
    _run = run;
    // Attach early: a channel failure may complete this error before the
    // write/flush below reaches its own await.
    unawaited(run.exit.then<void>((_) {}, onError: (Object _) {}));
    try {
      // Channel sink writes are ordered; a socket-level flush would race with
      // window-adjust packets and is not needed to deliver the frame.
      session.stdin.add(utf8.encode('$token B\n$command\n$token E\n'));
    } catch (_) {
      if (identical(_run, run)) _run = null;
      _fail(const AiFailure(_privilegeClosedMessage));
      throw const AiFailure(_privilegeClosedMessage);
    }
    try {
      return await run.exit;
    } finally {
      if (identical(_run, run)) _run = null;
    }
  }

  void _maybeClosed() {
    if (!_stdoutDone || !_stderrDone) return;
    _fail(const AiFailure(_privilegeClosedMessage));
  }

  void _fail(Object error) {
    if (_disposed) return;
    final failure = error is AiFailure
        ? error
        : const AiFailure(_privilegeClosedMessage);
    if (!_errorSignal.isCompleted) _errorSignal.completeError(failure);
    final run = _run;
    _run = null;
    run?.fail(failure);
    _disposeTransport();
  }

  void _disposeTransport() {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    final stdoutSubscription = _stdoutSubscription;
    final stderrSubscription = _stderrSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    if (stdoutSubscription != null) unawaited(stdoutSubscription.cancel());
    if (stderrSubscription != null) unawaited(stderrSubscription.cancel());
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {}
    try {
      session.close();
    } catch (_) {}
    if (!_closedSignal.isCompleted) _closedSignal.complete();
    onClosed?.call();
  }

  void close() {
    if (_disposed) return;
    final run = _run;
    _run = null;
    run?.fail(const AiFailure(_privilegeClosedMessage));
    _fail(const AiFailure(_privilegeClosedMessage));
  }
}

/// POSIX sh supervisor source. It is octal-encoded into the sudo command, so
/// the shell that parses it reads it from `eval`, not from stdin; stdin is
/// reserved exclusively for the framed command loop below.
const _bootstrapTemplate = r'''
t=__TOKEN__
nl=$(printf '\n_'); nl=${nl%_}
uid=$(id -u) || exit 70
[ "$uid" = 0 ] || { printf '%s NOTROOT\n' "$t" >&2; exit 70; }
printf '\n%s READY 0\n' "$t"
while IFS= read -r line; do
  [ "$line" = "$t B" ] || { printf '%s BAD\n' "$t" >&2; exit 71; }
  cmd=
  ok=0
  while IFS= read -r line; do
    if [ "$line" = "$t E" ]; then ok=1; break; fi
    cmd="$cmd$line$nl"
  done
  [ "$ok" = 1 ] || { printf '%s EOF\n' "$t" >&2; exit 72; }
  sh -c "$cmd" </dev/null 2>&1
  code=$?
  printf '%s END %s\n' "$t" "$code"
done
printf '%s EXIT\n' "$t" >&2
''';

String _bootstrapScript(String token) => _bootstrapTemplate
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('__TOKEN__', "'$token'");

class _RootRun {
  _RootRun(this.onOutput);

  final void Function(String) onOutput;
  final _exit = Completer<int>();

  Future<int> get exit => _exit.future;

  void emit(String text) {
    if (!_exit.isCompleted) onOutput(text);
  }

  void complete(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void fail(Object error) {
    if (!_exit.isCompleted) _exit.completeError(error);
  }
}
