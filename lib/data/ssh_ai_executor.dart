import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'terminal_ai.dart';

class SshAiExecutor implements AiCommandExecutor {
  SshAiExecutor(this.open);
  final Future<SSHSession> Function(String) open;
  final _cancelled = Completer<void>();
  SSHSession? _active;

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
    final session = _active;
    if (session != null) _terminate(session);
  }

  @override
  Future<AiCommandResult> execute(
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
                  final remaining = 16000 - output.length;
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
      await Future.any([
        Future.wait([...done, session.done]),
        _cancelled.future.then<List<void>>(
          (_) => throw const AiFailure('任务已停止'),
        ),
      ]).timeout(const Duration(seconds: 60));
      if (_cancelled.isCompleted) throw const AiFailure('任务已停止');
      return AiCommandResult(
        output.toString(),
        session.exitCode,
        truncated: truncated,
      );
    } on TimeoutException {
      if (session != null) _terminate(session);
      throw const AiFailure('命令超时，已请求终止；请检查服务器上的进程状态');
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
}
