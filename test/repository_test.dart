import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/domain/host.dart';

import 'support.dart';

void main() {
  group('登录凭证解析', () {
    test('免密码连接无需存储凭证，也不使用遗留密码或私钥', () async {
      final repository = memoryRepository();
      const target = Host(
        id: 'cnb',
        name: 'CNB',
        address: 'cnb.space',
        username: 'cnb-token',
        authMethod: AuthMethod.none,
        userId: 'stale-key',
      );
      Future<void> check() async {
        final credentials = await repository.loginCredentials(target);
        expect(credentials, isNotNull);
        expect(credentials!.password, isEmpty);
        expect(credentials.privateKey, isEmpty);
      }

      await check();
      await repository.saveCredentials(
        target.id,
        const Credentials(password: 'stale-password'),
      );
      await repository.saveUserCredentials(
        target.userId,
        const Credentials(privateKey: 'stale-key'),
      );
      await check();
    });

    const host = Host(
      id: 'key-host',
      name: 'Server',
      address: 'server.example.com',
      username: 'root',
      authMethod: AuthMethod.privateKey,
      userId: 'saved-key',
    );

    test('使用绑定凭证的私钥和口令', () async {
      final repository = memoryRepository();
      await repository.saveUserCredentials(
        host.userId,
        const Credentials(privateKey: 'key', passphrase: 'phrase'),
      );
      final credentials = await repository.loginCredentials(host);
      expect(credentials?.privateKey, 'key');
      expect(credentials?.passphrase, 'phrase');
    });

    test('连接级有效私钥优先，空白或密码记录不遮蔽绑定的私钥', () async {
      final repository = memoryRepository();
      await repository.saveUserCredentials(
        host.userId,
        const Credentials(privateKey: 'inherited'),
      );
      await repository.saveCredentials(
        host.id,
        const Credentials(privateKey: 'direct'),
      );
      expect((await repository.loginCredentials(host))?.privateKey, 'direct');
      for (final stale in [
        const Credentials(),
        const Credentials(password: 'old-password'),
        const Credentials(privateKey: '   '),
      ]) {
        await repository.saveCredentials(host.id, stale);
        expect(
          (await repository.loginCredentials(host))?.privateKey,
          'inherited',
        );
      }
    });

    test('只有凭证名称、公钥或空私钥不视为可登录', () async {
      final repository = memoryRepository();
      await repository.saveUsers([
        SshUser(
          id: host.userId,
          name: 'Saved key',
          username: '',
          authMethod: AuthMethod.privateKey,
          publicKey: 'ssh-ed25519 public',
        ),
      ]);
      expect(await repository.loginCredentials(host), isNull);
      await repository.saveUserCredentials(
        host.userId,
        const Credentials(privateKey: '   '),
      );
      expect(await repository.loginCredentials(host), isNull);
    });

    test('没有绑定时不猜测或使用其他凭证', () async {
      final repository = memoryRepository();
      await repository.saveUserCredentials(
        'unrelated',
        const Credentials(privateKey: 'key'),
      );
      expect(await repository.loginCredentials(host), isNull);
    });

    test('密码认证只读取密码，并保持密码中的空格', () async {
      final repository = memoryRepository();
      await repository.saveCredentials(
        testHost.id,
        const Credentials(privateKey: 'key'),
      );
      expect(await repository.loginCredentials(testHost), isNull);
      await repository.saveCredentials(
        testHost.id,
        const Credentials(password: '  secret  '),
      );
      expect(
        (await repository.loginCredentials(testHost))?.password,
        '  secret  ',
      );
    });
  });

  group('指纹冲突确认', () {
    late HostRepository repository;
    const saved = 'ssh-ed25519 SHA256:original';

    setUp(() async {
      repository = memoryRepository();
      await repository.verifyHost(
        testHost,
        'ssh-ed25519',
        'SHA256:original',
        (_, _) async => true,
      );
    });

    Future<bool> firstTrust(String type, String fingerprint) async =>
        fail('已知主机不能通过首次信任提示更新指纹');

    test('确认后替换指纹，再次连接相同指纹不再提示', () async {
      expect(
        await repository.verifyHost(
          testHost,
          'ssh-ed25519',
          'SHA256:new',
          firstTrust,
          confirmKeyChange: (type, fingerprint, previousKey) async {
            expect(type, 'ssh-ed25519');
            expect(fingerprint, 'SHA256:new');
            expect(previousKey, saved);
            expect((repository.secrets as MemoryStore).values.values, [saved]);
            return true;
          },
        ),
        isTrue,
      );
      expect((repository.secrets as MemoryStore).values.values, [
        'ssh-ed25519 SHA256:new',
      ]);
      expect(
        await repository.verifyHost(
          testHost,
          'ssh-ed25519',
          'SHA256:new',
          firstTrust,
          confirmKeyChange: (_, _, _) async => fail('相同指纹不应弹窗'),
        ),
        isTrue,
      );
    });

    test('取消确认阻止连接并保留原指纹', () async {
      await expectLater(
        repository.verifyHost(
          testHost,
          'ssh-ed25519',
          'SHA256:new',
          firstTrust,
          confirmKeyChange: (_, _, _) async => false,
        ),
        throwsA(isA<HostKeyMismatch>()),
      );
      expect((repository.secrets as MemoryStore).values.values, [saved]);
    });

    test('密钥类型改变也需要明确确认', () async {
      var prompted = false;
      await repository.verifyHost(
        testHost,
        'ssh-rsa',
        'SHA256:original',
        firstTrust,
        confirmKeyChange: (type, fingerprint, previousKey) async {
          prompted = true;
          expect(type, 'ssh-rsa');
          expect(previousKey, saved);
          return true;
        },
      );
      expect(prompted, isTrue);
      expect((repository.secrets as MemoryStore).values.values, [
        'ssh-rsa SHA256:original',
      ]);
    });

    test('保存新指纹失败时不放行连接', () async {
      (repository.secrets as MemoryStore).failWrites = true;
      await expectLater(
        repository.verifyHost(
          testHost,
          'ssh-ed25519',
          'SHA256:new',
          firstTrust,
          confirmKeyChange: (_, _, _) async => true,
        ),
        throwsStateError,
      );
      expect((repository.secrets as MemoryStore).values.values, [saved]);
    });

    for (final sameKey in [false, true]) {
      test('并发确认${sameKey ? '相同指纹可以继续连接' : '不同指纹不能覆盖先确认的指纹'}', () async {
        final opened = Completer<void>();
        final decision = Completer<bool>();
        final pending = repository.verifyHost(
          testHost,
          'ssh-ed25519',
          sameKey ? 'SHA256:accepted' : 'SHA256:stale',
          firstTrust,
          confirmKeyChange: (_, _, previousKey) {
            expect(previousKey, saved);
            opened.complete();
            return decision.future;
          },
        );
        await opened.future;
        await repository.verifyHost(
          testHost,
          'ssh-ed25519',
          'SHA256:accepted',
          firstTrust,
          confirmKeyChange: (_, _, _) async => true,
        );
        final checked = expectLater(
          pending,
          sameKey ? completion(isTrue) : throwsA(isA<HostKeyMismatch>()),
        );
        decision.complete(true);
        await checked;
        expect((repository.secrets as MemoryStore).values.values, [
          'ssh-ed25519 SHA256:accepted',
        ]);
      });
    }

    test('确认期间重置指纹不能被迟到的确认覆盖', () async {
      await expectLater(
        repository.verifyHost(
          testHost,
          'ssh-ed25519',
          'SHA256:new',
          firstTrust,
          confirmKeyChange: (_, _, _) async {
            await repository.forgetHostKey(testHost);
            return true;
          },
        ),
        throwsA(isA<HostKeyMismatch>()),
      );
      expect((repository.secrets as MemoryStore).values, isEmpty);
    });
  });

  test('并发首次信任不能覆盖另一会话已经信任的不同指纹', () async {
    final repository = memoryRepository();
    final results = await Future.wait([
      repository
          .verifyHost(
            testHost,
            'ssh-ed25519',
            'SHA256:one',
            (_, _) async => true,
          )
          .then<Object>((v) => v, onError: (Object e) => e),
      repository
          .verifyHost(
            testHost,
            'ssh-ed25519',
            'SHA256:two',
            (_, _) async => true,
          )
          .then<Object>((v) => v, onError: (Object e) => e),
    ]);
    expect(results.where((v) => v == true).length, 1);
    expect(results.whereType<HostKeyMismatch>().length, 1);
  });
  test('主机配置与凭据分离，支持删除已记住凭据', () async {
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    await repository.saveCredentials(
      testHost.id,
      const Credentials(password: 'sensitive-password'),
    );
    expect(
      (await repository.loadHosts()).single.destination,
      'deploy@dev.example.com:22',
    );
    expect(
      (repository.preferences as MemoryStore).values.values.join(),
      isNot(contains('sensitive-password')),
    );
    expect(
      (await repository.credentials(testHost.id))!.password,
      'sensitive-password',
    );
    await repository.saveCredentials(testHost.id, null);
    expect(await repository.credentials(testHost.id), isNull);
  });
  test('用户配置与凭据分离，删除用户凭据不影响主机', () async {
    final repository = memoryRepository();
    const user = SshUser(id: 'user-1', name: '生产部署', username: 'deploy');
    await repository.saveHosts([testHost]);
    await repository.saveUsers([user]);
    await repository.saveUserCredentials(
      user.id,
      const Credentials(password: 'user-secret'),
    );
    expect((await repository.loadUsers()).single.name, '生产部署');
    expect(
      (repository.preferences as MemoryStore).values.values.join(),
      isNot(contains('user-secret')),
    );
    expect(
      (await repository.userCredentials(user.id))!.password,
      'user-secret',
    );
    expect(await repository.credentials(testHost.id), isNull);
    await repository.saveUserCredentials(user.id, null);
    expect(await repository.userCredentials(user.id), isNull);
  });
  test('取消首次信任不会记住指纹', () async {
    final repository = memoryRepository();
    expect(
      await repository.verifyHost(
        testHost,
        'ssh-ed25519',
        'SHA256:first',
        (_, _) async => false,
      ),
      isFalse,
    );
    expect((repository.secrets as MemoryStore).values, isEmpty);
  });
  test('保存首次信任，后续相同指纹不再提示，变化时拒绝', () async {
    final repository = memoryRepository();
    var prompts = 0;
    Future<bool> prompt(String type, String fingerprint) async {
      prompts++;
      return true;
    }

    expect(
      await repository.verifyHost(
        testHost,
        'ssh-ed25519',
        'SHA256:first',
        prompt,
      ),
      isTrue,
    );
    expect(
      await repository.verifyHost(
        testHost,
        'ssh-ed25519',
        'SHA256:first',
        prompt,
      ),
      isTrue,
    );
    expect(prompts, 1);
    await expectLater(
      repository.verifyHost(testHost, 'ssh-ed25519', 'SHA256:changed', prompt),
      throwsA(isA<HostKeyMismatch>()),
    );
    expect(prompts, 1);
    await repository.forgetHostKey(testHost);
    expect(
      await repository.verifyHost(
        testHost,
        'ssh-ed25519',
        'SHA256:changed',
        prompt,
      ),
      isTrue,
    );
    expect(prompts, 2);
  });
  test('主机指纹按地址端口关联，与账号无关', () async {
    final repository = memoryRepository();
    await repository.verifyHost(
      testHost,
      'ssh-ed25519',
      'SHA256:first',
      (_, _) async => true,
    );
    const anotherUser = Host(
      id: 'host-2',
      name: 'root',
      address: 'DEV.EXAMPLE.COM',
      username: 'root',
    );
    await expectLater(
      repository.verifyHost(
        anotherUser,
        'ssh-ed25519',
        'SHA256:changed',
        (_, _) async => true,
      ),
      throwsA(isA<HostKeyMismatch>()),
    );
    const anotherPort = Host(
      id: 'host-3',
      name: '2222',
      address: 'dev.example.com',
      port: 2222,
      username: 'root',
    );
    expect(
      await repository.verifyHost(
        anotherPort,
        'ssh-ed25519',
        'SHA256:changed',
        (_, _) async => true,
      ),
      isTrue,
    );
  });
}
