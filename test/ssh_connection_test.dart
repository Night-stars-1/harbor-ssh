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

import 'support.dart';

void main() {
  final enabled = Platform.environment['HARBOR_SSH_INTEGRATION'] == '1';
  group(
    '真实 loopback SSH 协议',
    () {
      late Process fixture;
      late int port;
      late String privateKey;
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
        username: 'tester',
        authMethod: method,
      );
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
          List.generate(180000, (index) => index % 251),
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
        await files.download(
          path,
          (bytes) async {
            received.add(bytes);
          },
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        expect(received.takeBytes(), payload);
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
      for (final method in AuthMethod.values) {
        test('测试连接只验证身份，不打开终端 ${method.name}', () async {
          final connection = SshConnection(
            id: 'probe',
            host: host(method: method),
          );
          addTearDown(connection.dispose);
          final repository = memoryRepository();
          await connection.connect(
            method == AuthMethod.password
                ? const Credentials(password: 'fixture-password')
                : Credentials(
                    privateKey: privateKey,
                    passphrase: 'fixture-passphrase',
                  ),
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
