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

    final rebased = incoming.rebaseLocalChanges(
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

    final partial = incoming.rebaseLocalChanges(
      started: started,
      current: _snapshot(_host(bookmarks: const [])),
    );
    expect((partial.records['host:host-1']!['data'] as Map)['sftpBookmarks'], [
      '/srv/remote',
    ]);

    final unchanged = _snapshot(_host());
    final emptied = unchanged.rebaseLocalChanges(
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

    final rebased = incoming.rebaseLocalChanges(
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

    final rebased = accepted.rebaseLocalChanges(started: local, current: local);
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
      incomplete.rebaseLocalChanges(started: local, current: local).records,
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
      () => merged.rebaseLocalChanges(
        started: started,
        current: _snapshot(_host(bookmarks: ['/srv/a', '/srv/b'])),
      ),
      throwsA(
        isA<SyncConflict>().having((error) => error.names, 'names', ['开发服务器']),
      ),
    );
  });

  test('并发字段互不相干时各自保留，同字段不同值才冲突', () {
    final started = _snapshot(_host());
    final incoming = _snapshot(_host(name: '云端改名'));

    // 收藏与云端改名互不影响：两边都保留。
    final merged = incoming.rebaseLocalChanges(
      started: started,
      current: _snapshot(_host(favorite: true)),
    );
    final data = merged.records['host:host-1']!['data'] as Map;
    expect(data['name'], '云端改名');
    expect(data['favorite'], isTrue);

    // 同一字段两边都改了：必须由用户选择，不能静默覆盖。
    expect(
      () => incoming.rebaseLocalChanges(
        started: started,
        current: _snapshot(_host(name: '本地改名')),
      ),
      throwsA(isA<SyncConflict>()),
    );

    // 本地完全未变时云端改动原样保留。
    expect(
      incoming.rebaseLocalChanges(started: started, current: started).records,
      incoming.records,
    );
  });

  test('本地改密码与云端改其它字段同时发生时各自保留', () {
    final started = _snapshot(_host());
    final incoming = SyncSnapshot.merge(
      local: started,
      remote: _snapshot(_host(name: '云端改名')),
      base: _snapshot(_host()),
    );
    final merged = incoming.rebaseLocalChanges(
      started: started,
      current: _snapshot(_host(), secret: const Credentials(password: '新密码')),
    );
    final record = merged.records['host:host-1']!;
    expect((record['data'] as Map)['name'], '云端改名');
    expect(record['secret'], const Credentials(password: '新密码').toJson());
  });

  test('认证字段与密码作为整体：两边都改但不同就报冲突', () {
    final started = _snapshot(_host());
    // 云端换了地址和密码。
    final moved = Host.fromJson({..._host().toJson(), 'address': 'other'});
    final incoming = _snapshot(
      moved,
      secret: const Credentials(password: '云端密码'),
    );
    // 本地改了用户名和密码：绝不允许把旧账号套到新地址上。
    final renamed = Host.fromJson({..._host().toJson(), 'username': 'ops'});
    expect(
      () => incoming.rebaseLocalChanges(
        started: started,
        current: _snapshot(
          renamed,
          secret: const Credentials(password: '本地密码'),
        ),
      ),
      throwsA(
        isA<SyncConflict>().having((error) => error.names, 'names', ['开发服务器']),
      ),
    );

    // 云端没碰认证组时，本地的整组认证改动整体生效。
    final merged = _snapshot(_host(name: '云端改名')).rebaseLocalChanges(
      started: started,
      current: _snapshot(_host(), secret: const Credentials(password: '本地密码')),
    );
    final record = merged.records['host:host-1']!;
    expect((record['data'] as Map)['name'], '云端改名');
    expect((record['data'] as Map)['address'], 'dev.example.com');
    expect(record['secret'], const Credentials(password: '本地密码').toJson());
  });

  test('本地新增与删除按记录存在语义生效', () {
    final started = _snapshot(_host());
    const addedHost = Host(
      id: 'host-2',
      name: '云端新增',
      address: 'cloud.example.com',
      username: 'root',
    );
    final incoming = SyncSnapshot({
      ...started.records,
      'host:host-2': <String, dynamic>{
        'data': addedHost.toJson(),
        'secret': null,
      },
    });
    const localHost = Host(
      id: 'host-3',
      name: '本地新增',
      address: 'local.example.com',
      username: 'root',
    );
    final added = SyncSnapshot({
      ...started.records,
      'host:host-3': <String, dynamic>{
        'data': localHost.toJson(),
        'secret': null,
      },
    });

    // 上传期间本地新增的连接写回，云端新增的连接保留。
    final merged = incoming.rebaseLocalChanges(
      started: started,
      current: added,
    );
    expect(merged.records.keys.toSet(), {
      'host:host-1',
      'host:host-2',
      'host:host-3',
    });

    // 本地删除一条云端没动过的记录直接生效。
    expect(
      started
          .rebaseLocalChanges(started: started, current: SyncSnapshot.empty())
          .records,
      isEmpty,
    );

    // 云端改过的记录不能被本地并发删除静默丢弃。
    expect(
      () => _snapshot(_host(name: '云端改名'))
          .rebaseLocalChanges(started: started, current: SyncSnapshot.empty()),
      throwsA(
        isA<SyncConflict>().having((error) => error.names, 'names', ['开发服务器']),
      ),
    );
  });

  test('凭证记录的名称等非认证字段同样按字段合并', () {
    final keyData = const SshUser(
      id: 'user-1',
      name: '运维',
      username: 'deploy',
    ).toJson();
    final withKey = SyncSnapshot({
      'key:user-1': <String, dynamic>{
        'data': keyData,
        'secret': _password.toJson(),
      },
    });
    final changedKey = SyncSnapshot({
      'key:user-1': <String, dynamic>{
        'data': {...keyData, 'name': '改名'},
        'secret': _password.toJson(),
      },
    });
    final merged = withKey.rebaseLocalChanges(
      started: withKey,
      current: changedKey,
    );
    expect((merged.records['key:user-1']!['data'] as Map)['name'], '改名');

    // 认证字段两边都改但不同：冲突。
    final movedKey = SyncSnapshot({
      'key:user-1': <String, dynamic>{
        'data': {...keyData, 'username': 'ops'},
        'secret': _password.toJson(),
      },
    });
    final renamedKey = SyncSnapshot({
      'key:user-1': <String, dynamic>{
        'data': {...keyData, 'name': '改名', 'username': 'root'},
        'secret': _password.toJson(),
      },
    });
    expect(
      () => movedKey.rebaseLocalChanges(started: withKey, current: renamedKey),
      throwsA(isA<SyncConflict>()),
    );
  });

  test('其他记录的并发改动不会重新触发已批准的密码清空冲突', () {
    const otherHost = Host(
      id: 'host-2',
      name: '其他主机',
      address: 'other.example.com',
      username: 'root',
    );
    final started = SyncSnapshot({
      ..._snapshot(_host()).records,
      'host:host-2': <String, dynamic>{
        'data': otherHost.toJson(),
        'secret': null,
      },
    });
    // 用户在冲突面板里选择保留云端已经清空密码的版本。
    final accepted = SyncSnapshot.merge(
      local: started,
      remote: SyncSnapshot({
        'host:host-1': <String, dynamic>{
          'data': _host().toJson(),
          'secret': null,
        },
        'host:host-2': <String, dynamic>{
          'data': otherHost.toJson(),
          'secret': null,
        },
      }),
      base: started,
      choice: SyncConflictChoice.remote,
    );
    expect(accepted.records['host:host-1']!['secret'], isNull);

    // 上传期间只编辑了另一条记录：已批准的清空不能被重新判定为冲突。
    final merged = accepted.rebaseLocalChanges(
      started: started,
      current: SyncSnapshot({
        ...started.records,
        'host:host-2': <String, dynamic>{
          'data': otherHost.withFavorite(true).toJson(),
          'secret': null,
        },
      }),
    );
    expect(merged.records['host:host-1']!['secret'], isNull);
    expect((merged.records['host:host-2']!['data'] as Map)['favorite'], isTrue);
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
