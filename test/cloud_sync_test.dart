import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';

import 'support.dart';

SyncSnapshot snapshot(String? name, {bool favorite = false}) => SyncSnapshot({
  if (name != null)
    'host:host-1': {
      'data': {...testHost.toJson(), 'name': name, 'favorite': favorite},
      'secret': const Credentials(password: 'ssh-password').toJson(),
    },
});

void main() {
  test('三方合并保留新增、同步删除，双端修改和删除冲突不会静默覆盖', () {
    final base = snapshot('original');
    final a = snapshot('local');
    final b = snapshot('remote');
    expect(
      () => SyncSnapshot.merge(local: a, remote: b, base: base),
      throwsA(isA<SyncConflict>()),
    );
    expect(
      () => SyncSnapshot.merge(local: snapshot(null), remote: b, base: base),
      throwsA(isA<SyncConflict>()),
    );
    expect(
      SyncSnapshot.merge(
        local: snapshot(null),
        remote: base,
        base: base,
      ).records,
      isEmpty,
    );
    expect(
      SyncSnapshot.merge(
        local: base,
        remote: snapshot(null),
        base: base,
      ).records,
      isEmpty,
    );
    expect(
      SyncSnapshot.merge(
        local: a,
        remote: b,
        base: base,
        choice: SyncConflictChoice.remote,
      ).encode(),
      b.encode(),
    );
    final extra = SyncSnapshot({
      'host:new': {
        'data': {...testHost.toJson(), 'id': 'new'},
        'secret': null,
      },
    });
    expect(
      SyncSnapshot.merge(
        local: a,
        remote: extra,
        base: SyncSnapshot.empty(),
      ).records,
      hasLength(2),
    );
  });

  test('加密文件不含明文，随机化密文，错误密码和篡改不可解密', () async {
    final plain = snapshot('private-host').encode();
    final first = await encryptSync(plain, 'encryption-password');
    final second = await encryptSync(plain, 'encryption-password');
    expect(first, isNot(second));
    expect(first, isNot(contains('private-host')));
    expect(first, isNot(contains('ssh-password')));
    expect(await decryptSync(first, 'encryption-password'), plain);
    await expectLater(decryptSync(first, 'wrong-password'), throwsA(anything));
    final altered = jsonDecode(first) as Map<String, dynamic>;
    final data = base64Decode(altered['data'] as String);
    data[0] ^= 1;
    altered['data'] = base64Encode(data);
    await expectLater(
      decryptSync(jsonEncode(altered), 'encryption-password'),
      throwsA(anything),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('本地同步写入失败回滚，密钥仅落在安全存储，启动可恢复未完成写入', () async {
    final preferences = _FailOnceStore();
    final secrets = MemoryStore();
    final repository = HostRepository(
      preferences: preferences,
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    await repository.saveCredentials(
      testHost.id,
      const Credentials(password: 'old-password'),
    );
    final storage = SyncStorage(repository);
    final before = await storage.capture();
    preferences.failKey = 'harbor.users.v1';
    await expectLater(storage.apply(snapshot('changed')), throwsStateError);
    expect((await storage.capture()).encode(), before.encode());
    expect(preferences.values.values.join(), isNot(contains('old-password')));
    expect(secrets.values.containsKey('harbor.sync.pending.v1'), isFalse);
    await secrets.write(
      'harbor.sync.pending.v1',
      jsonEncode({
        'before': before.encode(),
        'incoming': snapshot('changed').encode(),
      }),
    );
    await repository.saveCredentials(
      testHost.id,
      const Credentials(password: 'partial'),
    );
    await storage.recover();
    expect((await storage.capture()).encode(), before.encode());
  });

  test('WebDAV 两设备同步凭证、收藏和删除，ETag 竞争及错误密码保留数据', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? remote;
    var revision = 0, rejectWrite = false, puts = 0;
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.method);
      expect(
        request.headers.value('authorization'),
        'Basic ${base64Encode(utf8.encode('test:app-password'))}',
      );
      if (request.method == 'PROPFIND') {
        expect(request.headers.value('depth'), '0');
        request.response.statusCode = 207;
      } else if (request.method == 'GET') {
        request.response.statusCode = remote == null ? 404 : 200;
        if (remote != null) {
          request.response.headers.set('ETag', '"$revision"');
          request.response.write(remote);
        }
      } else if (request.method == 'PUT') {
        final incoming = await utf8.decoder.bind(request).join();
        if (rejectWrite ||
            (remote == null
                ? request.headers.value('if-none-match') != '*'
                : request.headers.value('if-match') != '"$revision"')) {
          request.response.statusCode = 412;
        } else {
          remote = incoming;
          revision++;
          puts++;
          request.response.statusCode = 201;
        }
      }
      await request.response.close();
    });
    final settings = WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: 'shared-encryption-password',
    );
    final a = memoryRepository(), b = memoryRepository();
    final syncA = WebDavSync(a), syncB = WebDavSync(b);
    addTearDown(syncA.dispose);
    addTearDown(syncB.dispose);
    await syncA.saveSettings(settings);
    await syncB.saveSettings(settings);
    await syncA.testConnection(settings);
    await a.saveHosts([testHost]);
    await a.saveCredentials(
      testHost.id,
      const Credentials(password: 'ssh-private-password'),
    );
    const user = SshUser(
      id: 'key-1',
      name: 'SSH key',
      username: '',
      authMethod: AuthMethod.privateKey,
      publicKey: 'ssh-ed25519 public',
    );
    await a.saveUsers([user]);
    await a.saveUserCredentials(
      user.id,
      const Credentials(privateKey: 'private-key', passphrase: 'key-pass'),
    );
    await syncA.synchronize();
    expect(remote, isNot(contains('ssh-private-password')));
    expect(remote, isNot(contains('private-key')));
    await syncB.synchronize();
    expect((await b.loadHosts()).single.id, testHost.id);
    expect(
      (await b.credentials(testHost.id))!.password,
      'ssh-private-password',
    );
    expect((await b.userCredentials(user.id))!.privateKey, 'private-key');
    expect((await b.loadUsers()).single.publicKey, user.publicKey);
    expect(puts, 1);
    await b.saveHosts([testHost.withFavorite(true)]);
    await syncB.synchronize();
    await syncA.synchronize();
    expect((await a.loadHosts()).single.favorite, isTrue);
    Host renamed(String name) =>
        Host.fromJson({...testHost.toJson(), 'name': name});
    await a.saveHosts([renamed('A edit')]);
    await b.saveHosts([renamed('B edit')]);
    await syncA.synchronize();
    await expectLater(syncB.synchronize(), throwsA(isA<SyncConflict>()));
    await a.saveHosts([renamed('A newer edit')]);
    await syncA.synchronize();
    final newRemote = remote;
    await expectLater(
      syncB.synchronize(choice: SyncConflictChoice.local),
      throwsA(isA<SyncFailure>()),
    );
    expect(remote, newRemote);
    await expectLater(syncB.synchronize(), throwsA(isA<SyncConflict>()));
    await syncB.synchronize(choice: SyncConflictChoice.local);
    await syncA.synchronize();
    expect((await a.loadHosts()).single.name, 'B edit');
    await b.saveHosts([]);
    await b.saveCredentials(testHost.id, null);
    await syncB.synchronize();
    await syncA.synchronize();
    expect(await a.loadHosts(), isEmpty);
    expect(await a.credentials(testHost.id), isNull);
    await a.saveHosts([testHost]);
    final localBefore = (await SyncStorage(a).capture()).encode();
    final remoteBefore = remote;
    rejectWrite = true;
    await expectLater(syncA.synchronize(), throwsA(isA<SyncFailure>()));
    expect(remote, remoteBefore);
    expect((await SyncStorage(a).capture()).encode(), localBefore);
    rejectWrite = false;
    await syncA.saveSettings(
      WebDavSettings(
        url: settings.url,
        username: 'test',
        password: 'app-password',
        encryptionPassword: 'incorrect-encryption-password',
      ),
    );
    await expectLater(syncA.synchronize(), throwsA(isA<SyncFailure>()));
    expect(remote, remoteBefore);
    expect((await SyncStorage(a).capture()).encode(), localBefore);
    expect(a.preferences is MemoryStore, isTrue);
    expect(
      (a.preferences as MemoryStore).values.values.join(),
      isNot(contains('app-password')),
    );
    expect(
      (a.preferences as MemoryStore).values.values.join(),
      isNot(contains('private-key')),
    );
    expect(requests, containsAll(['PROPFIND', 'GET', 'PUT']));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

class _FailOnceStore extends MemoryStore {
  String? failKey;
  @override
  Future<void> write(String key, String value) async {
    if (key == failKey) {
      failKey = null;
      throw StateError('disk failure');
    }
    await super.write(key, value);
  }
}
