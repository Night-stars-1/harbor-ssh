import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_privilege.dart';
import 'package:harbor_ssh/data/ssh_ai_executor.dart';
import 'package:harbor_ssh/data/ssh_algorithms.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/domain/host.dart';

import 'support.dart';

/// Endpoint of an isolated, disposable SSH host.
///
/// No default is provided: the suite never touches a production machine, and
/// missing variables turn the affected scenario into an explicit skip.
class _SshTarget {
  const _SshTarget({required this.host, required this.port});

  final String host;
  final int port;

  static _SshTarget? fromPlatform() {
    final env = Platform.environment;
    final host = (env['HARBOR_SUDO_HOST'] ?? '').trim();
    final port = int.tryParse((env['HARBOR_SUDO_PORT'] ?? '').trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
    return _SshTarget(host: host, port: port);
  }
}

/// A synthetic non-root login user whose sudo requires a password.
class _SudoEnvironment {
  const _SudoEnvironment({
    required this.target,
    required this.username,
    required this.sshPassword,
    required this.sudoPassword,
  });

  final _SshTarget target;
  final String username;
  final String sshPassword;
  final String sudoPassword;

  static const requiredVariables = [
    'HARBOR_SUDO_HOST',
    'HARBOR_SUDO_PORT',
    'HARBOR_SUDO_USER',
    'HARBOR_SUDO_SSH_PASSWORD',
    'HARBOR_SUDO_SUDO_PASSWORD',
  ];

  static _SudoEnvironment? fromPlatform(_SshTarget? target) {
    if (target == null) return null;
    final env = Platform.environment;
    final user = (env['HARBOR_SUDO_USER'] ?? '').trim();
    final sshPassword = env['HARBOR_SUDO_SSH_PASSWORD'] ?? '';
    final sudoPassword = env['HARBOR_SUDO_SUDO_PASSWORD'] ?? '';
    if (user.isEmpty || sshPassword.isEmpty || sudoPassword.isEmpty) {
      return null;
    }
    return _SudoEnvironment(
      target: target,
      username: user,
      sshPassword: sshPassword,
      sudoPassword: sudoPassword,
    );
  }
}

/// A second synthetic user whose sudoers rule is NOPASSWD.
class _PasswordlessEnvironment {
  const _PasswordlessEnvironment({
    required this.target,
    required this.username,
    required this.sshPassword,
  });

  final _SshTarget target;
  final String username;
  final String sshPassword;

  static const requiredVariables = [
    'HARBOR_SUDO_HOST',
    'HARBOR_SUDO_PORT',
    'HARBOR_SUDO_NOPASSWD_USER',
    'HARBOR_SUDO_NOPASSWD_SSH_PASSWORD',
  ];

  static _PasswordlessEnvironment? fromPlatform(_SshTarget? target) {
    if (target == null) return null;
    final env = Platform.environment;
    final user = (env['HARBOR_SUDO_NOPASSWD_USER'] ?? '').trim();
    final sshPassword = env['HARBOR_SUDO_NOPASSWD_SSH_PASSWORD'] ?? '';
    if (user.isEmpty || sshPassword.isEmpty) return null;
    return _PasswordlessEnvironment(
      target: target,
      username: user,
      sshPassword: sshPassword,
    );
  }
}

final _target = _SshTarget.fromPlatform();
final _environment = _SudoEnvironment.fromPlatform(_target);
final _passwordlessEnvironment = _PasswordlessEnvironment.fromPlatform(
  _target,
);

Future<void> _eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      fail(reason ?? '条件在 $timeout 内未满足');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Types a command into the human terminal and waits for a marker that does
/// not appear literally in the typed command, so shell echo cannot fake it.
Future<void> _waitForManualShell(
  SshConnection connection,
  String command,
  String marker,
) async {
  connection.send('$command\r');
  await _eventually(
    () => connection.terminal.buffer.getText().contains(marker),
    reason: '人工终端未在 20 秒内输出 $marker',
  );
}

Future<SshConnection> _connect(
  _SshTarget target,
  String username,
  String sshPassword,
) async {
  final connection = SshConnection(
    id: 'sudo-smoke-$username',
    host: Host(
      id: 'sudo-smoke-$username',
      name: 'sudo 隔离环境',
      address: target.host,
      port: target.port,
      username: username,
    ),
  );
  addTearDown(connection.dispose);
  await connection.connect(
    Credentials(password: sshPassword),
    memoryRepository(),
    (_, _) async => true,
  );
  expect(
    connection.status,
    ConnectionStatus.connected,
    reason: connection.error,
  );
  expect(connection.error, isNull);
  return connection;
}

/// Opens a dedicated, non-terminal SSH client for executor channels.
///
/// The authorization scenario needs its own exec sessions so the human
/// terminal used by the other scenarios stays an untouched control.
Future<SSHClient> _connectClient(
  _SshTarget target,
  String username,
  String sshPassword,
) async {
  final socket = await SSHSocket.connect(
    target.host,
    target.port,
    timeout: const Duration(seconds: 15),
  );
  final client = SSHClient(
    socket,
    username: username,
    algorithms: harborSshAlgorithms,
    handshakeTimeout: const Duration(minutes: 5),
    authTimeout: const Duration(seconds: 30),
    onPasswordRequest: () => sshPassword,
    onVerifyHostKey: (type, bytes) async => true,
  );
  addTearDown(() async {
    await client.close();
  });
  await client.authenticated;
  return client;
}

void main() {
  group('真实 SSH sudo 提权协议', () {
    test(
      '普通身份、错误密码、连续 root 命令、stdin EOF、退出码、cd 与取消后终端可用',
      () async {
        final env = _environment!;
        final connection = await _connect(
          env.target,
          env.username,
          env.sshPassword,
        );

        // The human shell is usable before AI touches anything.
        await _waitForManualShell(
          connection,
          "printf 'HARBOR_SUDO_%s\\n' SHELL_READY",
          'HARBOR_SUDO_SHELL_READY',
        );

        final executor = connection.createAiExecutor();
        expect(executor, isA<AiPrivilegeExecutor>());
        final privilege = executor as AiPrivilegeExecutor;

        // Every byte the executor shows to a caller is inspected below for
        // credential or sudo-prompt leakage.
        final callbackOutput = StringBuffer();
        Future<AiCommandResult> run(String command) async {
          final streamed = StringBuffer();
          final result = await executor.execute(command, (chunk) {
            streamed.write(chunk);
            callbackOutput.write(chunk);
          });
          // Streaming callbacks and the returned result describe the same
          // bounded output, with the sudo framing removed.
          expect(streamed.toString(), result.output);
          return result;
        }

        final unprivileged = await run('id -u');
        expect(unprivileged.exitCode, 0, reason: unprivileged.output);
        expect(
          unprivileged.output.trim(),
          isNot('0'),
          reason: '隔离环境应使用非 root 的登录用户；当前用户已是 root',
        );
        expect(privilege.elevated, isFalse);

        // A wrong password fails with a fixed, credential-free message and
        // leaves the executor unprivileged so it can be retried.
        final wrongPassword = '${env.sudoPassword}-wrong';
        String? wrongError;
        try {
          await privilege.elevate(wrongPassword);
          fail('错误密码不应完成提权');
        } on AiFailure catch (error) {
          wrongError = error.message;
        }
        expect(wrongError, isNotNull);
        expect(wrongError, isNot(contains(env.sudoPassword)));
        expect(wrongError, isNot(contains(env.sshPassword)));
        expect(privilege.elevated, isFalse);

        final afterFailure = await run('id -u');
        expect(afterFailure.output.trim(), isNot('0'));
        expect(afterFailure.exitCode, 0);

        // The correct password opens a real root channel.
        await privilege.elevate(env.sudoPassword);
        expect(privilege.elevated, isTrue);

        // Two separate commands both run as root, proving the privilege is
        // reused for the turn instead of surviving only one command.
        final firstRoot = await run('id -u');
        expect(firstRoot.exitCode, 0, reason: firstRoot.output);
        expect(firstRoot.output.trim(), '0');
        final secondRoot = await run('id -u');
        expect(secondRoot.exitCode, 0, reason: secondRoot.output);
        expect(secondRoot.output.trim(), '0');
        expect(privilege.elevated, isTrue);

        // Output boundaries: only the command's own stdout reaches the
        // caller, with no sudo prompt or control frame in between.
        final bounded = await run(
          "printf 'HARBOR_SUDO_BEGIN\\n'; id -u; printf 'HARBOR_SUDO_END\\n'",
        );
        expect(bounded.output.trim().split('\n'), [
          'HARBOR_SUDO_BEGIN',
          '0',
          'HARBOR_SUDO_END',
        ]);
        expect(bounded.output, isNot(contains('[harbor-ai-sudo-')));

        // Root commands get no interactive stdin: `cat` must see EOF rather
        // than hang waiting for input that can never arrive.
        final eof = await run('cat').timeout(const Duration(seconds: 15));
        expect(eof.output, isEmpty);
        expect(eof.exitCode, 0);

        // The remote exit code is propagated truthfully.
        final failing = await run('exit 7');
        expect(failing.exitCode, 7, reason: failing.output);

        // Every command is its own shell: `cd` does not leak into the next
        // command even while the root channel stays alive.
        final changed = await run('cd /tmp && pwd');
        expect(changed.output.trim(), '/tmp');
        final current = await run('pwd');
        expect(current.output.trim(), isNotEmpty);
        expect(current.output.trim(), isNot('/tmp'));

        // Cancel closes the elevated channel and the in-flight command fails
        // instead of continuing or silently degrading.
        final started = Completer<void>();
        final running = executor.execute(
          'echo HARBOR_SUDO_CANCEL_START; sleep 30; echo HARBOR_SUDO_CANCEL_END',
          (chunk) {
            callbackOutput.write(chunk);
            if (!started.isCompleted &&
                chunk.contains('HARBOR_SUDO_CANCEL_START')) {
              started.complete();
            }
          },
        );
        await started.future.timeout(const Duration(seconds: 15));
        final stopped = expectLater(running, throwsA(isA<AiFailure>()));
        executor.cancel();
        await stopped.timeout(const Duration(seconds: 15));
        expect(privilege.elevated, isFalse);
        expect(connection.status, ConnectionStatus.connected);

        // The human terminal never shared the AI root channel, so it keeps
        // working after the AI turn is cancelled.
        await _waitForManualShell(
          connection,
          "printf 'HARBOR_SUDO_%s\\n' MANUAL_ALIVE",
          'HARBOR_SUDO_MANUAL_ALIVE',
        );

        final seen = callbackOutput.toString();
        expect(seen, isNot(contains(env.sudoPassword)));
        expect(seen, isNot(contains(env.sshPassword)));
        expect(seen, isNot(contains('[harbor-ai-sudo-')));
        expect(
          connection.terminal.buffer.getText(),
          isNot(contains(env.sudoPassword)),
        );
        expect(
          connection.terminal.buffer.getText(),
          isNot(contains(env.sshPassword)),
        );
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: _environment == null
          ? '设置 ${_SudoEnvironment.requiredVariables.join('、')} '
                '后可运行带密码的 sudo 提权测试'
          : null,
    );

    test(
      'NOPASSWD sudo 空密码：普通身份、elevate 空串、真实 root id -u 与取消',
      () async {
        final env = _passwordlessEnvironment!;
        final connection = await _connect(
          env.target,
          env.username,
          env.sshPassword,
        );
        await _waitForManualShell(
          connection,
          "printf 'HARBOR_SUDO_%s\\n' NOPASSWD_READY",
          'HARBOR_SUDO_NOPASSWD_READY',
        );

        final executor = connection.createAiExecutor();
        expect(executor, isA<AiPrivilegeExecutor>());
        final privilege = executor as AiPrivilegeExecutor;
        final output = StringBuffer();
        Future<AiCommandResult> run(String command) => executor.execute(
          command,
          output.write,
        );

        final unprivileged = await run('id -u');
        expect(unprivileged.exitCode, 0, reason: unprivileged.output);
        expect(
          unprivileged.output.trim(),
          isNot('0'),
          reason: '免密场景也必须使用非 root 的登录用户',
        );
        expect(privilege.elevated, isFalse);

        // No password is available or needed: the configured NOPASSWD rule is
        // what authorizes this turn. The executor accepts the empty field so
        // the controller can forward it instead of rejecting it up front.
        await privilege.elevate('');
        expect(privilege.elevated, isTrue);

        final root = await run('id -u');
        expect(root.exitCode, 0, reason: root.output);
        expect(root.output.trim(), '0');

        executor.cancel();
        expect(privilege.elevated, isFalse);
        expect(connection.status, ConnectionStatus.connected);
        await _waitForManualShell(
          connection,
          "printf 'HARBOR_SUDO_%s\\n' NOPASSWD_MANUAL_OK",
          'HARBOR_SUDO_NOPASSWD_MANUAL_OK',
        );
        expect(output.toString(), isNot(contains(env.sshPassword)));
        expect(output.toString(), isNot(contains('[harbor-ai-sudo-')));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: _passwordlessEnvironment == null
          ? '设置 ${_PasswordlessEnvironment.requiredVariables.join('、')} '
                '后可运行 NOPASSWD 空密码提权测试'
          : null,
    );

    test(
      '撤销在途提权：迟到通道被关闭，新授权立即成功，普通命令仍用原执行器',
      () async {
        final env = _environment!;
        final client = await _connectClient(
          env.target,
          env.username,
          env.sshPassword,
        );

        var privilegeOpens = 0;
        final firstOpened = Completer<SSHSession>();
        final releaseFirst = Completer<void>();
        Future<SSHSession> open(String command) => client.execute(command);
        Future<SSHSession> openPrivilege(String command) async {
          if (privilegeOpens++ > 0) return client.execute(command);
          // Hold the executor before its exec channel is opened. Opening the
          // real sudo command here and withholding only the session object
          // would leave a sudo process waiting for a password, which holds
          // the server-side sudo timestamp lock and stalls the replacement
          // authorization's prompt. The gate therefore covers the "opening
          // still in flight" state and the channel opens only when released.
          await releaseFirst.future;
          final session = await client.execute(command);
          if (!firstOpened.isCompleted) firstOpened.complete(session);
          return session;
        }

        final executor = SshAiExecutor(open, openPrivilege: openPrivilege);
        addTearDown(executor.cancel);
        final seen = StringBuffer();
        Future<AiCommandResult> run(String command) =>
            executor.execute(command, seen.write);

        // Ordinary commands work before any authorization.
        final before = await run('id -u');
        expect(before.exitCode, 0, reason: before.output);
        expect(before.output.trim(), isNot('0'));
        expect(executor.elevated, isFalse);

        // The first authorization is held while its exec channel is still
        // unopened, so no suspended sudo process can hold the server-side
        // timestamp lock across the replacement authorization.
        final held = executor.elevate(env.sudoPassword);
        expect(firstOpened.isCompleted, isFalse);

        executor.revokePrivilege();
        await expectLater(
          held.timeout(const Duration(seconds: 10)),
          throwsA(isA<AiFailure>()),
        );
        expect(executor.elevated, isFalse);

        // Revoking an authorization must not cancel the executor: ordinary
        // commands still run, unprivileged, on a fresh channel.
        final afterRevoke = await run('id -u');
        expect(afterRevoke.exitCode, 0, reason: afterRevoke.output);
        expect(afterRevoke.output.trim(), isNot('0'));

        // The revoked attempt's cleanup must not block a new authorization.
        await executor
            .elevate(env.sudoPassword)
            .timeout(const Duration(seconds: 45));
        expect(executor.elevated, isTrue);
        final rooted = await run('id -u');
        expect(rooted.exitCode, 0, reason: rooted.output);
        expect(rooted.output.trim(), '0');

        // Release the stale opening after the new root channel is live: the
        // late session is opened and immediately closed by the executor
        // without being installed, replacing or invalidating the new root.
        releaseFirst.complete();
        final staleSession = await firstOpened.future.timeout(
          const Duration(seconds: 15),
        );
        await staleSession.done.timeout(const Duration(seconds: 15));
        expect(executor.elevated, isTrue);
        final stillRooted = await run('id -u');
        expect(stillRooted.output.trim(), '0');

        // Revoking an already-granted channel stays fail-closed: later
        // commands fail instead of silently dropping to the login user.
        executor.revokePrivilege();
        expect(executor.elevated, isFalse);
        await expectLater(run('id -u'), throwsA(isA<AiFailure>()));

        expect(seen.toString(), isNot(contains(env.sudoPassword)));
        expect(seen.toString(), isNot(contains(env.sshPassword)));
        expect(seen.toString(), isNot(contains('[harbor-ai-sudo-')));
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: _environment == null
          ? '设置 ${_SudoEnvironment.requiredVariables.join('、')} '
                '后可运行撤销在途提权的 sudo 测试'
          : null,
    );
  });
}
