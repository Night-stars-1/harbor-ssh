import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/remote_text_editor.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/data/remote_metrics.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/remote_file.dart';
import 'package:harbor_ssh/data/file_copy.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';

import 'support.dart';

void main() {
  final enabled = Platform.environment['HARBOR_SSH_INTEGRATION'] == '1';
  group(
    '真实 loopback SSH 协议',
    () {
      late Process fixture;
      late int port;
      late String privateKey;
      late String publicKey;
      setUpAll(() async {
        fixture = await Process.start('python', ['tool/ssh_fixture.py']);
        final output = fixture.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        final ready = Completer<Map<String, dynamic>>();
        output.listen((line) {
          if (!ready.isCompleted) {
            ready.complete(jsonDecode(line) as Map<String, dynamic>);
          }
        });
        fixture.stderr.transform(utf8.decoder).listen((line) {
          if (!ready.isCompleted) ready.completeError(StateError(line));
        });
        final config = await ready.future.timeout(const Duration(seconds: 20));
        port = config['port'] as int;
        privateKey = config['privateKey'] as String;
        publicKey = config['publicKey'] as String;
      });
      tearDownAll(() async {
        fixture.kill();
        await fixture.exitCode;
      });
      Host host({AuthMethod method = AuthMethod.password}) => Host(
        id: 'fixture',
        name: 'Fixture',
        address: '127.0.0.1',
        port: port,
        username: method == AuthMethod.none ? 'cnb-fixture-token' : 'tester',
        authMethod: method,
      );
      test('保存两级中转，独立认证和指纹，终端与 SFTP 工作并可重连', () async {
        Future<(Process, int)> gateway() async {
          final process = await Process.start(
            'python',
            ['tool/port_forward_fixture.py'],
            environment: {
              'HARBOR_FIXTURE_PUBLIC_KEY': publicKey,
              'PYTHONUTF8': '1',
            },
          );
          addTearDown(() async {
            process.kill();
            await process.exitCode;
          });
          final ready = Completer<int>();
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                if (!ready.isCompleted) {
                  ready.complete((jsonDecode(line) as Map)['port'] as int);
                }
              });
          process.stderr.transform(utf8.decoder).listen((line) {
            if (!ready.isCompleted) ready.completeError(StateError(line));
          });
          return (
            process,
            await ready.future.timeout(const Duration(seconds: 20)),
          );
        }

        final outerProcess = await gateway();
        final innerProcess = await gateway();
        final outer = Host(
          id: 'outer',
          name: '公网堡垒机',
          address: '127.0.0.1',
          port: outerProcess.$2,
          username: 'tester',
        );
        final inner = Host(
          id: 'inner',
          name: '内网堡垒机',
          address: 'jump-fixture.invalid',
          port: innerProcess.$2,
          username: 'tester',
          authMethod: AuthMethod.privateKey,
          userId: 'gateway-key',
          jumpHostId: outer.id,
        );
        final target = Host(
          id: 'target',
          name: '目标服务器',
          address: 'jump-fixture.invalid',
          port: port,
          username: 'cnb-fixture-token',
          authMethod: AuthMethod.none,
          jumpHostId: inner.id,
        );
        final repository = memoryRepository();
        await repository.saveHosts([outer, inner, target]);
        await repository.saveCredentials(
          outer.id,
          const Credentials(password: 'fixture-password'),
        );
        await repository.saveUserCredentials(
          'gateway-key',
          Credentials(privateKey: privateKey, passphrase: 'fixture-passphrase'),
        );
        final saved = (await repository.loadHosts()).last;
        expect(saved.jumpHostId, inner.id);
        expect(saved.withFavorite(true).jumpHostId, inner.id);
        final trusted = <String>[];
        final fingerprints = <String>[];
        final connection = SshConnection(id: 'jump-session', host: saved);
        addTearDown(connection.dispose);
        await connection.connect(
          (await repository.loginCredentials(saved))!,
          repository,
          (_, fingerprint) async {
            trusted.add(target.id);
            fingerprints.add(fingerprint);
            return true;
          },
          trustJumpHost: (hop, _, fingerprint) async {
            trusted.add(hop.id);
            fingerprints.add(fingerprint);
            return true;
          },
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        expect(trusted, [outer.id, inner.id, target.id]);
        expect(fingerprints.toSet(), hasLength(3));
        connection.send('jump-session\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=jump-session',
          ),
        );
        final listing = await connection.files.browse('~');
        final path = '${listing.path}/jump-transfer.txt';
        final content = Uint8List.fromList(utf8.encode('中转 SFTP transfer'));
        await connection.files.upload(
          path,
          Stream.value(content),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        final received = <int>[];
        await connection.files.download(
          path,
          (bytes) async => received.addAll(bytes),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        expect(received, content);
        connection.send('exit\r');
        await eventually(() => connection.status == ConnectionStatus.closed);
        await connection.reconnect(
          const Credentials(),
          repository,
          (_, _) async => fail('目标指纹已保存，不应重复确认'),
          trustJumpHost: (_, _, _) async => fail('中转指纹已保存，不应重复确认'),
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        connection.send('jump-reconnected\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=jump-reconnected',
          ),
        );
        expect((await connection.files.browse('~')).entries, isNotEmpty);

        // A changed gateway key must be confirmed against that gateway, not
        // against the target. Rejecting it must stop the whole route.
        connection.close();
        await repository.forgetHostKey(outer);
        await repository.verifyHost(
          outer,
          'ssh-rsa',
          'changed-key',
          (_, _) async => true,
        );
        Host? changedHop;
        await connection.reconnect(
          const Credentials(),
          repository,
          (_, _) async => fail('拒绝中转指纹后不应连接目标'),
          confirmJumpHostKeyChange: (hop, _, _, previous) async {
            changedHop = hop;
            expect(previous, 'ssh-rsa changed-key');
            return false;
          },
        );
        expect(changedHop?.id, outer.id);
        expect(connection.status, ConnectionStatus.failed);
        expect(connection.error, contains(outer.name));

        await repository.saveUserCredentials('gateway-key', null);
        await connection.reconnect(
          const Credentials(),
          repository,
          (_, _) async => fail('缺少中转凭证时不应连接目标'),
          trustJumpHost: (_, _, _) async => fail('缺少中转凭证时不应开始认证'),
        );
        expect(connection.status, ConnectionStatus.failed);
        expect(connection.error, contains('缺少登录凭证'));
        expect(connection.error, contains(inner.name));
        await repository.saveUserCredentials(
          'gateway-key',
          Credentials(privateKey: privateKey, passphrase: 'fixture-passphrase'),
        );

        // Restoring trust and retrying preserves the same terminal session.
        await repository.forgetHostKey(outer);
        await connection.reconnect(
          const Credentials(),
          repository,
          (_, _) async => true,
          trustJumpHost: (_, _, _) async => true,
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        outerProcess.$1.kill();
        await outerProcess.$1.exitCode;
        await eventually(() => connection.status != ConnectionStatus.connected);

        // Invalid routes fail before any dial and never fall back to direct.
        for (final configuration in [
          [target],
          [
            Host(
              id: inner.id,
              name: inner.name,
              address: inner.address,
              port: inner.port,
              username: inner.username,
              jumpHostId: target.id,
            ),
            target,
          ],
        ]) {
          await repository.saveHosts(configuration);
          await connection.reconnect(
            const Credentials(),
            repository,
            (_, _) async => fail('无效中转配置不应产生指纹请求'),
          );
          expect(connection.status, ConnectionStatus.failed);
          expect(connection.error, contains('中转主机'));
        }
      });
      test('免密码认证可打开终端和 SFTP，拒绝不允许免密码的账户', () async {
        final connection = SshConnection(
          id: 'no-password',
          host: host(method: AuthMethod.none),
        );
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        expect((await connection.files.browse('~')).entries, isNotEmpty);
        connection.send('no-password-session\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=no-password-session',
          ),
        );

        final rejected = SshConnection(
          id: 'password-required',
          host: Host(
            id: 'rejected',
            name: 'Password required',
            address: '127.0.0.1',
            port: port,
            username: 'tester',
            authMethod: AuthMethod.none,
          ),
        );
        addTearDown(rejected.dispose);
        await rejected.connect(
          const Credentials(),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(rejected.status, ConnectionStatus.failed);
      });

      test('密码认证、UTF-8 输出、键盘输入、窗口缩放和远程退出', () async {
        final connection = SshConnection(id: '1', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        connection.send('hello\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains('ECHO=hello'),
        );
        connection.terminal.resize(100, 35);
        connection.send('size\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains('SIZE=100x35'),
        );
        connection.send('\x03');
        await eventually(
          () => connection.terminal.buffer.getText().contains('interrupted'),
        );
        connection.send('exit\r');
        await eventually(() => connection.status == ConnectionStatus.closed);
        expect(connection.terminal.buffer.getText(), contains('FINAL-OUTPUT'));
      });
      test('远程退出后原会话重连，保留终端与历史并恢复输入和 SFTP', () async {
        final connection = SshConnection(id: 'same-session', host: host());
        addTearDown(connection.dispose);
        final repository = memoryRepository();
        const credentials = Credentials(password: 'fixture-password');
        await connection.connect(credentials, repository, (_, _) async => true);
        final terminal = connection.terminal;
        final history = connection.commandHistory;
        history.add('preserved-command');
        await connection.listDirectory('~');
        connection.send('before-reconnect\r');
        await eventually(
          () => terminal.buffer.getText().contains('ECHO=before-reconnect'),
        );
        connection.send('exit\r');
        await eventually(() => connection.status == ConnectionStatus.closed);
        final before = terminal.buffer.getText();
        final statuses = <ConnectionStatus>[];
        connection.addListener(() => statuses.add(connection.status));
        await connection.reconnect(
          credentials,
          repository,
          (_, _) async => true,
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        expect(connection.id, 'same-session');
        expect(connection.terminal, same(terminal));
        expect(connection.commandHistory, same(history));
        expect(history.matching('preserved'), contains('preserved-command'));
        expect(terminal.buffer.getText(), contains(before));
        expect(statuses, [
          ConnectionStatus.connecting,
          ConnectionStatus.connected,
        ]);
        connection.send('after-reconnect\r');
        await eventually(
          () => terminal.buffer.getText().contains('ECHO=after-reconnect'),
        );
        expect(await connection.listDirectory('~'), isNotEmpty);
        final callback = terminal.onOutput;
        await connection.reconnect(
          credentials,
          repository,
          (_, _) async => true,
        );
        expect(terminal.onOutput, same(callback));
        connection.send('exit\r');
        await eventually(() => connection.status == ConnectionStatus.closed);
      });

      test('重连失败仍可再次重试，清除上次错误', () async {
        final connection = SshConnection(id: 'retry-failure', host: host());
        addTearDown(connection.dispose);
        final repository = memoryRepository();
        await connection.connect(
          const Credentials(password: 'wrong'),
          repository,
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.failed);
        expect(connection.error, isNotNull);
        await connection.reconnect(
          const Credentials(password: 'wrong'),
          repository,
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.failed);
        await connection.reconnect(
          const Credentials(password: 'fixture-password'),
          repository,
          (_, _) async => true,
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
        expect(connection.error, isNull);
        connection.send('retry-success\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=retry-success',
          ),
        );
      });

      test('取消旧重连后再次连接，迟到的指纹确认不会关闭新连接', () async {
        final connection = SshConnection(id: 'stale-reconnect', host: host());
        addTearDown(connection.dispose);
        connection.close();
        final opened = Completer<void>();
        final decision = Completer<bool>();
        const credentials = Credentials(password: 'fixture-password');
        final previous = connection.reconnect(credentials, memoryRepository(), (
          _,
          _,
        ) {
          opened.complete();
          return decision.future;
        });
        await opened.future.timeout(const Duration(seconds: 10));
        connection.close();
        await connection.reconnect(
          credentials,
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        decision.complete(true);
        await previous;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(connection.status, ConnectionStatus.connected);
        connection.send('new-transport\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=new-transport',
          ),
        );
        connection.close();
        final closing = connection.reconnect(
          credentials,
          memoryRepository(),
          (_, _) async => true,
        );
        connection.close();
        await closing;
        expect(connection.status, ConnectionStatus.closed);
      });

      test('已加密私钥认证', () async {
        final connection = SshConnection(
          id: '2',
          host: host(method: AuthMethod.privateKey),
        );
        addTearDown(connection.dispose);
        await connection.connect(
          Credentials(privateKey: privateKey, passphrase: 'fixture-passphrase'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(
          connection.status,
          ConnectionStatus.connected,
          reason: connection.error,
        );
      });
      test('AI 独立执行通道返回输出与退出码，取消不关闭交互终端', () async {
        final connection = SshConnection(id: 'ai-exec', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        final before = connection.terminal.buffer.getText();
        final executor = connection.createAiExecutor();
        final chunks = StringBuffer();
        final result = await executor.execute(
          'harbor-ai-fixture-success',
          chunks.write,
        );
        expect(result.exitCode, 0);
        expect(result.output, contains('AI 测试输出'));
        expect(chunks.toString(), result.output);
        final failed = await executor.execute('harbor-ai-fixture-fail', (_) {});
        expect(failed.exitCode, 7);
        expect(failed.output, contains('fixture error'));
        final large = await executor.execute('harbor-ai-fixture-large', (_) {});
        expect(large.truncated, isTrue);
        expect(large.output.length, 16000);
        final started = Completer<void>();
        final pending = executor.execute('harbor-ai-fixture-wait', (_) {
          if (!started.isCompleted) started.complete();
        });
        final stopped = expectLater(pending, throwsA(isA<AiFailure>()));
        await started.future.timeout(const Duration(seconds: 5));
        executor.cancel();
        await stopped;
        expect(connection.status, ConnectionStatus.connected);
        expect(connection.terminal.buffer.getText(), before);
        connection.send('after-ai\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains('ECHO=after-ai'),
        );
      });
      test('AI 完整流程：静默命令超过一分钟仍继续，停止后可再执行且终端可用', () async {
        final connection = SshConnection(id: 'ai-slow-task', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        final terminalBefore = connection.terminal.buffer.getText();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requests = <Map<String, dynamic>>[];
        // Local protocol responses stand in for the model; the HTTP client,
        // task loop and SSH command channels are the production implementations.
        server.listen((request) async {
          final body = jsonDecode(
            await utf8.decoder.bind(request).join(),
          ) as Map<String, dynamic>;
          requests.add(body);
          expect(body['stream'], isTrue);
          final tools = body['tools'] as List;
          expect(
            tools.first['function']['description'],
            isNot(contains('最长 60 秒')),
          );
          final command = switch (requests.length) {
            1 => 'harbor-ai-fixture-slow',
            2 || 5 => 'harbor-ai-fixture-success',
            4 => 'harbor-ai-fixture-wait',
            _ => null,
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': command == null ? '流程完成' : null,
                    if (command != null)
                      'tool_calls': [
                        {
                          'id': 'step-${requests.length}',
                          'type': 'function',
                          'function': {
                            'name': 'run_command',
                            'arguments': jsonEncode({
                              'command': command,
                              'reason': '验证完整执行流程',
                              'requires_approval': false,
                            }),
                          },
                        },
                      ],
                  },
                },
              ],
            }),
          );
          await request.response.close();
        });
        final task = AiTaskController(
          settings: () => AiSettings(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'loopback-model',
          ),
          executorFactory: connection.createAiExecutor,
          connected: () => connection.status == ConnectionStatus.connected,
        );
        addTearDown(task.dispose);
        final elapsed = Stopwatch()..start();
        await task.start('执行慢命令，再检查结果');
        expect(elapsed.elapsed, greaterThan(const Duration(seconds: 60)));
        expect(task.failure, isNull);
        expect(task.status, '已完成');
        expect(requests, hasLength(3));
        final slowResult = jsonDecode(
          (requests[1]['messages'] as List).singleWhere(
                (message) => message['role'] == 'tool',
              )['content']
              as String,
        ) as Map;
        expect(slowResult['exitCode'], 0);
        expect(slowResult['output'], contains('慢命令完成'));
        final commands = task.entries.where((entry) => entry.command).toList();
        expect(commands, hasLength(2));
        expect(commands.every((entry) => entry.finished), isTrue);
        expect(task.entries.last.text, '流程完成');

        final waiting = task.start('执行一个等待中的命令');
        await eventually(
          () =>
              task.entries.last.command &&
              task.entries.last.output.contains('AI 测试输出'),
        );
        task.stop();
        await waiting.timeout(const Duration(seconds: 5));
        expect(task.running, isFalse);
        expect(requests, hasLength(4));
        expect(connection.status, ConnectionStatus.connected);
        expect(connection.terminal.buffer.getText(), terminalBefore);
        await task.start('停止后重新检查');
        expect(task.failure, isNull);
        expect(task.status, '已完成');
        expect(requests, hasLength(6));
        connection.send('after-slow-ai\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=after-slow-ai',
          ),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));
      test('远端状态经独立 exec 通道采样，交互终端不收到监控命令', () async {
        final connection = SshConnection(id: 'metrics-exec', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        final before = connection.terminal.buffer.getText();
        final first = await connection.readRemoteMetrics();
        final second = await connection.readRemoteMetrics();
        expect(first, isNotNull);
        expect(second, isNotNull);
        final metrics = RemoteHostMetrics.fromSamples(second!, first);
        expect(metrics.cpuPercent, greaterThan(0));
        expect(metrics.memoryPercent, greaterThan(0));
        expect(metrics.diskPercent, closeTo(40, 0.01));
        expect(metrics.downloadBytesPerSecond, closeTo(100000, 0.01));
        expect(metrics.uploadBytesPerSecond, closeTo(50000, 0.01));
        expect(metrics.cpuCores.map((core) => core.id), ['cpu0', 'cpu1']);
        expect(metrics.cpuCores.first.percent, closeTo(75 / 85 * 100, 0.01));
        expect(metrics.cpuCores.last.percent, closeTo(35 / 85 * 100, 0.01));
        expect(metrics.processesAvailable, isTrue);
        expect(metrics.processes.first.pid, 123);
        expect(metrics.processes.first.residentBytes, 65536 * 1024);
        expect(metrics.processes.last.name, 'node worker');
        expect(metrics.disksAvailable, isTrue);
        expect(metrics.disks.map((disk) => disk.mountPoint), [
          '/data volume',
          '/',
        ]);
        expect(metrics.disks.first.totalBytes, 20480000 * 1024);
        expect(metrics.disks.first.availableBytes, 9216000 * 1024);
        expect(connection.terminal.buffer.getText(), before);
        connection.send('still-interactive\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=still-interactive',
          ),
        );
        connection.close();
        expect(await connection.readRemoteMetrics(), isNull);
      });
      test('SFTP 读取远端目录与目录软链接，不污染交互终端', () async {
        final connection = SshConnection(id: 'completion-sftp', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        final before = connection.terminal.buffer.getText();
        final entries = await connection.listDirectory('~');
        expect(entries.map((entry) => entry.name).toSet(), {
          'docs',
          'my dir',
          'readme.txt',
          'linkdir',
        });
        expect(
          entries
              .where((entry) => entry.isDirectory)
              .map((entry) => entry.name)
              .toSet(),
          {'docs', 'my dir', 'linkdir'},
        );
        expect(await connection.listDirectory('~/missing'), isEmpty);
        await connection.loadCommandHistory();
        expect(connection.commandHistory.matching('git'), [
          'git log',
          'git status',
        ]);
        expect(connection.commandHistory.matching('docker'), ['docker ps']);
        expect(await connection.listAvailableCommands(), [
          'cd',
          'docker',
          'docker-compose',
          'git',
        ]);
        expect(await connection.listAvailableCommands(), [
          'cd',
          'docker',
          'docker-compose',
          'git',
        ]);
        expect(connection.status, ConnectionStatus.connected);
        expect(connection.terminal.buffer.getText(), before);
        connection.send('catalog-count\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains('CATALOGS=1'),
        );
        connection.send('still-connected\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=still-connected',
          ),
        );
      });
      test('SFTP 文件上传下载、同名保护、取消清理及终端隔离', () async {
        final connection = SshConnection(id: 'transfer-sftp', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        final before = connection.terminal.buffer.getText();
        final files = connection.files;
        final listing = await files.browse('~');
        expect(listing.path, '/home/tester');
        expect(listing.entries.first.isDirectory, isTrue);
        expect(
          listing.entries
              .firstWhere((entry) => entry.name == 'linkdir')
              .isDirectory,
          isTrue,
        );
        await expectLater(files.browse('/missing'), throwsA(anything));
        final payload = Uint8List.fromList(
          List.generate(3 * 1024 * 1024 + 123, (index) => index % 251),
        );
        var progress = 0;
        final path = '${listing.path}/传输 test.bin';
        await files.upload(
          path,
          Stream.fromIterable([
            Uint8List.sublistView(payload, 0, 90000),
            Uint8List.sublistView(payload, 90000),
          ]),
          cancellation: TransferCancellation(),
          onProgress: (bytes) => progress = bytes,
        );
        expect(progress, payload.length);
        await expectLater(
          files.upload(
            path,
            Stream.value(Uint8List.fromList([99])),
            cancellation: TransferCancellation(),
            onProgress: (_) {},
          ),
          throwsA(anything),
        );
        final received = BytesBuilder();
        var downloadWrites = 0;
        await files.download(
          path,
          (bytes) async {
            downloadWrites++;
            expect(bytes.length, lessThanOrEqualTo(256 * 1024));
            received.add(bytes);
          },
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        expect(received.takeBytes(), payload);
        expect(downloadWrites, 13);
        final downloadCancellation = TransferCancellation();
        var cancelledBytes = 0;
        await expectLater(
          files.download(
            path,
            (bytes) async => cancelledBytes += bytes.length,
            cancellation: downloadCancellation,
            onProgress: (_) => downloadCancellation.cancel(),
          ),
          throwsA(isA<TransferCancelled>()),
        );
        expect(cancelledBytes, 256 * 1024);
        expect(connection.status, ConnectionStatus.connected);
        final cancellation = TransferCancellation();
        await expectLater(
          files.upload(
            '${listing.path}/cancelled',
            Stream.fromIterable([Uint8List(8), Uint8List(8)]),
            cancellation: cancellation,
            onProgress: (_) => cancellation.cancel(),
          ),
          throwsA(isA<TransferCancelled>()),
        );
        await expectLater(
          files.upload(
            '${listing.path}/write-fail',
            Stream.value(Uint8List(8)),
            cancellation: TransferCancellation(),
            onProgress: (_) {},
          ),
          throwsA(anything),
        );
        final after = await files.browse('~');
        expect(
          after.entries.any(
            (entry) => entry.name == 'cancelled' || entry.name == 'write-fail',
          ),
          isFalse,
        );
        await files.upload(
          '${listing.path}/empty',
          const Stream.empty(),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        var emptyBytes = 0;
        await files.download(
          '${listing.path}/empty',
          (bytes) async {
            emptyBytes += bytes.length;
          },
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        expect(emptyBytes, 0);
        final sourceFolder = '${listing.path}/source-folder';
        await files.createDirectory(sourceFolder);
        await files.createDirectory('$sourceFolder/sub');
        await files.createDirectory('$sourceFolder/empty-dir');
        await files.upload(
          '$sourceFolder/root.txt',
          Stream.value(Uint8List.fromList([1, 2, 3])),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        await files.upload(
          '$sourceFolder/sub/nested.txt',
          Stream.value(Uint8List.fromList([4, 5])),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        DirectoryCopyResult? prepared;
        final copiedFolder = '${listing.path}/copied-folder';
        await copyDirectoryBetween(
          source: files,
          destination: files,
          sourcePath: sourceFolder,
          destinationPath: copiedFolder,
          cancellation: TransferCancellation(),
          onPrepared: (value) => prepared = value,
          onProgress: (_) {},
        );
        expect(prepared?.files, 2);
        expect(prepared?.directories, 3);
        expect(
          (await files.browse(copiedFolder)).entries.map((entry) => entry.name),
          containsAll(['sub', 'empty-dir', 'root.txt']),
        );
        expect(
          (await files.browse('$copiedFolder/sub')).entries.single.name,
          'nested.txt',
        );
        await expectLater(
          files.deleteDirectory(copiedFolder),
          throwsA(anything),
        );
        await files.deleteDirectory(copiedFolder, recursive: true);
        await files.deleteDirectory(sourceFolder, recursive: true);
        await files.deleteFile(path);
        await files.deleteFile('${listing.path}/empty');
        final afterDelete = await files.browse('~');
        expect(
          afterDelete.entries.any(
            (entry) => entry.path == path || entry.name == 'empty',
          ),
          isFalse,
        );
        await expectLater(files.deleteFile(path), throwsA(anything));
        await expectLater(
          files.deleteFile('${listing.path}/documents'),
          throwsA(anything),
        );
        expect(connection.terminal.buffer.getText(), before);
        connection.send('after-transfer\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=after-transfer',
          ),
        );
      });
      test('SFTP 文本编辑保留原件直至新内容发布', () async {
        final connection = SshConnection(id: 'edit-sftp', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
          openShell: false,
        );
        expect(connection.status, ConnectionStatus.connected);
        final files = connection.files;
        final directory = await files.browse('~');
        final path = files.childPath(directory.path, 'edit-测试.txt');
        await files.upload(
          path,
          Stream.value(Uint8List.fromList(utf8.encode('第一版\n'))),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        addTearDown(() => files.deleteFile(path));
        final entry = (await files.browse(directory.path)).entries
            .singleWhere((item) => item.path == path);
        final editor = RemoteTextEditor(files);
        final original = await editor.load(entry);
        expect(original, '第一版\n');
        await editor.save(entry, original, '第二版\n新的一行');
        expect(await editor.load(entry), '第二版\n新的一行');
        expect(
          (await files.browse(directory.path)).entries
              .where((item) => item.name.startsWith('.harbor-')),
          isEmpty,
        );
      });
      test('独立 SFTP 连接无需打开终端，两个远端标签可流式复制', () async {
        final connection = SshConnection(id: 'file-only', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
          openShell: false,
        );
        expect(connection.status, ConnectionStatus.connected);
        final files = connection.files;
        final directory = await files.browse('~');
        final source = directory.entries.firstWhere(
          (entry) => entry.name == 'readme.txt',
        );
        final destination = '${directory.path}/copied.txt';
        await copyFileBetween(
          source: connection.files,
          destination: connection.files,
          sourcePath: source.path,
          destinationPath: destination,
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        final bytes = BytesBuilder();
        await files.download(
          destination,
          (chunk) async {
            bytes.add(chunk);
          },
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        expect(utf8.decode(bytes.takeBytes()), 'Hello SFTP\n');
        expect(connection.terminal.buffer.getText().trim(), isEmpty);
      });
      test('公钥安装使用独立 SFTP 通道，不干扰交互终端', () async {
        final connection = SshConnection(id: 'install-live', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(connection.status, ConnectionStatus.connected);
        await eventually(
          () => connection.terminal.buffer.getText().contains('测试 connected'),
        );
        final before = connection.terminal.buffer.getText();
        expect(await connection.installPublicKey(publicKey), isTrue);
        expect(connection.terminal.buffer.getText(), before);
        connection.send('after-key-install\r');
        await eventually(
          () => connection.terminal.buffer.getText().contains(
            'ECHO=after-key-install',
          ),
        );
      });
      for (final method in AuthMethod.values) {
        test('测试连接只验证身份，不打开终端 ${method.name}', () async {
          final connection = SshConnection(
            id: 'probe',
            host: host(method: method),
          );
          addTearDown(connection.dispose);
          final repository = memoryRepository();
          await connection.connect(
            switch (method) {
              AuthMethod.password => const Credentials(
                password: 'fixture-password',
              ),
              AuthMethod.privateKey => Credentials(
                privateKey: privateKey,
                passphrase: 'fixture-passphrase',
              ),
              AuthMethod.none => const Credentials(),
            },
            repository,
            (_, _) async => true,
            openShell: false,
          );
          expect(
            connection.status,
            ConnectionStatus.connected,
            reason: connection.error,
          );
          expect(connection.terminal.onOutput, isNull);
          expect(connection.terminal.buffer.getText().trim(), isEmpty);
          expect(await repository.loadHosts(), isEmpty);
          connection.close();
          expect(connection.status, ConnectionStatus.closed);
        });
      }
      test('测试连接拒绝错误密码', () async {
        final connection = SshConnection(id: 'probe-invalid', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'wrong'),
          memoryRepository(),
          (_, _) async => true,
          openShell: false,
        );
        expect(connection.status, ConnectionStatus.failed);
        expect(connection.terminal.onOutput, isNull);
      });
      test('拒绝未知指纹与错误密码均无法打开终端', () async {
        final rejected = SshConnection(id: '3', host: host());
        addTearDown(rejected.dispose);
        await rejected.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => false,
        );
        expect(rejected.status, ConnectionStatus.failed);
        final wrongPassword = SshConnection(id: '4', host: host());
        addTearDown(wrongPassword.dispose);
        await wrongPassword.connect(
          const Credentials(password: 'wrong'),
          memoryRepository(),
          (_, _) async => true,
        );
        expect(wrongPassword.status, ConnectionStatus.failed);
      });
      test('已保存指纹不匹配时拒绝连接并保留原指纹', () async {
        final repository = memoryRepository();
        final target = host();
        await repository.verifyHost(
          target,
          'ssh-rsa',
          'SHA256:wrong',
          (_, _) async => true,
        );
        final connection = SshConnection(id: '5', host: target);
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          repository,
          (_, _) async => fail('必须不弹信任提示'),
        );
        expect(connection.status, ConnectionStatus.failed);
        expect(connection.error, contains('指纹已改变'));
      });
      for (final openShell in [false, true]) {
        for (final accept in [false, true]) {
          test(
            '指纹冲突${accept ? '确认后更新并继续' : '取消后保留并阻止'}连接 (shell=$openShell)',
            () async {
              final repository = memoryRepository();
              final target = host();
              await repository.verifyHost(
                target,
                'ssh-rsa',
                'SHA256:old',
                (_, _) async => true,
              );
              final connection = SshConnection(id: 'conflict', host: target);
              addTearDown(connection.dispose);
              String? presented;
              var confirmations = 0;
              await connection.connect(
                const Credentials(password: 'fixture-password'),
                repository,
                (_, _) async => fail('冲突必须显示单独的确认提示'),
                openShell: openShell,
                confirmKeyChange: (type, fingerprint, previousKey) async {
                  confirmations++;
                  expect(previousKey, 'ssh-rsa SHA256:old');
                  expect(connection.status, ConnectionStatus.connecting);
                  expect(
                    connection.terminal.buffer.getText(),
                    isNot(contains('connected')),
                  );
                  presented = '$type $fingerprint';
                  return accept;
                },
              );
              expect(confirmations, 1);
              expect(
                connection.status,
                accept ? ConnectionStatus.connected : ConnectionStatus.failed,
                reason: connection.error,
              );
              expect((repository.secrets as MemoryStore).values.values, [
                accept ? presented : 'ssh-rsa SHA256:old',
              ]);
              if (accept) {
                final second = SshConnection(id: 'trusted-again', host: target);
                addTearDown(second.dispose);
                await second.connect(
                  const Credentials(password: 'fixture-password'),
                  repository,
                  (_, _) async => fail('已信任指纹不应再次提示'),
                  openShell: false,
                  confirmKeyChange: (_, _, _) async => fail('已信任指纹不应再次提示'),
                );
                expect(
                  second.status,
                  ConnectionStatus.connected,
                  reason: second.error,
                );
              } else {
                expect(connection.error, contains('指纹已改变'));
              }
            },
          );
        }
      }
      test('冲突弹窗等待期间关闭连接，迟到确认不更新指纹', () async {
        final repository = memoryRepository();
        final target = host();
        await repository.verifyHost(
          target,
          'ssh-rsa',
          'SHA256:old',
          (_, _) async => true,
        );
        final connection = SshConnection(id: 'closed-conflict', host: target);
        addTearDown(connection.dispose);
        final opened = Completer<void>();
        final decision = Completer<bool>();
        final attempt = connection.connect(
          const Credentials(password: 'fixture-password'),
          repository,
          (_, _) async => fail('冲突不应显示首次信任提示'),
          confirmKeyChange: (_, _, _) {
            opened.complete();
            return decision.future;
          },
        );
        await opened.future.timeout(const Duration(seconds: 10));
        connection.close();
        decision.complete(true);
        await attempt;
        expect(connection.status, ConnectionStatus.closed);
        expect((repository.secrets as MemoryStore).values.values, [
          'ssh-rsa SHA256:old',
        ]);
      });
      test('连接过程中关闭，不产生迟到会话', () async {
        final connection = SshConnection(id: '6', host: host());
        addTearDown(connection.dispose);
        final attempt = connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
        );
        connection.close();
        await attempt;
        expect(connection.status, ConnectionStatus.closed);
      });
    },
    skip: !enabled
        ? '设置 HARBOR_SSH_INTEGRATION=1 运行；依赖 tool/requirements-test.txt'
        : false,
  );
}

Future<void> eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('等待 SSH 状态或输出超时');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
