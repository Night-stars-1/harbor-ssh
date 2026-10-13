import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

const _localHost = Host(
  id: 'host-1',
  name: '本地名字',
  address: 'dev.example.com',
  username: 'deploy',
  tags: ['开发'],
);

/// 云端同一主机的名字、地址与标签都与本地基线不同，用于证明合并后远端字段生效。
const _remoteHost = Host(
  id: 'host-1',
  name: '云端名字',
  address: 'cloud.example.com',
  username: 'deploy',
  tags: ['云端'],
);

const _bookmarkedHost = Host(
  id: 'host-1',
  name: '开发服务器',
  address: 'dev.example.com',
  username: 'deploy',
  tags: ['开发'],
  sftpBookmarks: ['/a'],
);

/// 排队期间同步写回磁盘的同一主机：名字、标签与收藏都与原值不同。
const _diskHost = Host(
  id: 'host-1',
  name: '磁盘最新名字',
  address: 'dev.example.com',
  username: 'deploy',
  tags: ['磁盘'],
  favorite: true,
);

void main() {
  test('云同步网络读取阻塞时，书签增删仍在本地完成并落盘', () async {
    final harness = await _startHarness();
    final server = harness.server;
    final model = harness.model;

    server.blockGet();
    final syncing = model.syncNow();
    harness.track(syncing);
    await server.getReached.future;
    expect(model.saving, isTrue, reason: '网络同步进行中界面仍显示保存中');

    final added = model.setSftpBookmark(testHost.id, '/srv/a', saved: true);
    harness.track(added);
    await added.timeout(const Duration(seconds: 30));
    expect(server.getBlocked, isTrue, reason: '本地新增完成时网络读取仍被阻塞');
    expect(model.hosts.single.sftpBookmarks, ['/srv/a']);
    expect((await harness.repository.loadHosts()).single.sftpBookmarks, [
      '/srv/a',
    ]);

    final removed = model.setSftpBookmark(testHost.id, '/srv/a', saved: false);
    harness.track(removed);
    await removed.timeout(const Duration(seconds: 30));
    expect(server.getBlocked, isTrue, reason: '本地删除完成时网络读取仍被阻塞');
    expect(model.hosts.single.sftpBookmarks, isEmpty);
    expect(
      (await harness.repository.loadHosts()).single.sftpBookmarks,
      isEmpty,
    );

    server.releaseGet();
    await syncing.timeout(const Duration(seconds: 30));
    expect(model.saving, isFalse);
    expect(
      (await harness.repository.loadHosts()).single.sftpBookmarks,
      isEmpty,
    );
    expect(model.hosts.single.sftpBookmarks, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('云端返回保留远端主机字段与并发的本地书签', () async {
    final harness = await _startHarness(hosts: const [_localHost]);
    final server = harness.server;
    final model = harness.model;
    final settings = harness.settings;

    final base = SyncSnapshot({
      'host:${_localHost.id}': {'data': _localHost.toJson(), 'secret': null},
    });
    await harness.repository.preferences.write(
      settings.baselineKey,
      await encryptSync(base.encode(), settings.encryptionPassword),
    );
    final remote = SyncSnapshot({
      'host:${_remoteHost.id}': {'data': _remoteHost.toJson(), 'secret': null},
    });
    server.content = await encryptSync(
      remote.encode(),
      settings.encryptionPassword,
    );

    server.blockGet();
    final syncing = model.syncNow();
    harness.track(syncing);
    await server.getReached.future;

    final added = model.setSftpBookmark(_localHost.id, '/srv/new', saved: true);
    harness.track(added);
    await added.timeout(const Duration(seconds: 30));
    expect(server.getBlocked, isTrue, reason: '本地新增完成时网络读取仍被阻塞');
    expect((await harness.repository.loadHosts()).single.sftpBookmarks, [
      '/srv/new',
    ]);

    server.releaseGet();
    await syncing.timeout(const Duration(seconds: 30));

    final saved = (await harness.repository.loadHosts()).single;
    expect(saved.name, _remoteHost.name);
    expect(saved.address, _remoteHost.address);
    expect(saved.tags, _remoteHost.tags);
    expect(saved.sftpBookmarks, ['/srv/new']);
    expect(model.hosts.single.name, _remoteHost.name);
    expect(model.hosts.single.tags, _remoteHost.tags);
    expect(model.hosts.single.sftpBookmarks, ['/srv/new']);
    expect(model.saving, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('上传期间到达的本地书签改动不被同步覆盖，并由下一次同步发布', () async {
    final harness = await _startHarness(hosts: const [_bookmarkedHost]);
    final server = harness.server;
    final model = harness.model;
    final settings = harness.settings;

    server.blockPut();
    final syncing = model.syncNow();
    harness.track(syncing);
    await server.putReached.future;

    final late = model.setSftpBookmark(
      _bookmarkedHost.id,
      '/late',
      saved: true,
    );
    harness.track(late);
    await late.timeout(const Duration(seconds: 30));
    expect(server.putBlocked, isTrue, reason: '本地新增完成时网络上传仍被阻塞');
    expect(model.hosts.single.sftpBookmarks, ['/a', '/late']);
    expect((await harness.repository.loadHosts()).single.sftpBookmarks, [
      '/a',
      '/late',
    ]);

    server.releasePut();
    await syncing.timeout(const Duration(seconds: 30));
    expect(model.saving, isFalse);
    expect((await harness.repository.loadHosts()).single.sftpBookmarks, [
      '/a',
      '/late',
    ]);
    expect(model.hosts.single.sftpBookmarks, ['/a', '/late']);
    expect(await _publishedBookmarks(server, settings), [
      '/a',
    ], reason: '本次上传携带的是改动前的快照，迟到的本地改动尚未发布');

    await model.syncNow();
    expect(await _publishedBookmarks(server, settings), ['/a', '/late']);
    expect((await harness.repository.loadHosts()).single.sftpBookmarks, [
      '/a',
      '/late',
    ]);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('网络失败时保留已经成功的本地书签删除', () async {
    final harness = await _startHarness(hosts: const [_bookmarkedHost]);
    final server = harness.server;
    final model = harness.model;

    server.blockGet();
    final syncing = model.syncNow();
    harness.track(syncing);
    await server.getReached.future;

    final removed = model.setSftpBookmark(
      _bookmarkedHost.id,
      '/a',
      saved: false,
    );
    harness.track(removed);
    await removed.timeout(const Duration(seconds: 30));
    expect(model.hosts.single.sftpBookmarks, isEmpty);
    expect(
      (await harness.repository.loadHosts()).single.sftpBookmarks,
      isEmpty,
    );

    // 同步仍停在网络读取上；此时断开连接就是一次真实的网络失败。
    await server.close();
    await expectLater(syncing, throwsA(isA<SyncFailure>()));
    expect(model.saving, isFalse);
    expect(model.hosts.single.sftpBookmarks, isEmpty);
    expect(
      (await harness.repository.loadHosts()).single.sftpBookmarks,
      isEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('排队等待本地提交时，书签写入基于磁盘最新主机数据', () async {
    final harness = await _startLocalHarness();
    final store = harness.store;
    final repository = harness.repository;
    final model = harness.model;

    store.gateKey = 'harbor.users.v1';
    store.gate = Completer<void>();
    final user = model.saveUser(
      const SshUser(id: 'user-1', name: '运维', username: 'ops'),
      null,
    );
    harness.track(user);
    await store.entered.future;

    final bookmark = model.setSftpBookmark(testHost.id, '/srv/a', saved: true);
    harness.track(bookmark);
    await Future<void>.delayed(Duration.zero);

    // 排队期间同步把云端字段写回磁盘：书签写入必须基于这份最新数据。
    await repository.saveHosts([_diskHost]);

    store.gate!.complete();
    store.gate = null;
    await user;
    await bookmark;

    final saved = (await repository.loadHosts()).single;
    expect(saved.name, _diskHost.name);
    expect(saved.tags, _diskHost.tags);
    expect(saved.favorite, isTrue);
    expect(saved.sftpBookmarks, ['/srv/a']);
    expect(model.hosts.single.sftpBookmarks, ['/srv/a']);
    expect(model.saving, isFalse);
  });

  test('排队等待本地提交期间主机被云端删除，书签写入明确失败且不改动磁盘', () async {
    final harness = await _startLocalHarness();
    final store = harness.store;
    final repository = harness.repository;
    final model = harness.model;

    store.gateKey = 'harbor.users.v1';
    store.gate = Completer<void>();
    final user = model.saveUser(
      const SshUser(id: 'user-1', name: '运维', username: 'ops'),
      null,
    );
    harness.track(user);
    await store.entered.future;

    final bookmark = model.setSftpBookmark(testHost.id, '/srv/a', saved: true);
    harness.track(bookmark);
    await Future<void>.delayed(Duration.zero);

    // 同步的本地提交把云端删除结果写回磁盘：主机已不存在。
    await repository.saveHosts(const []);

    store.gate!.complete();
    store.gate = null;
    await user;
    await expectLater(bookmark, throwsA(isA<StateError>()));
    expect(await repository.loadHosts(), isEmpty);
    expect(model.saving, isFalse);
  });
}

/// 只靠本地存储的用例：把一次本地提交停在中途，验证排队中的书签写入。
Future<_LocalHarness> _startLocalHarness() async {
  final store = _KeyedGateStore();
  final repository = HostRepository(preferences: store, secrets: MemoryStore());
  await repository.saveHosts([testHost]);
  final model = WorkspaceModel(repository);
  final harness = _LocalHarness(store, repository, model);
  // 逆序执行：先放行并等待操作，再释放模型。
  addTearDown(model.dispose);
  addTearDown(harness.drainPending);
  await model.initialize();
  return harness;
}

class _LocalHarness {
  _LocalHarness(this.store, this.repository, this.model);

  final _KeyedGateStore store;
  final HostRepository repository;
  final WorkspaceModel model;
  final List<Future<void>> _pending = [];

  /// 让清理阶段也能等到这次操作结束（断言失败时同样如此）。
  void track(Future<void> future) {
    _pending.add(future.then<void>((_) {}, onError: (Object _) {}));
  }

  Future<void> drainPending() async {
    final gate = store.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    for (final future in _pending) {
      await future.timeout(const Duration(seconds: 30));
    }
  }
}

Future<List<String>> _publishedBookmarks(
  _WebDavServer server,
  CloudSyncConfig settings,
) async {
  final content = server.content;
  if (content == null) return const [];
  final snapshot = SyncSnapshot.decode(
    await decryptSync(content, settings.encryptionPassword),
  );
  final record = snapshot.records['host:${_bookmarkedHost.id}'];
  if (record == null) return const [];
  return Host.fromJson(Map<String, dynamic>.from(record['data'] as Map))
      .sftpBookmarks;
}

class _Harness {
  _Harness({
    required this.server,
    required this.repository,
    required this.model,
    required this.settings,
  });

  final _WebDavServer server;
  final HostRepository repository;
  final WorkspaceModel model;
  final CloudSyncConfig settings;
  final List<Future<void>> _pending = [];

  /// 让清理阶段也能等到这次操作结束（断言失败时同样如此）。
  void track(Future<void> future) {
    _pending.add(future.then<void>((_) {}, onError: (Object _) {}));
  }

  Future<void> drainPending() async {
    server.releaseAll();
    for (final future in _pending) {
      await future.timeout(const Duration(seconds: 30));
    }
  }
}

Future<_Harness> _startHarness({List<Host> hosts = const [testHost]}) async {
  final server = await _WebDavServer.start();
  addTearDown(server.close);
  final repository = memoryRepository();
  await repository.saveHosts(hosts);
  final model = WorkspaceModel(repository);
  final harness = _Harness(
    server: server,
    repository: repository,
    model: model,
    settings: WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: 'shared-test-encryption-password',
    ),
  );
  // 逆序执行：先放行并等待操作，再释放模型，最后关闭服务器。
  addTearDown(model.dispose);
  addTearDown(harness.drainPending);
  await model.initialize();
  await model.cloudSync.saveSettings(harness.settings);
  return harness;
}

/// 真实回环 WebDAV 服务器：GET/PUT 各有一道确定性闸门，PUT 校验 ETag 条件头。
class _WebDavServer {
  _WebDavServer._(this._server);

  static Future<_WebDavServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _WebDavServer._(server);
    server.listen(instance._handle, onError: (Object _) {});
    return instance;
  }

  final HttpServer _server;
  int get port => _server.port;

  /// 加密后的云端文件；null 表示尚未创建（GET 返回 404）。
  String? content;
  int revision = 0;

  Completer<void>? _getGate;
  Completer<void>? _putGate;
  final getReached = Completer<void>();
  final putReached = Completer<void>();

  bool get getBlocked => _getGate != null && !_getGate!.isCompleted;
  bool get putBlocked => _putGate != null && !_putGate!.isCompleted;

  void blockGet() => _getGate = Completer<void>();
  void blockPut() => _putGate = Completer<void>();
  void releaseGet() => _release(_getGate);
  void releasePut() => _release(_putGate);

  void releaseAll() {
    _release(_getGate);
    _release(_putGate);
  }

  static void _release(Completer<void>? gate) {
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET') {
        if (!getReached.isCompleted) getReached.complete();
        await _getGate?.future;
        final body = content;
        if (body == null) {
          request.response.statusCode = 404;
        } else {
          request.response.statusCode = 200;
          request.response.headers.set('ETag', '"$revision"');
          request.response.write(body);
        }
      } else if (request.method == 'PUT') {
        final incoming = await utf8.decoder.bind(request).join();
        if (!putReached.isCompleted) putReached.complete();
        await _putGate?.future;
        final expected = content == null ? '*' : '"$revision"';
        final actual = content == null
            ? request.headers.value('if-none-match')
            : request.headers.value('if-match');
        if (actual != expected) {
          request.response.statusCode = 412;
        } else {
          content = incoming;
          revision++;
          request.response.statusCode = 201;
        }
      } else {
        request.response.statusCode = 207;
      }
      await request.response.close();
    } catch (_) {
      // 服务器可能在断言失败后被拆掉；吞掉以免污染测试输出。
    }
  }
}

/// 只拦截指定键的本地写入，用于把一次本地提交停在中途。
class _KeyedGateStore extends MemoryStore {
  String? gateKey;
  Completer<void>? gate;
  final entered = Completer<void>();

  @override
  Future<void> write(String key, String value) async {
    if (key == gateKey && gate != null) {
      if (!entered.isCompleted) entered.complete();
      await gate!.future;
    }
    await super.write(key, value);
  }
}
