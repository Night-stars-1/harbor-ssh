import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/local_files.dart';
import 'package:harbor_ssh/data/sftp_files.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

/// Permission bits as written in a shell, for example `mode('4755')`.
int mode(String octal) => int.parse(octal, radix: 8);

const _home = '/home/tester';
const _readme = '$_home/readme.txt';

void main() {
  // The local create path goes through `harbor/local_paths` before it falls
  // back to `dart:io`, which needs a binding to answer or refuse the call.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('本地创建边界', () {
    test('独占创建文件不覆盖同名项目，创建目录不接管已有名称', () async {
      final directory = await Directory.systemTemp.createTemp('harbor-create-');
      addTearDown(() => directory.delete(recursive: true));
      final files = LocalFiles(directory.path);

      final existing = File('${directory.path}/report.txt');
      await existing.writeAsString('keep');
      await expectLater(
        files.createFileExclusive(existing.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existing.readAsString(), 'keep');

      final folder = '${directory.path}/folder';
      await files.createDirectory(folder);
      expect(await Directory(folder).exists(), isTrue);
      await expectLater(
        files.createDirectory(folder),
        throwsA(isA<FileSystemException>()),
      );
      // A file in the way is refused just as clearly as a directory.
      await expectLater(
        files.createDirectory(existing.path),
        throwsA(isA<FileSystemException>()),
      );

      final fresh = '${directory.path}/fresh.txt';
      await files.createFileExclusive(fresh);
      expect(await File(fresh).length(), 0);
      await expectLater(
        files.createFileExclusive(fresh),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        files.createFileExclusive(folder),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('本地名称校验复用 childPath，越界名称在创建前被拒绝', () {
      final files = LocalFiles(Directory.systemTemp.path);
      for (final name in ['', '.', '..', 'a/b', 'a\x00b']) {
        expect(() => files.childPath(files.root, name), throwsFormatException);
      }
    });

    test('本地目录不具备权限能力，权限编辑只对 SFTP 提供', () {
      expect(
        LocalFiles(Directory.systemTemp.path),
        isNot(isA<RemoteFilePermissions>()),
      );
    });
  });

  test('SFTP 权限变更在建立通道前完成校验，非法值不会发出', () async {
    var opened = false;
    final files = SftpFiles(() {
      opened = true;
      throw StateError('不应建立通道');
    });
    for (final invalid in <Future<void> Function()>[
      () => files.setPermissions('/x'),
      () => files.setPermissions('/x', userId: 1000),
      () => files.setPermissions('/x', groupId: 1000),
      () => files.setPermissions('/x', mode: 0x1000),
      () => files.setPermissions('/x', mode: -1),
      () => files.setPermissions('/x', userId: -1, groupId: 0),
      () => files.setPermissions('/x', userId: 0, groupId: -1),
      // Above 32 bits the wire value is truncated into another owner.
      () => files.setPermissions('/x', userId: 0x100000000, groupId: 0),
      () => files.setPermissions('/x', userId: 0, groupId: 0x100000000),
    ]) {
      await expectLater(invalid(), throwsArgumentError);
    }
    expect(opened, isFalse);
    // 0 and 07777 are the accepted ends of the mode range, 0xffffffff the
    // accepted end of an owner id; all reach the channel, which is what the
    // failing opener below stands in for.
    for (final accepted in <Future<void> Function()>[
      () => files.setPermissions('/x', mode: 0),
      () => files.setPermissions('/x', mode: 0xfff),
      () => files.setPermissions('/x', userId: 0xffffffff, groupId: 0xffffffff),
    ]) {
      await expectLater(accepted(), throwsA(isA<StateError>()));
    }
    expect(opened, isTrue);
  });

  final enabled = Platform.environment['HARBOR_SSH_INTEGRATION'] == '1';
  group(
    '真实 loopback SFTP 权限与独占创建',
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

      /// Every connection owns an independent virtual tree, so a test may
      /// change permissions without leaking them into another test.
      Future<T> withClient<T>(Future<T> Function(SSHClient) action) async {
        final socket = await SSHSocket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(seconds: 15),
        );
        final client = SSHClient(
          socket,
          username: 'tester',
          identities: SSHKeyPair.fromPem(privateKey, 'fixture-passphrase'),
          onVerifyHostKey: (_, _) async => true,
        );
        await client.authenticated;
        try {
          return await action(client);
        } finally {
          unawaited(client.close().catchError((Object _) {}));
        }
      }

      Future<Uint8List> readFile(SftpClient sftp, String path) async {
        final file = await sftp.open(path);
        try {
          return await file.readBytes();
        } finally {
          await file.close();
        }
      }

      test('读取权限返回服务器上报的权限位与所有者', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final file = await files.readPermissions(_readme);
          expect(file.mode, mode('644'));
          expect(file.userId, 1000);
          expect(file.groupId, 1000);
          expect((await files.readPermissions(_home)).mode, mode('755'));
        });
      });

      test('权限位与特殊位写入后由独立读取确认', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final sftp = await client.sftp();
          for (final value in ['4755', '1777', '640', '0000']) {
            await files.setPermissions(_readme, mode: mode(value));
            expect((await files.readPermissions(_readme)).mode, mode(value));
            final attrs = await sftp.stat(_readme, followLink: false);
            expect(attrs.mode!.value & 0xfff, mode(value));
          }
          await sftp.close();
        });
      });

      test('成对 uid/gid 写入后由独立读取确认', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final sftp = await client.sftp();
          await files.setPermissions(_readme, userId: 1234, groupId: 5678);
          final attrs = await sftp.stat(_readme, followLink: false);
          expect(attrs.userID, 1234);
          expect(attrs.groupID, 5678);
          final permissions = await files.readPermissions(_readme);
          expect(permissions.userId, 1234);
          expect(permissions.groupId, 5678);
          await sftp.close();
        });
      });

      test('所有者与特殊位一起修改时两者都保留', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final sftp = await client.sftp();
          // The fixture chowns after a mode carried by the same request, and a
          // chown drops setuid/setgid, so the ownership has to land first.
          await files.setPermissions(
            _readme,
            mode: mode('4755'),
            userId: 1234,
            groupId: 5678,
          );
          final attrs = await sftp.stat(_readme, followLink: false);
          expect(attrs.mode!.value & 0xfff, mode('4755'));
          expect(attrs.userID, 1234);
          expect(attrs.groupID, 5678);
          final permissions = await files.readPermissions(_readme);
          expect(permissions.mode, mode('4755'));
          expect(permissions.userId, 1234);
          expect(permissions.groupId, 5678);
          await sftp.close();
        });
      });

      test('单值 uid/gid 被拒绝且远端所有者不变', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final sftp = await client.sftp();
          await expectLater(
            files.setPermissions(_readme, userId: 1234),
            throwsArgumentError,
          );
          await expectLater(
            files.setPermissions(_readme, groupId: 1234),
            throwsArgumentError,
          );
          final attrs = await sftp.stat(_readme, followLink: false);
          expect(attrs.userID, 1000);
          expect(attrs.groupID, 1000);
          await sftp.close();
        });
      });

      test('符号链接的权限不被修改，链接目标也不受影响', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final sftp = await client.sftp();
          await expectLater(
            files.setPermissions('$_home/linkdir', mode: mode('700')),
            throwsA(isA<StateError>()),
          );
          expect(
            (await sftp.stat('$_home/linkdir', followLink: false)).mode!.value &
                0xfff,
            mode('777'),
          );
          expect(
            (await sftp.stat('$_home/docs', followLink: false)).mode!.value &
                0xfff,
            mode('755'),
          );
          expect(
            (await files.readPermissions('$_home/linkdir')).mode,
            mode('777'),
          );
          await sftp.close();
        });
      });

      test('独占创建不覆盖已有文件，同名目录创建失败', () async {
        await withClient((client) async {
          final files = SftpFiles(() => client.sftp());
          final sftp = await client.sftp();
          final before = await readFile(sftp, _readme);
          await expectLater(
            files.createFileExclusive(_readme),
            throwsA(isA<SftpStatusError>()),
          );
          expect(await readFile(sftp, _readme), before);
          await expectLater(
            files.createDirectory(_home),
            throwsA(isA<SftpStatusError>()),
          );

          final fresh = '$_home/fresh.txt';
          await files.createFileExclusive(fresh);
          expect(await readFile(sftp, fresh), isEmpty);
          await expectLater(
            files.createFileExclusive(fresh),
            throwsA(isA<SftpStatusError>()),
          );
          await sftp.close();
        });
      });
    },
    skip: !enabled
        ? '设置 HARBOR_SSH_INTEGRATION=1 运行；依赖 tool/requirements-test.txt'
        : false,
  );
}
