import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';

import 'support.dart';

const keyUser = SshUser(
  id: 'key',
  name: 'Deployment',
  username: '',
  authMethod: AuthMethod.privateKey,
  publicKey: 'ssh-ed25519 AAAA old-comment',
);
const signingKey = Credentials(privateKey: 'private-key', passphrase: 'phrase');

SyncSnapshot keySnapshot(
  Credentials? secret, {
  String? name,
  String? publicKey,
}) => SyncSnapshot({
  'key:key': {
    'data': {...keyUser.toJson(), 'name': ?name, 'publicKey': ?publicKey},
    'secret': secret?.toJson(),
  },
});
SyncSnapshot passwordSnapshot(Credentials? secret, {String? username}) =>
    SyncSnapshot({
      'host:${testHost.id}': {
        'data': {...testHost.toJson(), 'username': ?username},
        'secret': secret?.toJson(),
      },
    });

void main() {
  const config = WebDavSettings(
    url: 'https://sync.example.test/',
    username: 'test',
    password: 'webdav-password',
    encryptionPassword: 'test-encryption-password',
  );

  test('私钥无法恢复时云同步不写远端、不推进基线、不改本地', () async {
    final repository = memoryRepository();
    await repository.saveUsers([keyUser]);
    final missing = await SyncStorage(repository).capture();
    final encrypted = await encryptSync(
      missing.encode(),
      config.encryptionPassword,
    );
    await repository.preferences.write(config.baselineKey, encrypted);
    final client = _CredentialWebDav(config)..content = encrypted;
    final sync = WebDavSync(repository, clientFactory: (_) => client);
    addTearDown(sync.dispose);
    await sync.saveSettings(config);
    await expectLater(sync.synchronize(), throwsA(isA<SyncFailure>()));
    expect(sync.message, contains('缺少私钥'));
    expect(sync.lastSync, isNull);
    expect(client.writes, 0);
    expect(client.content, encrypted);
    expect(await repository.preferences.read(config.baselineKey), encrypted);
    expect(
      (await SyncStorage(repository).capture()).encode(),
      missing.encode(),
    );
    expect(await repository.secrets.read('harbor.sync.pending.v1'), isNull);
  });

  test('云同步从完整远端恢复本地，再修复旧客户端上传的空私钥', () async {
    final repository = memoryRepository();
    await repository.saveUsers([keyUser]);
    final complete = keySnapshot(signingKey);
    final encrypted = await encryptSync(
      complete.encode(),
      config.encryptionPassword,
    );
    final client = _CredentialWebDav(config)..content = encrypted;
    final sync = WebDavSync(repository, clientFactory: (_) => client);
    addTearDown(sync.dispose);
    await sync.saveSettings(config);
    await sync.synchronize();
    expect(
      (await repository.userCredentials(keyUser.id))?.toJson(),
      signingKey.toJson(),
    );
    expect(client.writes, 0);
    client.content = await encryptSync(
      keySnapshot(null).encode(),
      config.encryptionPassword,
    );
    await sync.synchronize();
    expect(client.writes, 1);
    final restored = SyncSnapshot.decode(
      await decryptSync(client.content!, config.encryptionPassword),
    );
    expect(restored.records['key:key']!['secret'], signingKey.toJson());
    expect(
      (await repository.userCredentials(keyUser.id))?.toJson(),
      signingKey.toJson(),
    );
    expect(sync.failed, isFalse);
    expect(
      await repository.preferences.read(config.baselineKey),
      client.content,
    );
  });

  for (final side in ['local', 'remote', 'both']) {
    test('$side 私钥丢失时从相同公钥的完整副本恢复，口令和输入快照保持不变', () {
      final complete = keySnapshot(signingKey);
      final missing = keySnapshot(null);
      final result = SyncSnapshot.merge(
        local: side == 'remote' ? complete : missing,
        remote: side == 'local' ? complete : missing,
        base: complete,
      );
      expect(result.records['key:key']!['secret'], signingKey.toJson());
      expect(missing.records['key:key']!['secret'], isNull);
      expect(complete.records['key:key']!['secret'], signingKey.toJson());
    });
  }

  test('修复私钥时保留本机重命名，允许公钥备注变化', () {
    final base = keySnapshot(signingKey);
    final local = keySnapshot(
      null,
      name: 'Renamed',
      publicKey: 'ssh-ed25519 AAAA new-comment',
    );
    final result = SyncSnapshot.merge(local: local, remote: base, base: base);
    expect((result.records['key:key']!['data'] as Map)['name'], 'Renamed');
    expect(result.records['key:key']!['secret'], signingKey.toJson());
  });

  test('公钥已改变时不挪用旧私钥，停止同步', () {
    final base = keySnapshot(signingKey);
    expect(
      () => SyncSnapshot.merge(
        local: keySnapshot(null, publicKey: 'ssh-ed25519 BBBB'),
        remote: base,
        base: base,
      ),
      throwsA(isA<SyncCredentialMissing>()),
    );
  });

  test('空私钥也视为丢失，可以从完整副本恢复', () {
    final complete = keySnapshot(signingKey);
    final result = SyncSnapshot.merge(
      local: keySnapshot(const Credentials(privateKey: '  ')),
      remote: complete,
      base: complete,
    );
    expect(result.records['key:key']!['secret'], signingKey.toJson());
  });

  test('完整轮换后的密钥不会被旧基线恢复覆盖', () {
    final base = keySnapshot(signingKey);
    const rotated = Credentials(
      privateKey: 'rotated',
      passphrase: 'new-phrase',
    );
    final local = keySnapshot(rotated, publicKey: 'ssh-ed25519 BBBB');
    final result = SyncSnapshot.merge(
      local: local,
      remote: keySnapshot(null),
      base: base,
    );
    expect(result.encode(), local.encode());
  });

  test('不存在完整私钥时包括显式冲突选择在内都不能同步空凭证', () {
    for (final choice in [
      null,
      SyncConflictChoice.local,
      SyncConflictChoice.remote,
    ]) {
      expect(
        () => SyncSnapshot.merge(
          local: keySnapshot(null),
          remote: keySnapshot(null),
          base: SyncSnapshot.empty(),
          choice: choice,
        ),
        throwsA(isA<SyncCredentialMissing>()),
      );
    }
  });

  test('删除整条凭证仍然按原有三方合并语义同步', () {
    final base = keySnapshot(signingKey);
    expect(
      SyncSnapshot.merge(
        local: SyncSnapshot.empty(),
        remote: base,
        base: base,
      ).records,
      isEmpty,
    );
    expect(
      SyncSnapshot.merge(
        local: base,
        remote: SyncSnapshot.empty(),
        base: base,
      ).records,
      isEmpty,
    );
  });

  for (final side in ['local', 'remote']) {
    test('$side 密码突然缺失必须先确认，选择完整一端保留密码', () {
      final base = passwordSnapshot(const Credentials(password: 'saved'));
      final missing = passwordSnapshot(null);
      final a = side == 'local' ? missing : base;
      final b = side == 'remote' ? missing : base;
      expect(
        () => SyncSnapshot.merge(local: a, remote: b, base: base),
        throwsA(isA<SyncConflict>()),
      );
      final keep = side == 'local'
          ? SyncConflictChoice.remote
          : SyncConflictChoice.local;
      expect(
        SyncSnapshot.merge(
          local: a,
          remote: b,
          base: base,
          choice: keep,
        ).encode(),
        base.encode(),
      );
      final clear = side == 'local'
          ? SyncConflictChoice.local
          : SyncConflictChoice.remote;
      expect(
        SyncSnapshot.merge(
          local: a,
          remote: b,
          base: base,
          choice: clear,
        ).encode(),
        missing.encode(),
      );
    });
  }

  test('新建未填密码的连接或改变登录账户不误恢复旧密码', () {
    final missing = passwordSnapshot(null);
    expect(
      SyncSnapshot.merge(
        local: missing,
        remote: SyncSnapshot.empty(),
        base: SyncSnapshot.empty(),
      ).encode(),
      missing.encode(),
    );
    final base = passwordSnapshot(const Credentials(password: 'old-account'));
    final changed = passwordSnapshot(null, username: 'different-account');
    expect(
      SyncSnapshot.merge(local: changed, remote: base, base: base).encode(),
      changed.encode(),
    );
  });

  test('不完整同步快照不能删除本机私钥或写入回滚日志', () async {
    final repository = memoryRepository();
    await repository.saveUsers([keyUser]);
    await repository.saveUserCredentials(keyUser.id, signingKey);
    final storage = SyncStorage(repository);
    final before = await storage.capture();
    await expectLater(
      storage.apply(keySnapshot(null)),
      throwsA(isA<SyncCredentialMissing>()),
    );
    expect((await storage.capture()).encode(), before.encode());
    expect(await repository.secrets.read('harbor.sync.pending.v1'), isNull);
  });
}

class _CredentialWebDav extends WebDavClient {
  _CredentialWebDav(super.settings);
  String? content;
  int writes = 0;

  @override
  Future<WebDavResponse> request(
    String method, {
    bool directory = false,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    if (method == 'GET') return WebDavResponse(200, content!, '"$writes"');
    if (method == 'PUT') {
      content = body;
      writes++;
      return const WebDavResponse(201, '', null);
    }
    throw StateError('Unexpected request: $method');
  }
}
