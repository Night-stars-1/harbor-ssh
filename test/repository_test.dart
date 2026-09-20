import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/domain/host.dart';

import 'support.dart';

void main() {
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
