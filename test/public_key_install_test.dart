import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/public_key_install.dart';
import 'package:harbor_ssh/data/sftp_files.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/data/ssh_keys.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

import 'support.dart';

/// Permission bits as written in a shell, for example `mode('700')`.
int mode(String octal) => int.parse(octal, radix: 8);

const _home = '/home/tester';
const _sshDirectory = '$_home/.ssh';
const _authorizedKeys = '$_sshDirectory/authorized_keys';

void main() {
  final newKey = generateEd25519Key(comment: 'harbor-new');
  final otherKey = generateEd25519Key(comment: 'harbor-other');
  final parsed = parseOpenSshPublicKey(newKey.publicOpenSsh);

  group('公钥文本校验', () {
    test('接受生成的 Ed25519 公钥并去掉首尾空白', () {
      expect(
        validatedOpenSshPublicKey('  ${newKey.publicOpenSsh}\n'),
        newKey.publicOpenSsh,
      );
      expect(parsed.type, 'ssh-ed25519');
      expect(base64.decode(parsed.blob), isNotEmpty);
    });

    test('接受没有注释的公钥', () {
      final line = '${parsed.type} ${parsed.blob}';
      expect(parseOpenSshPublicKey(line).line, line);
    });

    test('接受以 CRLF 结尾的单行公钥', () {
      expect(
        validatedOpenSshPublicKey('${newKey.publicOpenSsh}\r\n'),
        newKey.publicOpenSsh,
      );
    });

    test('压缩多余空格并保留注释', () {
      expect(
        parseOpenSshPublicKey('${parsed.type}   ${parsed.blob}  我的 密钥').line,
        '${parsed.type} ${parsed.blob} 我的 密钥',
      );
    });

    for (final (description, value) in <(String, String)>[
      ('空文本', ''),
      ('只有空白', '  \n\t '),
      ('两行公钥', '${newKey.publicOpenSsh}\n${otherKey.publicOpenSsh}'),
      ('行内回车符', '${parsed.type} ${parsed.blob}\r\n${otherKey.publicOpenSsh}'),
      ('NUL 字符', '${parsed.type} ${parsed.blob}\x00'),
      ('制表符分隔', '${parsed.type}\t${parsed.blob}'),
      ('控制字符', '${newKey.publicOpenSsh}\x07'),
      ('超长文本', 'ssh-ed25519 ${'A'.padRight(9000, 'A')}'),
      ('command 选项前缀', 'command="/bin/false" ${newKey.publicOpenSsh}'),
      ('from 选项前缀', 'from="10.0.0.1" ${newKey.publicOpenSsh}'),
      ('无参数选项前缀', 'no-pty ${newKey.publicOpenSsh}'),
      ('缺少密钥内容', parsed.type),
      ('只有类型和注释', 'ssh-ed25519 我的密钥'),
      ('base64 长度不合法', '${parsed.type} ${parsed.blob}A'),
      ('base64 含非法字符', '${parsed.type} ${parsed.blob.substring(1)}'),
      (
        'base64 不是密钥结构',
        'ssh-ed25519 ${base64.encode(utf8.encode('hello world!!'))}',
      ),
      ('类型与内容不一致', 'ssh-rsa ${parsed.blob}'),
      ('类型名大小写错误', 'Ssh-Ed25519 ${parsed.blob}'),
      (
        '内容被截断',
        '${parsed.type} ${parsed.blob.substring(0, parsed.blob.length - 8)}',
      ),
      ('PEM 私钥文本', '-----BEGIN OPENSSH PRIVATE KEY-----'),
    ]) {
      test('拒绝$description', () {
        expect(() => validatedOpenSshPublicKey(value), throwsFormatException);
      });
    }
  });

  group('未连接时的安装', () {
    test('非法公钥在连接检查之前被拒绝', () async {
      final connection = SshConnection(id: 'offline', host: testHost);
      addTearDown(connection.dispose);
      await expectLater(
        connection.installPublicKey('ssh-ed25519 不是密钥'),
        throwsFormatException,
      );
    });

    test('未连接时报告确定失败而不是结果未知', () async {
      final connection = SshConnection(id: 'offline', host: testHost);
      addTearDown(connection.dispose);
      await expectLater(
        connection.installPublicKey(newKey.publicOpenSsh),
        throwsA(
          isA<PublicKeyInstallFailure>()
              .having((error) => error.unknown, 'unknown', isFalse)
              .having((error) => error.message, 'message', isNotEmpty),
        ),
      );
    });
  });

  final enabled = Platform.environment['HARBOR_SSH_INTEGRATION'] == '1';
  group(
    '真实 loopback SFTP 安装',
    () {
      late Process fixture;
      late int port;
      late String privateKey;
      late String fixturePublicKey;
      late String fixtureExistingKey;

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
        fixturePublicKey = config['publicKey'] as String;
        fixtureExistingKey = config['existingKey'] as String;
      });

      tearDownAll(() async {
        fixture.kill();
        await fixture.exitCode;
      });

      Host host() => Host(
        id: 'fixture',
        name: 'Fixture',
        address: '127.0.0.1',
        port: port,
        username: 'tester',
        authMethod: AuthMethod.password,
      );

      Future<SshConnection> connect({bool openShell = false}) async {
        final connection = SshConnection(id: 'install', host: host());
        addTearDown(connection.dispose);
        await connection.connect(
          const Credentials(password: 'fixture-password'),
          memoryRepository(),
          (_, _) async => true,
          openShell: openShell,
        );
        return connection;
      }

      /// A second, independent connection whose virtual tree is its own.
      Future<SSHClient> openClient() async {
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
        return client;
      }

      Future<T> withClient<T>(Future<T> Function(SSHClient) action) async {
        final client = await openClient();
        try {
          return await action(client);
        } finally {
          unawaited(client.close().catchError((Object _) {}));
        }
      }

      /// Reads the fixture's own permission report over a virtual exec channel.
      /// The command is a fixed token; nothing is interpolated into it.
      Future<String> keyModes(SSHClient client) async {
        final session = await client.execute('harbor-key-fixture-modes');
        final output = StringBuffer();
        await Future.wait<void>([
          session.stdout
              .cast<List<int>>()
              .transform(const Utf8Decoder())
              .forEach(output.write),
          session.stderr.drain<void>(),
          session.done.then((_) {}),
        ]);
        session.close();
        return output.toString();
      }

      Future<Uint8List> readFile(SftpClient sftp, String path) async {
        final file = await sftp.open(path);
        try {
          return await file.readBytes();
        } finally {
          await file.close();
        }
      }

      Future<void> writeFile(
        SftpClient sftp,
        String path,
        List<int> content,
      ) async {
        final file = await sftp.open(
          path,
          mode: SftpFileOpenMode.write | SftpFileOpenMode.create,
        );
        try {
          await file.writeBytes(Uint8List.fromList(content), offset: 0);
        } finally {
          await file.close();
        }
      }

      Future<Uint8List> installedContent(SshConnection connection) async {
        final bytes = BytesBuilder(copy: false);
        await connection.files.download(
          _authorizedKeys,
          (chunk) async => bytes.add(chunk),
          cancellation: TransferCancellation(),
          onProgress: (_) {},
        );
        return bytes.takeBytes();
      }

      Future<bool> homeHasSshDirectory(SshConnection connection) async {
        final listing = await connection.files.browse(_home);
        return listing.entries.any((entry) => entry.name == '.ssh');
      }

      test('真实 RSA 公钥行通过校验', () {
        expect(validatedOpenSshPublicKey(fixturePublicKey), fixturePublicKey);
        final existing = parseOpenSshPublicKey(fixtureExistingKey);
        expect(existing.type, 'ssh-rsa');
        expect(base64.decode(existing.blob), isNotEmpty);
      });

      test('全新安装返回 true，读回内容为公钥加换行', () async {
        final connection = await connect();
        expect(await connection.installPublicKey(newKey.publicOpenSsh), isTrue);
        expect(
          await installedContent(connection),
          utf8.encode('${newKey.publicOpenSsh}\n'),
        );
        expect(await homeHasSshDirectory(connection), isTrue);
        expect(connection.status, ConnectionStatus.connected);
        expect(connection.error, isNull);
      });

      test('重复安装同一公钥返回 false 且内容逐字节不变', () async {
        final connection = await connect();
        expect(await connection.installPublicKey(newKey.publicOpenSsh), isTrue);
        final first = await installedContent(connection);
        // A different comment still describes the same key.
        expect(
          await connection.installPublicKey(
            '${parsed.type} ${parsed.blob} harbor-again',
          ),
          isFalse,
        );
        expect(await installedContent(connection), first);
      });

      test('非法公钥抛 FormatException 且不创建任何远程文件', () async {
        final connection = await connect();
        for (final value in [
          parsed.type,
          '${newKey.publicOpenSsh}\n${otherKey.publicOpenSsh}',
          'no-pty ${newKey.publicOpenSsh}',
        ]) {
          await expectLater(
            connection.installPublicKey(value),
            throwsFormatException,
          );
        }
        expect(await homeHasSshDirectory(connection), isFalse);
      });

      test('修正既有 ~/.ssh 与 authorized_keys 权限并补尾换行', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          await writeFile(
            sftp,
            _authorizedKeys,
            utf8.encode(fixtureExistingKey),
          );
          expect(
            (await sftp.stat(_sshDirectory, followLink: false)).mode!.value &
                0xfff,
            mode('755'),
          );
          final before = await sftp.stat(_authorizedKeys, followLink: false);
          expect(before.mode!.value & 0xfff, mode('644'));

          expect(
            await SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            isTrue,
          );

          final directory = await sftp.stat(_sshDirectory, followLink: false);
          expect(directory.isDirectory, isTrue);
          expect(directory.mode!.value & 0xfff, mode('700'));
          final file = await sftp.stat(_authorizedKeys, followLink: false);
          expect(file.isFile, isTrue);
          expect(file.mode!.value & 0xfff, mode('600'));
          final content = await readFile(sftp, _authorizedKeys);
          final expected = utf8.encode(
            '$fixtureExistingKey\n${newKey.publicOpenSsh}\n',
          );
          expect(content, expected);

          final report = await keyModes(client);
          expect(report, contains('.ssh=700:'));
          expect(report, contains('authorized_keys=600:${expected.length}'));

          // The same key with another comment is not appended again.
          expect(
            await SftpFiles(() => client.sftp())
                .installAuthorizedKey('${parsed.type} ${parsed.blob} 再次'),
            isFalse,
          );
          expect(await readFile(sftp, _authorizedKeys), expected);
          await sftp.close();
        });
      });

      test('~/.ssh 是符号链接时拒绝，且不写穿链接目标', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          // dartssh2 sends the target first; paramiko builds the link at the
          // second path.
          await sftp.link('$_home/docs', _sshDirectory);
          expect(
            (await sftp.stat(_sshDirectory, followLink: false)).isSymbolicLink,
            isTrue,
          );

          await expectLater(
            SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            throwsA(
              isA<PublicKeyInstallFailure>().having(
                (error) => error.unknown,
                'unknown',
                isFalse,
              ),
            ),
          );
          await expectLater(
            sftp.stat('$_home/docs/authorized_keys', followLink: false),
            throwsA(isA<SftpStatusError>()),
          );
          await sftp.close();
        });
      });

      test('authorized_keys 是符号链接时拒绝，且链接目标内容不变', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          await sftp.link('$_home/readme.txt', _authorizedKeys);
          final before = await readFile(sftp, '$_home/readme.txt');

          await expectLater(
            SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            throwsA(
              isA<PublicKeyInstallFailure>().having(
                (error) => error.unknown,
                'unknown',
                isFalse,
              ),
            ),
          );
          expect(await readFile(sftp, '$_home/readme.txt'), before);
          await sftp.close();
        });
      });

      test('authorized_keys 是目录时拒绝', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          await sftp.mkdir(_authorizedKeys);

          await expectLater(
            SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            throwsA(
              isA<PublicKeyInstallFailure>().having(
                (error) => error.unknown,
                'unknown',
                isFalse,
              ),
            ),
          );
          expect(
            (await sftp.stat(_authorizedKeys, followLink: false)).isDirectory,
            isTrue,
          );
          await sftp.close();
        });
      });

      test('已存在公钥时同样把权限收敛为 0600', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          await writeFile(
            sftp,
            _authorizedKeys,
            utf8.encode('${newKey.publicOpenSsh}\n'),
          );
          final before = await readFile(sftp, _authorizedKeys);
          expect(
            (await sftp.stat(_sshDirectory, followLink: false)).mode!.value &
                0xfff,
            mode('755'),
          );
          expect(
            (await sftp.stat(_authorizedKeys, followLink: false)).mode!.value &
                0xfff,
            mode('644'),
          );

          expect(
            await SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            isFalse,
          );
          expect(
            (await sftp.stat(_sshDirectory, followLink: false)).mode!.value &
                0xfff,
            mode('700'),
          );
          expect(
            (await sftp.stat(_authorizedKeys, followLink: false)).mode!.value &
                0xfff,
            mode('600'),
          );
          expect(await readFile(sftp, _authorizedKeys), before);
          await sftp.close();
        });
      });

      test('其它 key 的注释包含目标公钥内容时仍会写入', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          // The decoy only embeds the body inside a longer token: it is not an
          // entry for this key, so the install must not treat it as one.
          final decoy = '${otherKey.publicOpenSsh} X${parsed.blob}';
          await writeFile(sftp, _authorizedKeys, utf8.encode('$decoy\n'));

          expect(
            await SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            isTrue,
          );
          expect(
            await readFile(sftp, _authorizedKeys),
            utf8.encode('$decoy\n${newKey.publicOpenSsh}\n'),
          );
          await sftp.close();
        });
      });

      test('注释行与其它 key 注释里的完整公钥都不算已安装', () async {
        for (final existing in [
          // A whole key hidden in a comment line.
          '# ${newKey.publicOpenSsh}\n',
          // A whole key sitting in another entry's comment.
          '${otherKey.publicOpenSsh} ${parsed.type} ${parsed.blob}\n',
          // A quoted command may contain a whole key before the real entry.
          'command="echo ${parsed.type} ${parsed.blob} marker" ${otherKey.publicOpenSsh}\n',
        ]) {
          await withClient((client) async {
            final sftp = await client.sftp();
            await sftp.mkdir(_sshDirectory);
            await writeFile(sftp, _authorizedKeys, utf8.encode(existing));

            expect(
              await SftpFiles(() => client.sftp())
                  .installAuthorizedKey(newKey.publicOpenSsh),
              isTrue,
            );
            expect(
              await readFile(sftp, _authorizedKeys),
              utf8.encode('$existing${newKey.publicOpenSsh}\n'),
            );
            await sftp.close();
          });
        }
      });

      test('带空格的 command 选项仍识别其后真正的公钥', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          final existing =
              'command="echo hello world",no-pty ${newKey.publicOpenSsh}\n';
          await writeFile(sftp, _authorizedKeys, utf8.encode(existing));

          expect(
            await SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            isFalse,
          );
          expect(await readFile(sftp, _authorizedKeys), utf8.encode(existing));
          await sftp.close();
        });
      });

      test('authorized_keys 超过 4 MiB 时拒绝且不写入', () async {
        await withClient((client) async {
          final sftp = await client.sftp();
          await sftp.mkdir(_sshDirectory);
          const limit = 4 * 1024 * 1024;
          // At the cap a duplicate needs no append; one byte beyond the cap
          // must be rejected even if that key is already present.
          await writeFile(
            sftp,
            _authorizedKeys,
            utf8.encode('${newKey.publicOpenSsh}\n'),
          );
          await sftp.setStat(_authorizedKeys, SftpFileAttrs(size: limit));
          expect(
            await SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            isFalse,
          );
          expect(
            (await sftp.stat(_authorizedKeys, followLink: false)).size,
            limit,
          );
          await sftp.setStat(_authorizedKeys, SftpFileAttrs(size: limit + 1));

          await expectLater(
            SftpFiles(() => client.sftp())
                .installAuthorizedKey(newKey.publicOpenSsh),
            throwsA(
              isA<PublicKeyInstallFailure>()
                  .having((error) => error.unknown, 'unknown', isFalse)
                  .having(
                    (error) => error.message,
                    'message',
                    contains('4 MiB'),
                  ),
            ),
          );
          final after = await sftp.stat(_authorizedKeys, followLink: false);
          expect(after.size, limit + 1);
          await sftp.close();
        });
      });
    },
    skip: !enabled
        ? '设置 HARBOR_SSH_INTEGRATION=1 运行；依赖 tool/requirements-test.txt'
        : false,
  );
}
