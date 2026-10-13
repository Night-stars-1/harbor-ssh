import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';

import 'support.dart';

const _password = Credentials(password: 'ssh-password');

Host _host({
  String name = '开发服务器',
  List<String> bookmarks = const ['/srv/a'],
  bool favorite = false,
}) => Host(
  id: 'host-1',
  name: name,
  address: 'dev.example.com',
  username: 'deploy',
  tags: const ['开发'],
  favorite: favorite,
  sftpBookmarks: bookmarks,
);

SyncSnapshot _snapshot(Host host, {Credentials? secret = _password}) =>
    SyncSnapshot({
      'host:${host.id}': <String, dynamic>{
        'data': host.toJson(),
        'secret': secret?.toJson(),
      },
    });

CloudSyncConfig _config() => const CloudSyncConfig(
  url: 'https://dav.example.com/sync/',
  username: 'test',
  password: 'app-password',
  encryptionPassword: 'shared-password',
);

/// The per-path bookmark write the model performs: read the current list and
/// save it with one path added.
Future<void> _addBookmark(
  HostRepository repository,
  String hostId,
  String path,
) => repository.withLocalData(() async {
  final hosts = await repository.loadHosts();
  await repository.saveHosts([
    for (final host in hosts)
      if (host.id == hostId && !host.sftpBookmarks.contains(path))
        host.withSftpBookmarks([...host.sftpBookmarks, path])
      else
        host,
  ]);
});

void main() {
  test('上传期间本地增删书签叠加在云端字段与云端新增书签之上', () {
    final started = _snapshot(_host());
    final base = _snapshot(_host());
    final incoming = SyncSnapshot.merge(
      local: started,
      remote: _snapshot(
        _host(name: '云端改名', bookmarks: ['/srv/a', '/srv/remote']),
      ),
      base: base,
    );
    expect((incoming.records['host:host-1']!['data'] as Map)['name'], '云端改名');

    final rebased = incoming.rebaseLocalBookmarks(
      started: started,
      current: _snapshot(_host(bookmarks: ['/srv/b'])),
    );
    final record = rebased.records['host:host-1']!;
    final data = record['data'] as Map;
    expect(data['name'], '云端改名');
    expect(data['sftpBookmarks'], ['/srv/remote', '/srv/b']);
    expect(record['secret'], incoming.records['host:host-1']!['secret']);
    expect(rebased.records.keys, incoming.records.keys);
  });

  test('本地删除书签后云端新增保留，删空则移除可选字段', () {
    final started = _snapshot(_host());
    final incoming = _snapshot(_host(bookmarks: ['/srv/a', '/srv/remote']));

    final partial = incoming.rebaseLocalBookmarks(
      started: started,
      current: _snapshot(_host(bookmarks: const [])),
    );
    expect((partial.records['host:host-1']!['data'] as Map)['sftpBookmarks'], [
      '/srv/remote',
    ]);

    final unchanged = _snapshot(_host());
    final emptied = unchanged.rebaseLocalBookmarks(
      started: started,
      current: _snapshot(_host(bookmarks: const [])),
    );
    final data = emptied.records['host:host-1']!['data'] as Map;
    expect(data.containsKey('sftpBookmarks'), isFalse);
    expect(emptied.encode(), isNot(contains('/srv/a')));
  });

  test('重放不改写任何输入快照', () {
    final started = _snapshot(_host());
    final current = _snapshot(_host(bookmarks: ['/srv/a', '/srv/b']));
    final incoming = _snapshot(_host(name: '云端改名'));
    final startedBefore = started.encode();
    final currentBefore = current.encode();
    final incomingBefore = incoming.encode();

    final rebased = incoming.rebaseLocalBookmarks(
      started: started,
      current: current,
    );
    expect(started.encode(), startedBefore);
    expect(current.encode(), currentBefore);
    expect(incoming.encode(), incomingBefore);
    expect(rebased.encode(), isNot(incomingBefore));
  });

  test('本地未变化时原样返回合并结果，不重新合并也不重新校验凭证', () {
    final local = _snapshot(_host());
    final accepted = SyncSnapshot.merge(
      local: local,
      remote: _snapshot(_host(), secret: null),
      base: _snapshot(_host()),
      choice: SyncConflictChoice.remote,
    );
    expect(accepted.records['host:host-1']!['secret'], isNull);

    final rebased = accepted.rebaseLocalBookmarks(
      started: local,
      current: local,
    );
    expect(rebased.records, accepted.records);
    expect(rebased.records['host:host-1']!['secret'], isNull);

    // 缺少私钥的记录同样不会在重放时被再次校验。
    final incomplete = SyncSnapshot({
      'key:user-1': <String, dynamic>{
        'data': const SshUser(
          id: 'user-1',
          name: '运维',
          username: 'deploy',
          authMethod: AuthMethod.privateKey,
          publicKey: 'ssh-ed25519 AAAA',
        ).toJson(),
        'secret': null,
      },
    });
    expect(
      () => incomplete.requireCompletePrivateKeys(),
      throwsA(isA<SyncCredentialMissing>()),
    );
    expect(
      incomplete.rebaseLocalBookmarks(started: local, current: local).records,
      incomplete.records,
    );
  });

  test('未接受凭证清空时三方合并仍然报冲突', () {
    expect(
      () => SyncSnapshot.merge(
        local: _snapshot(_host()),
        remote: _snapshot(_host(), secret: null),
        base: _snapshot(_host()),
      ),
      throwsA(isA<SyncConflict>()),
    );
  });

  test('云端删除主机而本地并发编辑书签时报冲突，不静默覆盖', () {
    final started = _snapshot(_host());
    final merged = SyncSnapshot.merge(
      local: started,
      remote: SyncSnapshot.empty(),
      base: _snapshot(_host()),
    );
    expect(merged.records, isEmpty);
    expect(
      () => merged.rebaseLocalBookmarks(
        started: started,
        current: _snapshot(_host(bookmarks: ['/srv/a', '/srv/b'])),
      ),
      throwsA(
        isA<SyncConflict>().having((error) => error.names, 'names', ['开发服务器']),
      ),
    );
  });

  test('其他并发字段、凭证与记录增删不会被静默覆盖', () {
    final started = _snapshot(_host());
    final incoming = _snapshot(_host(name: '云端改名'));

    expect(
      () => incoming.rebaseLocalBookmarks(
        started: started,
        current: _snapshot(_host(name: '本地改名')),
      ),
      throwsA(isA<SyncConflict>()),
    );
    expect(
      () => incoming.rebaseLocalBookmarks(
        started: started,
        current: _snapshot(_host(), secret: const Credentials(password: '新')),
      ),
      throwsA(isA<SyncConflict>()),
    );
    expect(
      () => incoming.rebaseLocalBookmarks(
        started: started,
        current: _snapshot(_host(favorite: true)),
      ),
      throwsA(isA<SyncConflict>()),
    );
    expect(
      () => incoming.rebaseLocalBookmarks(
        started: started,
        current: SyncSnapshot.empty(),
      ),
      throwsA(isA<SyncConflict>()),
    );

    const addedHost = Host(
      id: 'host-2',
      name: '新主机',
      address: 'new.example.com',
      username: 'root',
    );
    final added = SyncSnapshot({
      ...started.records,
      'host:host-2': <String, dynamic>{
        'data': addedHost.toJson(),
        'secret': null,
      },
    });
    expect(
      () => incoming.rebaseLocalBookmarks(started: started, current: added),
      throwsA(isA<SyncConflict>()),
    );

    final keyData = const SshUser(
      id: 'user-1',
      name: '运维',
      username: 'deploy',
    ).toJson();
    final withKey = SyncSnapshot({
      ...started.records,
      'key:user-1': <String, dynamic>{
        'data': keyData,
        'secret': _password.toJson(),
      },
    });
    final changedKey = SyncSnapshot({
      ...started.records,
      'key:user-1': <String, dynamic>{
        'data': {...keyData, 'name': '改名'},
        'secret': _password.toJson(),
      },
    });
    expect(
      () =>
          incoming.rebaseLocalBookmarks(started: withKey, current: changedKey),
      throwsA(isA<SyncConflict>()),
    );

    // 本地完全未变时云端改动原样保留。
    expect(
      incoming.rebaseLocalBookmarks(started: started, current: started).records,
      incoming.records,
    );
  });

  test('本地提交持锁期间排队的逐条书签编辑会等待并保留', () async {
    final preferences = _GatedPreferences();
    final repository = HostRepository(
      preferences: preferences,
      secrets: MemoryStore(),
    );
    final config = _config();
    await repository.saveHosts([_host()]);
    await repository.saveCredentials('host-1', _password);
    final baseline = await SyncStorage(repository).capture();
    await repository.preferences.write(
      config.baselineKey,
      await encryptSync(baseline.encode(), config.encryptionPassword),
    );
    final client = _GatedWebDav(config);
    client.content = await encryptSync(
      _snapshot(_host(name: '云端改名')).encode(),
      config.encryptionPassword,
    );
    final sync = CloudSync(repository, clientFactory: (value) => client);
    addTearDown(sync.dispose);
    await sync.saveSettings(config);

    final gate = Completer<void>();
    preferences.hostsGate = gate;
    final syncing = sync.synchronize();
    await preferences.entered.future;

    var queuedStarted = false;
    final queued = _addBookmark(repository, 'host-1', '/srv/queued').then((_) {
      queuedStarted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(queuedStarted, isFalse);
    gate.complete();
    await syncing;
    await queued;
    expect(queuedStarted, isTrue);

    final host = (await repository.loadHosts()).single;
    expect(host.name, '云端改名');
    expect(host.sftpBookmarks, ['/srv/a', '/srv/queued']);
    expect(sync.message, '同步完成');
  });

  test('上传期间的书签编辑提交后仍保留，下一次同步更新云端与基线', () async {
    final repository = memoryRepository();
    final config = _config();
    await repository.saveHosts([_host()]);
    await repository.saveCredentials('host-1', _password);
    final client = _GatedWebDav(config);
    final sync = CloudSync(repository, clientFactory: (value) => client);
    addTearDown(sync.dispose);
    await sync.saveSettings(config);

    final gate = Completer<void>();
    final putStarted = Completer<void>();
    client.putGate = gate;
    client.putStarted = putStarted;
    final syncing = sync.synchronize();
    await putStarted.future;

    // 上传进行中，本地锁空闲：逐条书签写入立即完成，绝不阻塞上传。
    await _addBookmark(repository, 'host-1', '/srv/late');
    gate.complete();
    await syncing;

    expect(client.writes, hasLength(1));
    final uploaded = SyncSnapshot.decode(
      await decryptSync(client.writes.single, config.encryptionPassword),
    );
    expect((uploaded.records['host:host-1']!['data'] as Map)['sftpBookmarks'], [
      '/srv/a',
    ]);
    expect((await repository.loadHosts()).single.sftpBookmarks, [
      '/srv/a',
      '/srv/late',
    ]);
    expect(sync.message, '同步完成');
    // 基线记录的是上传内容，而不是重放后的本地状态。
    expect(
      await repository.preferences.read(config.baselineKey),
      client.writes.single,
    );

    await sync.synchronize();
    final cloud = SyncSnapshot.decode(
      await decryptSync(client.content!, config.encryptionPassword),
    );
    expect((cloud.records['host:host-1']!['data'] as Map)['sftpBookmarks'], [
      '/srv/a',
      '/srv/late',
    ]);
    expect(
      await repository.preferences.read(config.baselineKey),
      client.content,
    );
    expect((await repository.loadHosts()).single.sftpBookmarks, [
      '/srv/a',
      '/srv/late',
    ]);
  });
}

class _GatedPreferences extends MemoryStore {
  Completer<void>? hostsGate;
  final entered = Completer<void>();

  @override
  Future<void> write(String key, String value) async {
    final gate = hostsGate;
    if (key == 'harbor.hosts.v1' && gate != null) {
      hostsGate = null;
      if (!entered.isCompleted) entered.complete();
      await gate.future;
    }
    await super.write(key, value);
  }
}

class _GatedWebDav extends WebDavClient {
  _GatedWebDav(super.settings);
  String? content;
  int revision = 0;
  Completer<void>? putGate;
  Completer<void>? putStarted;
  final writes = <String>[];

  @override
  Future<WebDavResponse> request(
    String method, {
    bool directory = false,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    if (method == 'GET') {
      return content == null
          ? const WebDavResponse(404, '', null)
          : WebDavResponse(200, content!, '"$revision"');
    }
    if (method == 'PUT') {
      final started = putStarted;
      putStarted = null;
      started?.complete();
      final gate = putGate;
      putGate = null;
      if (gate != null) await gate.future;
      content = body;
      revision++;
      writes.add(body!);
      return const WebDavResponse(201, '', null);
    }
    return const WebDavResponse(500, '', null);
  }
}
