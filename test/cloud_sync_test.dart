import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/gist_sync.dart';
import 'package:harbor_ssh/data/github_device_auth.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/network_identity.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

SyncSnapshot snapshot(String? name, {bool favorite = false}) => SyncSnapshot({
  if (name != null)
    'host:host-1': {
      'data': {...testHost.toJson(), 'name': name, 'favorite': favorite},
      'secret': const Credentials(password: 'ssh-password').toJson(),
    },
});

const _officeIdentity = NetworkIdentity(
  id: 'identity-office',
  name: '公司内网',
  overrides: {'host-1': EndpointOverride(address: '10.0.0.5', port: 2222)},
);

const _homeIdentity = NetworkIdentity(
  id: 'identity-home',
  name: '家里直连',
  overrides: {'host-1': EndpointOverride(address: '192.168.10.88', port: 2222)},
);

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

  test('本机 AI 历史不进入云同步快照或明文偏好设置', () async {
    final root = await Directory.systemTemp.createTemp(
      'harbor-local-ai-history-',
    );
    addTearDown(() => root.delete(recursive: true));
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final store = AiConversationStore(
      secrets: repository.secrets,
      directory: () async => root,
    );
    const scope = 'host-1|dev.example.com:22|deploy';
    final now = DateTime(2026);
    await store.save(
      AiConversation(
        id: 'local-chat',
        scope: scope,
        title: '本机敏感对话',
        model: 'test',
        createdAt: now,
        updatedAt: now,
        entries: [
          {'text': '私有输出标记-仅本机', 'user': true},
        ],
        history: [
          {'role': 'user', 'content': '私有输出标记-仅本机'},
        ],
      ),
    );
    final snapshot = await SyncStorage(repository).capture();
    expect(snapshot.records.keys, ['host:${testHost.id}']);
    expect(snapshot.encode(), isNot(contains('私有输出标记-仅本机')));
    expect(snapshot.encode(), isNot(contains('本机敏感对话')));
    expect(
      (repository.preferences as MemoryStore).values.values.join(),
      isNot(contains('私有输出标记-仅本机')),
    );
    expect((await store.load(scope, 'local-chat'))?.title, '本机敏感对话');
  });

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

  test('设备流令牌过期前自动轮换，新令牌用于 Gist 读写并在重启后保留', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final firstExpiry = start.add(const Duration(hours: 8));
    final refreshExpiry = start.add(const Duration(days: 30));
    final server = _GistServer()..exists = false;
    final auth = _FakeAuth()
      ..results.addAll([
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: firstExpiry,
          refreshExpiresAt: refreshExpiry,
        ),
        GitHubRenewal(
          token: 'access-3',
          refreshToken: 'refresh-3',
          expiresAt: firstExpiry,
          refreshExpiresAt: refreshExpiry,
        ),
      ]);
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        gistId: '',
        refreshToken: 'refresh-1',
        expiresAt: start.add(const Duration(minutes: 1)),
      ),
    );

    await sync.synchronize();

    expect(auth.calls, ['refresh-1']);
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(sync.settings!.expiresAt, firstExpiry);
    expect(sync.settings!.gistId, _gistId);
    expect(server.requests, contains('POST gists'));
    expect(server.tokens, everyElement('access-2'));
    expect(
      (jsonDecode(secrets.values['harbor.sync.settings.v1']!)
          as Map<String, dynamic>)['refreshToken'],
      'refresh-2',
    );

    // 第二个过期周期使用轮换后的刷新令牌，写入时也带着新的访问令牌。
    await repository.saveHosts([testHost.withFavorite(true)]);
    clock.value = start.add(const Duration(hours: 9));
    final cycleStart = server.tokens.length;
    await sync.synchronize();
    expect(auth.calls, ['refresh-1', 'refresh-2']);
    expect(server.tokens.sublist(cycleStart), everyElement('access-3'));
    final patched = server.requests.indexOf('PATCH gists/$_gistId');
    expect(patched, isNonNegative);
    expect(server.tokens[patched], 'access-3');
    expect(sync.settings!.refreshToken, 'refresh-3');

    final revived = CloudSync(repository);
    addTearDown(revived.dispose);
    await revived.initialize();
    expect(revived.settings!.token, 'access-3');
    expect(revived.settings!.refreshToken, 'refresh-3');
    expect(revived.settings!.githubLogin.toLowerCase(), 'alice');
    expect(revived.settings!.expiresAt, firstExpiry);
    expect(revived.settings!.refreshExpiresAt, refreshExpiry);
    expect(revived.settings!.gistId, _gistId);
    expect(revived.settings!.automatic, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('刷新失败或账号不符时不访问 Gist，凭据与本地数据保持不变', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    final remote = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    server.content = remote;
    final auth = _FakeAuth()
      ..results.add(const SyncFailure('bad_refresh_token'));
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );
    final storedBefore = secrets.values['harbor.sync.settings.v1'];
    final localBefore = (await SyncStorage(repository).capture()).encode();

    await expectLater(sync.synchronize(), throwsA(isA<SyncFailure>()));
    expect(sync.message, contains('重新登录'));
    expect(sync.failed, isTrue);
    expect(sync.lastSync, isNull);
    expect(server.requests, isEmpty);
    expect(server.content, remote);
    expect(secrets.values['harbor.sync.settings.v1'], storedBefore);
    expect((await SyncStorage(repository).capture()).encode(), localBefore);
    expect(sync.settings!.token, 'access-1');
    expect(sync.settings!.refreshToken, 'refresh-1');
    expect(
      sync.settings!.expiresAt,
      start.subtract(const Duration(minutes: 5)),
    );
    expect(sync.settings!.gistId, _gistId);
    expect(sync.settings!.automatic, isTrue);

    // 测试连接同样先刷新，失败时不会再去访问 GitHub。
    auth.results.add(const SyncFailure('bad_refresh_token'));
    await expectLater(
      sync.testConnection(sync.settings!),
      throwsA(isA<SyncFailure>()),
    );
    expect(server.requests, isEmpty);
    expect(secrets.values['harbor.sync.settings.v1'], storedBefore);

    // 轮换成功但资料接口返回其他账号时停止：新凭据已先落盘，远端没有任何写入。
    auth.results.add(
      GitHubRenewal(
        token: 'access-9',
        refreshToken: 'refresh-9',
        expiresAt: start.add(const Duration(hours: 8)),
        refreshExpiresAt: start.add(const Duration(days: 30)),
      ),
    );
    server.login = 'bob';
    await expectLater(sync.synchronize(), throwsA(isA<SyncFailure>()));
    expect(auth.calls, ['refresh-1', 'refresh-1', 'refresh-1']);
    expect(sync.settings!.token, 'access-9');
    expect(sync.settings!.refreshToken, 'refresh-9');
    expect(sync.settings!.githubLogin, 'alice');
    expect(server.writes, 0);
    expect(server.content, remote);
    expect((await SyncStorage(repository).capture()).encode(), localBefore);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('旧凭据没有刷新令牌时继续直接同步，401 后要求重新登录且不清除数据', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth();
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(_gistSettings(token: 'legacy-token'));

    await sync.synchronize();

    expect(auth.calls, isEmpty);
    expect(server.tokens, isNotEmpty);
    expect(server.tokens, everyElement('legacy-token'));
    expect(server.writes, 1);
    final storedBefore = secrets.values['harbor.sync.settings.v1'];
    final localBefore = (await SyncStorage(repository).capture()).encode();

    server.userStatus = 401;
    await expectLater(sync.synchronize(), throwsA(isA<SyncFailure>()));
    expect(sync.message, contains('重新登录'));
    expect(server.writes, 1);
    expect(auth.calls, isEmpty);
    expect(secrets.values['harbor.sync.settings.v1'], storedBefore);
    expect((await SyncStorage(repository).capture()).encode(), localBefore);
    expect(sync.settings!.token, 'legacy-token');
    expect(sync.settings!.refreshToken, isEmpty);
    expect(sync.settings!.githubLogin, 'alice');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('尚有余量时沿用当前令牌，过期时间未知时必须刷新', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final rotated = GitHubRenewal(
      token: 'access-2',
      refreshToken: 'refresh-2',
      expiresAt: start.add(const Duration(hours: 8)),
      refreshExpiresAt: start.add(const Duration(days: 30)),
    );
    final server = _GistServer()..exists = false;
    final auth = _FakeAuth()..results.add(rotated);
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        gistId: '',
        refreshToken: 'refresh-1',
        expiresAt: start.add(const Duration(minutes: 10)),
      ),
    );

    await sync.synchronize();

    expect(auth.calls, isEmpty);
    expect(server.tokens, everyElement('access-1'));
    expect(server.requests, contains('POST gists'));

    // 过期时间未知的设备流凭据（例如更早版本写入的设置）无法排除已经失效。
    await secrets.write(
      'harbor.sync.settings.v1',
      jsonEncode(
        _gistSettings(token: 'access-1', refreshToken: 'refresh-1').toJson(),
      ),
    );
    final unknown = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(unknown.dispose);
    await unknown.initialize();
    expect(unknown.settings!.expiresAt, isNull);
    expect(unknown.settings!.refreshToken, 'refresh-1');
    final cycleStart = server.tokens.length;

    await unknown.synchronize();

    expect(auth.calls, ['refresh-1']);
    expect(unknown.settings!.token, 'access-2');
    expect(unknown.settings!.refreshToken, 'refresh-2');
    expect(unknown.settings!.expiresAt, start.add(const Duration(hours: 8)));
    expect(server.tokens.sublist(cycleStart), everyElement('access-2'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('测试连接与自动同步并发时只消耗一次刷新令牌', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth()
      ..gate = Completer<void>()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    final testing = sync.testConnection(sync.settings!);
    final syncing = sync.synchronize();
    expect(auth.calls, ['refresh-1']);

    auth.gate!.complete();
    await testing;
    await syncing;

    expect(auth.calls, ['refresh-1']);
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(server.tokens, everyElement('access-2'));
    expect(server.writes, 1);
    expect(
      (jsonDecode(secrets.values['harbor.sync.settings.v1']!)
          as Map<String, dynamic>)['refreshToken'],
      'refresh-2',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('交换期间换了账号时丢弃过期结果，不覆盖新登录', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    final auth = _FakeAuth()
      ..gate = Completer<void>()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    final testing = sync.testConnection(sync.settings!);
    await sync.saveGitHubAccount('bob-token', 'bob');
    final storedBefore = secrets.values['harbor.sync.settings.v1'];

    auth.gate!.complete();
    await expectLater(testing, throwsA(isA<SyncFailure>()));

    expect(sync.settings!.token, 'bob-token');
    expect(sync.settings!.refreshToken, isEmpty);
    expect(secrets.values['harbor.sync.settings.v1'], storedBefore);
    expect(server.requests, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('后台轮换后旧表单快照仍用最新凭据测试，并保留表单里的存档地址', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer()..exists = false;
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        gistId: '',
        refreshToken: 'refresh-1',
        expiresAt: start.add(const Duration(minutes: 1)),
      ),
    );

    // 后台同步把令牌轮换成 access-2，表单仍拿着轮换前的快照。
    await sync.synchronize();
    expect(auth.calls, ['refresh-1']);
    final stale = _gistSettings(
      gistId: 'abcdefabcdef',
      token: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: start.add(const Duration(minutes: 1)),
    );
    final tested = server.tokens.length;

    await sync.testConnection(stale);

    expect(auth.calls, ['refresh-1']);
    expect(server.tokens.sublist(tested), everyElement('access-2'));
    expect(server.requests.sublist(tested), contains('GET gists/abcdefabcdef'));
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(sync.settings!.gistId, _gistId);
    expect(
      (jsonDecode(secrets.values['harbor.sync.settings.v1']!)
          as Map<String, dynamic>)['token'],
      'access-2',
    );
    // 测试之后保存旧表单，只修改表单字段，不能把已失效的令牌写回去。
    await sync.saveSettings(stale);
    final saved = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(saved['gistId'], 'abcdefabcdef');
    expect(saved['token'], 'access-2');
    expect(saved['refreshToken'], 'refresh-2');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('测试连接刷新令牌时不会写入表单里未保存的存档地址与选项', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer()..content = 'sealed';
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.add(const Duration(minutes: 1)),
      ),
    );
    final form = CloudSyncConfig(
      provider: SyncProvider.gist,
      gistId: 'abcdefabcdef',
      token: 'access-1',
      githubLogin: 'alice',
      refreshToken: 'refresh-1',
      expiresAt: start.add(const Duration(minutes: 1)),
      refreshExpiresAt: start.add(const Duration(days: 30)),
      encryptionPassword: 'form-encryption-password',
      automatic: false,
    );
    final tested = server.requests.length;

    await sync.testConnection(form);

    // 过期令牌被轮换，但只写入已保存账号自己的字段。
    expect(auth.calls, ['refresh-1']);
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['token'], 'access-2');
    expect(stored['refreshToken'], 'refresh-2');
    expect(stored['gistId'], _gistId);
    expect(stored['encryptionPassword'], 'shared-password');
    expect(stored['automatic'], isTrue);
    expect(sync.settings!.gistId, _gistId);
    expect(sync.settings!.automatic, isTrue);
    // 表单里改过的地址只用于这次连接检查，用的是轮换后的令牌。
    expect(server.requests.sublist(tested), contains('GET gists/abcdefabcdef'));
    expect(server.tokens.sublist(tested), everyElement('access-2'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('保存轮换凭据期间同一刷新令牌不会被再次消耗', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final secrets = _SlowSecretStore();
    final repository = HostRepository(
      preferences: MemoryStore(),
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    secrets.writes.clear();
    final gate = Completer<void>();
    secrets.gate = gate;
    final syncing = sync.synchronize();
    await Future<void>.delayed(Duration.zero);

    // 新令牌已换回，但新凭据还在写入安全存储：此时仍在同一次轮换里。
    expect(auth.calls, ['refresh-1']);
    expect(secrets.writes, ['harbor.sync.settings.v1']);
    expect(sync.settings!.token, 'access-1');
    expect(
      (jsonDecode(secrets.values['harbor.sync.settings.v1']!)
          as Map<String, dynamic>)['token'],
      'access-1',
    );
    final testing = sync.testConnection(sync.settings!);
    await Future<void>.delayed(Duration.zero);
    expect(auth.calls, ['refresh-1']);

    gate.complete();
    await syncing;
    await testing;

    expect(auth.calls, ['refresh-1']);
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(server.tokens, everyElement('access-2'));
    expect(server.writes, 1);
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['token'], 'access-2');
    expect(stored['refreshToken'], 'refresh-2');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('轮换凭据写入期间退出登录不会被作废的账号覆盖', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final secrets = _SlowSecretStore();
    final repository = HostRepository(
      preferences: MemoryStore(),
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    secrets.writes.clear();
    final gate = Completer<void>();
    secrets.gate = gate;
    final testing = sync.testConnection(sync.settings!);
    await Future<void>.delayed(Duration.zero);
    expect(secrets.writes, ['harbor.sync.settings.v1']);

    // 轮换还在写安全存储时退出登录：退出排在轮换之后，旧账号不会被复活。
    final logout = sync.saveGitHubAccount('', '');
    await Future<void>.delayed(Duration.zero);
    expect(secrets.writes, ['harbor.sync.settings.v1']);

    gate.complete();
    await testing;
    await logout;

    expect(sync.settings!.token, isEmpty);
    expect(sync.settings!.refreshToken, isEmpty);
    expect(sync.settings!.githubLogin, isEmpty);
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['token'], isEmpty);
    expect(stored['refreshToken'], isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('交换期间同账号重新登录时保留用户选择的新凭据', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    final auth = _FakeAuth()
      ..gate = Completer<void>()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    final testing = sync.testConnection(sync.settings!);
    final failed = expectLater(
      testing,
      throwsA(
        isA<SyncFailure>().having(
          (error) => error.message,
          'message',
          contains('登录状态已更新'),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(auth.calls, ['refresh-1']);
    await sync.saveGitHubAccount('manual-access', 'alice');
    auth.gate!.complete();
    await failed;

    expect(sync.settings!.token, 'manual-access');
    expect(sync.settings!.refreshToken, isEmpty);
    expect(server.requests, isEmpty);
    await sync.saveSettings(
      _gistSettings(
        token: 'access-1',
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );
    expect(sync.settings!.token, 'manual-access');
    expect(sync.settings!.refreshToken, isEmpty);
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['token'], 'manual-access');
    expect(stored['refreshToken'], isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('交换期间切换到 WebDAV 仍保存新凭据，并丢弃过期的 Gist 操作', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth()
      ..gate = Completer<void>()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    final testing = sync.testConnection(sync.settings!);
    await Future<void>.delayed(Duration.zero);
    // 设置窗口在轮换期间切换到 WebDAV，表单仍带着同一账号的元数据。
    await sync.saveSettings(
      CloudSyncConfig(
        url: 'https://dav.example.com/sync/',
        username: 'test',
        password: 'app-password',
        encryptionPassword: 'shared-password',
        token: 'access-1',
        githubLogin: 'alice',
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
        refreshExpiresAt: start.add(const Duration(days: 30)),
      ),
    );
    expect(sync.settings!.provider, SyncProvider.webdav);

    auth.gate!.complete();
    await expectLater(testing, throwsA(isA<SyncFailure>()));

    // 已经换回的新凭据保存在当前的 WebDAV 设置里，Gist 请求一个都没有发出。
    expect(server.requests, isEmpty);
    expect(sync.settings!.provider, SyncProvider.webdav);
    expect(sync.settings!.url, 'https://dav.example.com/sync/');
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['provider'], 'webdav');
    expect(stored['token'], 'access-2');
    expect(stored['refreshToken'], 'refresh-2');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('已保存的 WebDAV 设置里保留的 GitHub 账号在 Gist 测试时刷新，WebDAV 同步不刷新', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = CloudSync(
      repository,
      clientFactory: (config) => _FakeWebDav(config),
      gistClientFactory: (config) => _SyncGist(config, server),
      githubAuthFactory: () => auth,
      now: () => clock.value,
    );
    addTearDown(sync.dispose);
    await sync.saveSettings(
      CloudSyncConfig(
        url: 'https://dav.example.com/sync/',
        username: 'test',
        password: 'app-password',
        encryptionPassword: 'shared-password',
        token: 'access-1',
        githubLogin: 'alice',
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
        refreshExpiresAt: start.add(const Duration(days: 30)),
      ),
    );

    // 表单切到 Gist 测试：使用刷新后的令牌，保存的设置仍然是 WebDAV。
    await sync.testConnection(
      _gistSettings(
        token: 'access-1',
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );
    expect(auth.calls, ['refresh-1']);
    expect(server.tokens, isNotEmpty);
    expect(server.tokens, everyElement('access-2'));
    expect(sync.settings!.provider, SyncProvider.webdav);
    expect(sync.settings!.url, 'https://dav.example.com/sync/');
    expect(sync.settings!.encryptionPassword, 'shared-password');
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(
      (jsonDecode(secrets.values['harbor.sync.settings.v1']!)
          as Map<String, dynamic>)['provider'],
      'webdav',
    );

    // WebDAV 同步不使用 GitHub 凭据，也不会顺手把它刷新掉。
    clock.value = start.add(const Duration(hours: 9));
    await sync.synchronize();
    expect(auth.calls, ['refresh-1']);
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.provider, SyncProvider.webdav);
    expect(sync.lastSync, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('切换同步方式后保存表单不会写回已作废的刷新令牌', () async {
    final (:repository, :secrets) = _gistRepository();
    final sync = CloudSync(repository);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        token: 'access-2',
        refreshToken: 'refresh-2',
        expiresAt: DateTime.utc(2026, 9, 24, 17),
      ),
    );

    await sync.saveSettings(
      CloudSyncConfig(
        url: 'https://dav.example.com/sync/',
        username: 'test',
        password: 'app-password',
        encryptionPassword: 'shared-password',
        token: 'access-1',
        githubLogin: 'alice',
        refreshToken: 'refresh-1',
        expiresAt: DateTime.utc(2026, 9, 24, 10),
      ),
    );

    expect(sync.settings!.provider, SyncProvider.webdav);
    expect(sync.settings!.url, 'https://dav.example.com/sync/');
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(sync.settings!.expiresAt, DateTime.utc(2026, 9, 24, 17));
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['provider'], 'webdav');
    expect(stored['token'], 'access-2');
    expect(stored['refreshToken'], 'refresh-2');
  });

  test('排队中的保存不会在同步期间改写设置', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer();
    server.content = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final secrets = _SlowSecretStore();
    final repository = HostRepository(
      preferences: MemoryStore(),
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );

    final gate = Completer<void>();
    secrets.gate = gate;
    final testing = sync.testConnection(sync.settings!);
    await Future<void>.delayed(Duration.zero);
    final saving = sync.saveSettings(
      CloudSyncConfig(
        provider: SyncProvider.gist,
        gistId: _gistId,
        token: 'access-1',
        githubLogin: 'alice',
        refreshToken: 'refresh-1',
        expiresAt: start.add(const Duration(minutes: 1)),
        refreshExpiresAt: start.add(const Duration(days: 30)),
        encryptionPassword: 'form-encryption-password',
        automatic: false,
      ),
    );
    final syncing = sync.synchronize();

    gate.complete();
    await expectLater(saving, throwsA(isA<SyncFailure>()));
    await testing;
    await syncing;

    // 同步使用的是轮换后的凭据，排队中的表单没有被写入。
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    expect(sync.settings!.encryptionPassword, 'shared-password');
    expect(sync.settings!.automatic, isTrue);
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['encryptionPassword'], 'shared-password');
    expect(stored['token'], 'access-2');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('轮换后的新凭据先落盘，资料请求临时失败后重试不再刷新即可同步', () async {
    final start = DateTime.utc(2026, 9, 24, 9);
    final clock = _Clock(start);
    final server = _GistServer()..userStatus = 500;
    final remote = await encryptSync(
      SyncSnapshot.empty().encode(),
      'shared-password',
    );
    server.content = remote;
    final auth = _FakeAuth()
      ..results.add(
        GitHubRenewal(
          token: 'access-2',
          refreshToken: 'refresh-2',
          expiresAt: start.add(const Duration(hours: 8)),
          refreshExpiresAt: start.add(const Duration(days: 30)),
        ),
      );
    final (:repository, :secrets) = _gistRepository();
    await repository.saveHosts([testHost]);
    final sync = _gistSync(repository, server, auth, () => clock.value);
    addTearDown(sync.dispose);
    await sync.saveSettings(
      _gistSettings(
        refreshToken: 'refresh-1',
        expiresAt: start.subtract(const Duration(minutes: 5)),
      ),
    );
    final localBefore = (await SyncStorage(repository).capture()).encode();

    await expectLater(sync.synchronize(), throwsA(isA<SyncFailure>()));

    // 轮换后的凭据在任何后续 API 请求之前就已写入安全存储。
    expect(auth.calls, ['refresh-1']);
    expect(sync.settings!.token, 'access-2');
    expect(sync.settings!.refreshToken, 'refresh-2');
    final stored = jsonDecode(
      secrets.values['harbor.sync.settings.v1']!,
    ) as Map<String, dynamic>;
    expect(stored['token'], 'access-2');
    expect(stored['refreshToken'], 'refresh-2');
    expect(server.requests, ['GET user']);
    expect(server.tokens, ['access-2']);
    expect(server.writes, 0);
    expect(server.content, remote);
    expect((await SyncStorage(repository).capture()).encode(), localBefore);

    // 重试直接使用已保存的新令牌，不再消耗刷新令牌，并完成同步。
    server.userStatus = 200;
    final retried = server.tokens.length;
    await sync.synchronize();
    expect(auth.calls, ['refresh-1']);
    expect(server.tokens.sublist(retried), everyElement('access-2'));
    expect(server.writes, 1);
    expect(sync.lastSync, isNotNull);
    expect(sync.settings!.refreshToken, 'refresh-2');

    // 再次测试连接同样沿用新令牌。
    final tested = server.tokens.length;
    await sync.testConnection(sync.settings!);
    expect(auth.calls, ['refresh-1']);
    expect(server.tokens.sublist(tested), everyElement('access-2'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('设备流刷新凭据写入安全存储并可跨启动恢复，普通登录清除刷新元数据', () async {
    final (:repository, :secrets) = _gistRepository();
    final sync = CloudSync(repository);
    addTearDown(sync.dispose);
    final expires = DateTime.utc(2026, 9, 24, 17);
    final refreshExpires = DateTime.utc(2027, 3, 24, 17);
    await sync.saveSettings(_gistSettings(token: 'access-0'));

    await sync.saveGitHubAccount(
      'access-1',
      'Alice',
      refreshToken: 'refresh-1',
      expiresAt: expires,
      refreshExpiresAt: refreshExpires,
    );

    expect(sync.settings!.token, 'access-1');
    expect(sync.settings!.githubLogin, 'Alice');
    expect(sync.settings!.refreshToken, 'refresh-1');
    expect(sync.settings!.expiresAt, expires);
    expect(sync.settings!.refreshExpiresAt, refreshExpires);
    expect(sync.settings!.gistId, _gistId);
    expect(sync.settings!.automatic, isTrue);
    expect(
      (jsonDecode(secrets.values['harbor.sync.settings.v1']!)
          as Map<String, dynamic>)['refreshToken'],
      'refresh-1',
    );
    var revived = CloudSync(repository);
    addTearDown(revived.dispose);
    await revived.initialize();
    expect(revived.settings!.token, 'access-1');
    expect(revived.settings!.refreshToken, 'refresh-1');
    expect(revived.settings!.expiresAt, expires);
    expect(revived.settings!.refreshExpiresAt, refreshExpires);

    // 没有过期时间的令牌无法刷新，不能留下上一次的轮换凭据。
    await sync.saveGitHubAccount('personal-token', 'alice');
    expect(sync.settings!.token, 'personal-token');
    expect(sync.settings!.refreshToken, isEmpty);
    expect(sync.settings!.expiresAt, isNull);
    expect(sync.settings!.refreshExpiresAt, isNull);
    expect(sync.settings!.gistId, _gistId);
    revived = CloudSync(repository);
    addTearDown(revived.dispose);
    await revived.initialize();
    expect(revived.settings!.token, 'personal-token');
    expect(revived.settings!.refreshToken, isEmpty);
    expect(revived.settings!.expiresAt, isNull);
    expect(revived.settings!.refreshExpiresAt, isNull);
  });

  test('WebDAV 两设备同步身份定义与替换规则，当前身份选择各自保留', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? remote;
    var revision = 0, puts = 0;
    server.listen((request) async {
      expect(
        request.headers.value('authorization'),
        'Basic ${base64Encode(utf8.encode('test:app-password'))}',
      );
      if (request.method == 'PROPFIND') {
        request.response.statusCode = 207;
      } else if (request.method == 'GET') {
        request.response.statusCode = remote == null ? 404 : 200;
        if (remote != null) {
          request.response.headers.set('ETag', '"$revision"');
          request.response.write(remote);
        }
      } else if (request.method == 'PUT') {
        final incoming = await utf8.decoder.bind(request).join();
        final expected = remote == null ? '*' : '"$revision"';
        final actual = remote == null
            ? request.headers.value('if-none-match')
            : request.headers.value('if-match');
        if (actual != expected) {
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
    const password = 'shared-encryption-password';
    // 旧客户端留下的存档只有连接，没有任何身份记录。
    remote = await encryptSync(
      SyncSnapshot({
        'host:${testHost.id}': {'data': testHost.toJson(), 'secret': null},
      }).encode(),
      password,
    );
    revision = 1;
    expect(
      (jsonDecode(await decryptSync(remote!, password)) as Map)['version'],
      1,
    );
    final settings = WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: password,
    );
    final a = memoryRepository(), b = memoryRepository();
    final syncA = WebDavSync(a), syncB = WebDavSync(b);
    addTearDown(syncA.dispose);
    addTearDown(syncB.dispose);
    await syncA.saveSettings(settings);
    await syncB.saveSettings(settings);
    await syncA.testConnection(settings);

    // A 建好带替换规则的身份并选中后上传。
    await a.saveHosts([testHost]);
    await a.saveNetworkIdentities(
      const NetworkIdentities(
        identities: [_officeIdentity],
        activeId: 'identity-office',
      ),
    );
    await syncA.synchronize();
    final uploaded = await decryptSync(remote!, password);
    expect((jsonDecode(uploaded) as Map)['version'], 2);
    expect(uploaded, isNot(contains('activeId')));
    expect(puts, 1);

    // B 保持自己的身份与选择，只把 A 的身份追加到列表末尾。
    await b.saveNetworkIdentities(
      const NetworkIdentities(
        identities: [_homeIdentity],
        activeId: 'identity-home',
      ),
    );
    await syncB.synchronize();
    var bIdentities = await b.loadNetworkIdentities();
    expect(bIdentities.identities.map((identity) => identity.id), [
      'identity-home',
      'identity-office',
    ]);
    expect(bIdentities.activeId, 'identity-home');
    expect(bIdentities.endpointOf(testHost), ('192.168.10.88', 2222));
    final downloaded = bIdentities.identities.last;
    expect(downloaded.name, '公司内网');
    expect(downloaded.endpointOf(testHost), ('10.0.0.5', 2222));
    expect((await b.loadHosts()).single.id, testHost.id);
    expect(puts, 2);

    await syncA.synchronize();
    final aIdentities = await a.loadNetworkIdentities();
    expect(aIdentities.identities.map((identity) => identity.id), [
      'identity-office',
      'identity-home',
    ]);
    expect(aIdentities.activeId, 'identity-office');
    expect(puts, 2);

    // 仅切换当前身份：云端内容与上传次数都不变，另一端的选择也不受影响。
    final cloudBeforeSwitch = remote;
    await b.saveNetworkIdentities(
      bIdentities.copyWith(activeId: 'identity-office'),
    );
    await syncB.synchronize();
    expect(remote, cloudBeforeSwitch);
    expect(puts, 2);
    await syncA.synchronize();
    expect(remote, cloudBeforeSwitch);
    expect(puts, 2);
    expect((await a.loadNetworkIdentities()).activeId, 'identity-office');

    NetworkIdentity renamed(NetworkIdentity identity, String name) =>
        NetworkIdentity(
          id: identity.id,
          name: name,
          overrides: identity.overrides,
        );

    // A 改名并修改规则，B 同步后拿到新定义，仍保持自己的选择。
    const newOffice = NetworkIdentity(
      id: 'identity-office',
      name: '公司内网（新）',
      overrides: {'host-1': EndpointOverride(address: '10.0.0.6', port: 2224)},
    );
    await a.saveNetworkIdentities(
      const NetworkIdentities(
        identities: [newOffice, _homeIdentity],
        activeId: 'identity-office',
      ),
    );
    await syncA.synchronize();
    await syncB.synchronize();
    bIdentities = await b.loadNetworkIdentities();
    expect(bIdentities.activeId, 'identity-office');
    final syncedOffice = bIdentities.identities.firstWhere(
      (identity) => identity.id == 'identity-office',
    );
    expect(syncedOffice.name, '公司内网（新）');
    expect(bIdentities.endpointOf(testHost), ('10.0.0.6', 2224));

    // 两端同时改名：冲突按身份名提示，选择一侧后收敛。
    await a.saveNetworkIdentities(
      NetworkIdentities(
        identities: [renamed(syncedOffice, '总部网络'), _homeIdentity],
        activeId: 'identity-office',
      ),
    );
    await syncA.synchronize();
    await b.saveNetworkIdentities(
      bIdentities.copyWith(
        identities: [
          bIdentities.identities.first,
          renamed(syncedOffice, '分公司网络'),
        ],
      ),
    );
    Object? conflict;
    try {
      await syncB.synchronize();
    } on SyncConflict catch (error) {
      conflict = error;
    }
    expect(conflict, isA<SyncConflict>());
    expect((conflict! as SyncConflict).names, ['分公司网络']);
    final putsBeforeChoice = puts;
    await syncB.synchronize(choice: SyncConflictChoice.remote);
    bIdentities = await b.loadNetworkIdentities();
    expect(
      bIdentities.identities
          .firstWhere((identity) => identity.id == 'identity-office')
          .name,
      '总部网络',
    );
    expect(bIdentities.activeId, 'identity-office');
    expect(puts, putsBeforeChoice);

    // A 删除正被 B 选中的身份：删除传播，B 回到默认，连接本身不受影响。
    await a.saveNetworkIdentities(
      (await a.loadNetworkIdentities()).copyWith(identities: [_homeIdentity]),
    );
    final putsBeforeDelete = puts;
    await syncA.synchronize();
    expect(puts, putsBeforeDelete + 1);
    await syncB.synchronize();
    final bFinal = await b.loadNetworkIdentities();
    expect(puts, putsBeforeDelete + 1);
    expect(bFinal.identities.map((identity) => identity.id), ['identity-home']);
    expect(bFinal.activeId, isEmpty);
    expect(bFinal.endpointOf(testHost), (testHost.address, testHost.port));
    expect((await b.loadHosts()).single.name, testHost.name);
    expect((await a.loadHosts()).single.name, testHost.name);
    expect(
      SyncSnapshot.decode(await decryptSync(remote!, password)).records
          .containsKey('identity:identity-office'),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('身份写入失败和重启恢复都还原身份定义与本机当前身份，旧版日志不丢身份', () async {
    final preferences = _FailOnceStore();
    final secrets = MemoryStore();
    final repository = HostRepository(
      preferences: preferences,
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    await repository.saveNetworkIdentities(
      const NetworkIdentities(
        identities: [_officeIdentity, _homeIdentity],
        activeId: 'identity-office',
      ),
    );
    final storage = SyncStorage(repository);
    final incoming = SyncSnapshot({
      'host:${testHost.id}': {'data': testHost.toJson(), 'secret': null},
      'identity:identity-home': {'data': _homeIdentity.toJson()},
    });

    // 云端删掉了本机正选中的身份，本轮写入在保存连接时失败：整次回滚。
    preferences.failKey = 'harbor.hosts.v1';
    await expectLater(storage.apply(incoming), throwsStateError);
    final rolledBack = await repository.loadNetworkIdentities();
    expect(rolledBack.identities.map((identity) => identity.id), [
      'identity-home',
      'identity-office',
    ]);
    expect(rolledBack.activeId, 'identity-office');
    expect(rolledBack.endpointOf(testHost), ('10.0.0.5', 2222));
    expect(secrets.values.containsKey('harbor.sync.pending.v1'), isFalse);
    expect((await repository.loadHosts()).single.id, testHost.id);

    // 提交中途断电：日志保留，重启恢复身份定义与被删掉的当前身份。
    final before = await storage.capture();
    await secrets.write(
      'harbor.sync.pending.v1',
      jsonEncode({
        'before': before.encode(),
        'incoming': incoming.encode(),
        'activeId': 'identity-office',
      }),
    );
    await repository.saveNetworkIdentities(
      const NetworkIdentities(identities: [_homeIdentity]),
    );
    await storage.recover();
    final recovered = await repository.loadNetworkIdentities();
    expect(recovered.identities.map((identity) => identity.id), [
      'identity-home',
      'identity-office',
    ]);
    expect(recovered.activeId, 'identity-office');
    expect(recovered.endpointOf(testHost), ('10.0.0.5', 2222));
    expect(secrets.values.containsKey('harbor.sync.pending.v1'), isFalse);

    // 旧客户端留下的日志没有身份概念：恢复连接，本机身份与选择原样保留。
    final legacyBefore = SyncSnapshot({
      'host:${testHost.id}': {
        'data': {...testHost.toJson(), 'name': '旧名称'},
        'secret': null,
      },
    });
    final legacyIncoming = SyncSnapshot({
      'host:${testHost.id}': {
        'data': {...testHost.toJson(), 'name': '新名称'},
        'secret': null,
      },
    });
    await secrets.write(
      'harbor.sync.pending.v1',
      jsonEncode({
        'before': legacyBefore.encode(),
        'incoming': legacyIncoming.encode(),
      }),
    );
    await storage.recover();
    expect((await repository.loadHosts()).single.name, '旧名称');
    final kept = await repository.loadNetworkIdentities();
    expect(kept.identities.map((identity) => identity.id), [
      'identity-home',
      'identity-office',
    ]);
    expect(kept.activeId, 'identity-office');
    expect(secrets.values.containsKey('harbor.sync.pending.v1'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('同步进行中拒绝修改身份，完成后主界面采用云端身份并保留本机选择', () async {
    const password = 'shared-encryption-password';
    final server = await _GatedWebDavServer.start();
    addTearDown(server.close);
    server.content = await encryptSync(
      SyncSnapshot({
        'host:${testHost.id}': {'data': testHost.toJson(), 'secret': null},
        'identity:identity-office': {'data': _officeIdentity.toJson()},
      }).encode(),
      password,
    );
    server.revision = 1;
    final repository = memoryRepository();
    await repository.saveNetworkIdentities(
      const NetworkIdentities(
        identities: [_homeIdentity],
        activeId: 'identity-home',
      ),
    );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    await model.cloudSync.saveSettings(
      WebDavSettings(
        url: 'http://127.0.0.1:${server.port}/dav/',
        username: 'test',
        password: 'app-password',
        encryptionPassword: password,
      ),
    );

    server.blockGet();
    final syncing = model.syncNow();
    await server.getReached.future;
    await expectLater(
      model.saveNetworkIdentities(
        const NetworkIdentities(
          identities: [_officeIdentity],
          activeId: 'identity-office',
        ),
      ),
      throwsStateError,
    );
    expect(
      (await repository.loadNetworkIdentities()).identities.single.id,
      'identity-home',
    );
    server.releaseGet();
    await syncing;
    expect(server.puts, 1);

    expect(model.networkIdentities.identities.map((identity) => identity.id), [
      'identity-home',
      'identity-office',
    ]);
    expect(model.networkIdentities.activeId, 'identity-home');
    expect(model.networkIdentities.endpointOf(testHost), (
      '192.168.10.88',
      2222,
    ));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('首次同步的网络阶段保存图标立即成功，不报虚假冲突且下次同步上传', () async {
    const password = 'shared-encryption-password';
    final server = await _GatedWebDavServer.start();
    addTearDown(server.close);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final settings = WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: password,
    );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    await model.cloudSync.saveSettings(settings);

    // 首次同步：本机没有基线，云端也还没有文件。
    server.blockGet();
    final syncing = model.syncNow();
    await server.getReached.future;
    final edited = Host.fromJson({...testHost.toJson(), 'icon': 'database'});
    await model.saveHost(
      edited,
      null,
      originalHost: testHost,
      originalCredentials: null,
    );
    expect(model.hosts.single.icon, 'database');
    expect((await repository.loadHosts()).single.icon, 'database');

    // 收尾只折回本次真正的本地改动，不因为缺少基线凭空报冲突。
    server.releaseGet();
    await syncing;
    expect(model.cloudSync.failed, isFalse);
    expect(model.hosts.single.icon, 'database');
    expect((await repository.loadHosts()).single.icon, 'database');

    // 这次上传的是同步开始时看到的版本，随后的同步补上新图标。
    await model.syncNow();
    final remote = SyncSnapshot.decode(
      await decryptSync(server.content!, password),
    );
    expect(
      (remote.records['host:${testHost.id}']!['data'] as Map)['icon'],
      'database',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('本地改名尚未上传时网络阶段再保存图标，两个改动都保留并随后上传', () async {
    const password = 'shared-encryption-password';
    final server = await _GatedWebDavServer.start();
    addTearDown(server.close);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final settings = WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: password,
    );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    await model.cloudSync.saveSettings(settings);
    // 先让云端和基线停在旧名字。
    await model.syncNow();
    expect(server.puts, 1);

    // 本地改名还没有上传。
    final renamed = Host.fromJson({...testHost.toJson(), 'name': '改名的服务器'});
    await model.saveHost(
      renamed,
      null,
      originalHost: testHost,
      originalCredentials: null,
    );

    // 同步上传期间又保存了图标：不能因为基线落后于本地而误报冲突。
    server.blockGet();
    final syncing = model.syncNow();
    await server.getReached.future;
    final edited = Host.fromJson({...renamed.toJson(), 'icon': 'database'});
    await model.saveHost(
      edited,
      null,
      originalHost: renamed,
      originalCredentials: null,
    );
    expect((await repository.loadHosts()).single.icon, 'database');

    server.releaseGet();
    await syncing;
    expect(model.cloudSync.failed, isFalse);
    final saved = (await repository.loadHosts()).single;
    expect(saved.name, '改名的服务器');
    expect(saved.icon, 'database');

    await model.syncNow();
    final remote = SyncSnapshot.decode(
      await decryptSync(server.content!, password),
    );
    final data = remote.records['host:${testHost.id}']!['data'] as Map;
    expect(data['name'], '改名的服务器');
    expect(data['icon'], 'database');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('同步提交持锁写入云端改名、书签与凭据时，排队的旧编辑只叠加自己的图标', () async {
    const password = 'shared-encryption-password';
    final server = await _GatedWebDavServer.start();
    addTearDown(server.close);
    const localCredentials = Credentials(password: 'ssh-password');
    final preferences = _GatedPreferences();
    final repository = HostRepository(
      preferences: preferences,
      secrets: MemoryStore(),
    );
    await repository.saveHosts([testHost]);
    await repository.saveCredentials(testHost.id, localCredentials);
    final settings = WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: password,
    );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    await model.cloudSync.saveSettings(settings);
    await model.syncNow();
    expect(server.puts, 1);

    // 云端换了名字、加了书签并换了密码。
    final cloudHost = Host.fromJson({
      ...testHost.toJson(),
      'name': '云端改名',
      'sftpBookmarks': ['/srv/cloud'],
    });
    server.content = await encryptSync(
      SyncSnapshot({
        'host:${testHost.id}': <String, dynamic>{
          'data': cloudHost.toJson(),
          'secret': const Credentials(password: 'cloud-password').toJson(),
        },
      }).encode(),
      password,
    );
    server.revision++;

    // 同步收尾持锁落盘期间，同步开始前就打开的编辑窗口提交保存。
    final gate = Completer<void>();
    preferences.hostsGate = gate;
    final syncing = model.syncNow();
    await preferences.entered.future;
    var saved = false;
    final edited = Host.fromJson({...testHost.toJson(), 'icon': 'database'});
    final queued = model
        .saveHost(
          edited,
          localCredentials,
          originalHost: testHost,
          originalCredentials: localCredentials,
        )
        .then((_) => saved = true);
    await Future<void>.delayed(Duration.zero);
    expect(saved, isFalse);
    gate.complete();
    await syncing;
    await queued;
    expect(saved, isTrue);

    final host = (await repository.loadHosts()).single;
    expect(host.name, '云端改名');
    expect(host.sftpBookmarks, ['/srv/cloud']);
    expect(host.icon, 'database');
    expect(host.address, testHost.address);
    expect(
      (await repository.credentials(testHost.id))!.password,
      'cloud-password',
    );
    expect(model.hosts.single.icon, 'database');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('云端删除主机后旧编辑不能复活记录', () async {
    const password = 'shared-encryption-password';
    final server = await _GatedWebDavServer.start();
    addTearDown(server.close);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final settings = WebDavSettings(
      url: 'http://127.0.0.1:${server.port}/dav/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: password,
    );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    await model.cloudSync.saveSettings(settings);
    await model.syncNow();

    // 云端删除了这条连接，本地随同步一起删除。
    server.content = await encryptSync(SyncSnapshot.empty().encode(), password);
    server.revision++;
    await model.syncNow();
    expect(await repository.loadHosts(), isEmpty);
    expect(model.hosts, isEmpty);

    // 编辑窗口仍是删除前打开的：保存必须被拒绝，而不是把记录写回本地。
    final stale = Host.fromJson({...testHost.toJson(), 'icon': 'database'});
    await expectLater(
      model.saveHost(
        stale,
        null,
        originalHost: testHost,
        originalCredentials: null,
      ),
      throwsA(isA<SyncConflict>()),
    );
    expect(await repository.loadHosts(), isEmpty);
    expect(model.hosts, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('认证组并发真实冲突时不写入任何字段或凭据', () async {
    const original = Credentials(password: 'ssh-password');
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    await repository.saveCredentials(testHost.id, original);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();

    // 另一个窗口把地址和密码一起换掉了。
    final moved = Host.fromJson({
      ...testHost.toJson(),
      'address': 'new.example.com',
    });
    await model.saveHost(
      moved,
      const Credentials(password: 'new-password'),
      originalHost: testHost,
      originalCredentials: original,
    );

    // 这个窗口还显示旧地址，却把用户名和密码改成了另一组：整组认证必须
    // 报冲突，绝不能把旧账号的密码套到新地址上。
    final renamed = Host.fromJson({...testHost.toJson(), 'username': 'ops'});
    await expectLater(
      model.saveHost(
        renamed,
        const Credentials(password: 'other-password'),
        originalHost: testHost,
        originalCredentials: original,
      ),
      throwsA(isA<SyncConflict>()),
    );
    final host = (await repository.loadHosts()).single;
    expect(host.address, 'new.example.com');
    expect(host.username, 'deploy');
    expect(
      (await repository.credentials(testHost.id))!.password,
      'new-password',
    );
    expect(model.hosts.single.address, 'new.example.com');
  });

  test('启动恢复未完成的身份写入后主界面按恢复的当前身份拨号', () async {
    final secrets = MemoryStore();
    final repository = HostRepository(
      preferences: MemoryStore(),
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    final before = SyncSnapshot({
      'host:${testHost.id}': {'data': testHost.toJson(), 'secret': null},
      'identity:identity-office': {'data': _officeIdentity.toJson()},
    });
    final incoming = SyncSnapshot({
      'host:${testHost.id}': {'data': testHost.toJson(), 'secret': null},
    });
    await secrets.write(
      'harbor.sync.pending.v1',
      jsonEncode({
        'before': before.encode(),
        'incoming': incoming.encode(),
        'activeId': 'identity-office',
      }),
    );
    // 断电前云端快照已经把身份定义和本机选择一起写掉。
    await repository.saveNetworkIdentities(const NetworkIdentities());

    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();

    expect(model.networkIdentities.activeId, 'identity-office');
    expect(model.networkIdentities.endpointOf(testHost), ('10.0.0.5', 2222));
    expect(secrets.values.containsKey('harbor.sync.pending.v1'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

const _gistId = '0123456789abcdef';

CloudSyncConfig _gistSettings({
  String token = 'access-1',
  String login = 'alice',
  String refreshToken = '',
  DateTime? expiresAt,
  DateTime? refreshExpiresAt,
  String gistId = _gistId,
}) => CloudSyncConfig(
  provider: SyncProvider.gist,
  gistId: gistId,
  token: token,
  githubLogin: login,
  refreshToken: refreshToken,
  expiresAt: expiresAt,
  refreshExpiresAt: refreshExpiresAt,
  encryptionPassword: 'shared-password',
  automatic: true,
);

({HostRepository repository, MemoryStore secrets}) _gistRepository() {
  final secrets = MemoryStore();
  return (
    repository: HostRepository(preferences: MemoryStore(), secrets: secrets),
    secrets: secrets,
  );
}

CloudSync _gistSync(
  HostRepository repository,
  _GistServer server,
  _FakeAuth auth,
  DateTime Function() clock,
) => CloudSync(
  repository,
  gistClientFactory: (config) => _SyncGist(config, server),
  githubAuthFactory: () => auth,
  now: clock,
);

class _Clock {
  _Clock(this.value);
  DateTime value;
}

class _FakeAuth extends GitHubDeviceAuth {
  final calls = <String>[];
  final results = <Object>[];
  Completer<void>? gate;

  @override
  Future<GitHubRenewal> refresh(String refreshToken) async {
    calls.add(refreshToken);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final next = results.isEmpty ? null : results.removeAt(0);
    if (next is Exception) throw next;
    if (next is GitHubRenewal) return next;
    throw const SyncFailure('测试没有提供刷新结果');
  }
}

class _GistServer {
  bool exists = true;
  String? content;
  String login = 'alice';
  int userStatus = 200;
  int revision = 0;
  final requests = <String>[];
  final tokens = <String>[];

  int get writes => requests
      .where(
        (request) => request.startsWith('PATCH') || request.startsWith('POST'),
      )
      .length;

  GitHubResponse handle(
    CloudSyncConfig settings,
    String method,
    String path,
    Map<String, Object?>? body,
  ) {
    requests.add('$method $path');
    tokens.add(settings.token);
    final uri = Uri.parse(path);
    if (method == 'GET' && path == 'user') {
      return GitHubResponse(userStatus, '{"login":"$login"}');
    }
    if (method == 'GET' && uri.path == 'gists') {
      return GitHubResponse(200, jsonEncode(exists ? [_gist()] : const []));
    }
    if (method == 'POST' && uri.path == 'gists') {
      exists = true;
      content = _uploaded(body);
      revision++;
      return GitHubResponse(201, jsonEncode(_gist()));
    }
    if (uri.path == 'gists/$_gistId') {
      if (method == 'PATCH') {
        content = _uploaded(body);
        revision++;
        return GitHubResponse(200, jsonEncode(_gist()));
      }
      if (!exists) return const GitHubResponse(404, '{}');
      return GitHubResponse(200, jsonEncode(_gist()));
    }
    if (method == 'GET' && uri.path.startsWith('gists/')) {
      return const GitHubResponse(404, '{}');
    }
    return const GitHubResponse(500, '{}');
  }

  Map<String, Object?> _gist() => {
    'id': _gistId,
    'owner': {'login': 'alice'},
    'files': {
      gistSyncFileName: {'content': content ?? ''},
    },
    'history': [
      {'version': 'rev-$revision'},
    ],
  };

  static String? _uploaded(Map<String, Object?>? body) {
    final files = body?['files'];
    if (files is! Map) return null;
    final file = files[gistSyncFileName];
    return file is Map ? file['content'] as String? : null;
  }
}

class _FakeWebDav extends WebDavClient {
  _FakeWebDav(super.settings);
  String? content;
  int revision = 0;

  @override
  Future<WebDavResponse> request(
    String method, {
    bool directory = false,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    if (method == 'PROPFIND') return const WebDavResponse(207, '', null);
    if (method == 'GET') {
      return content == null
          ? const WebDavResponse(404, '', null)
          : WebDavResponse(200, content!, '"$revision"');
    }
    if (method == 'PUT') {
      content = body;
      revision++;
      return const WebDavResponse(201, '', null);
    }
    return const WebDavResponse(500, '', null);
  }
}

class _SyncGist extends GitHubGistClient {
  _SyncGist(super.settings, this.server);
  final _GistServer server;

  @override
  Future<GitHubResponse> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async => server.handle(settings, method, path, body);
}

class _SlowSecretStore extends MemoryStore {
  Completer<void>? gate;
  final writes = <String>[];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    final gate = this.gate;
    if (gate != null) {
      this.gate = null;
      await gate.future;
    }
    await super.write(key, value);
  }
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

/// 真实回环 WebDAV 服务器：GET 可被闸门停住，用来观察同步进行中的本地写入。
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

class _GatedWebDavServer {
  _GatedWebDavServer._(this._server);

  static Future<_GatedWebDavServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _GatedWebDavServer._(server);
    server.listen(instance._handle, onError: (Object _) {});
    return instance;
  }

  final HttpServer _server;
  int get port => _server.port;

  String? content;
  int revision = 0;
  int puts = 0;
  Completer<void>? _getGate;
  final getReached = Completer<void>();

  void blockGet() => _getGate = Completer<void>();

  void releaseGet() {
    final gate = _getGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> close() async {
    releaseGet();
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
        final expected = content == null ? '*' : '"$revision"';
        final actual = content == null
            ? request.headers.value('if-none-match')
            : request.headers.value('if-match');
        if (actual != expected) {
          request.response.statusCode = 412;
        } else {
          content = incoming;
          revision++;
          puts++;
          request.response.statusCode = 201;
        }
      } else {
        request.response.statusCode = 207;
      }
      await request.response.close();
    } catch (_) {
      // 断言失败后服务器会被拆掉，忽略残留连接。
    }
  }
}
