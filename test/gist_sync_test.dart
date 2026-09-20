import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/gist_sync.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';

import 'support.dart';

const gistConfig = CloudSyncConfig(
  provider: SyncProvider.gist,
  token: 'github-test-token',
  encryptionPassword: 'shared-encryption-password',
);
const gistId = '0123456789abcdef0123456789abcdef';

void main() {
  test('旧配置仍使用 WebDAV，Gist ID 可从链接读取，凭据不进入基线键', () {
    final legacy = CloudSyncConfig.fromJson({
      'url': 'https://dav.example.com/',
      'username': 'user',
      'password': 'password',
      'encryptionPassword': 'shared-password',
    });
    expect(legacy.provider, SyncProvider.webdav);
    final config = gistConfig.withGistId(
      'https://gist.github.com/user/$gistId',
    );
    expect(config.normalizedGistId, gistId);
    expect(config.baselineKey, gistConfig.withGistId(gistId).baselineKey);
    expect(config.baselineKey, isNot(contains(config.token)));
    expect(
      () => gistConfig.withGistId('https://example.com/$gistId').validate(),
      throwsA(isA<SyncFailure>()),
    );
  });

  test('创建 Secret Gist、双设备同步和冲突处理，不修改其他文件', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final files = <String, String>{'notes.txt': 'keep this file'};
    var revision = 0, posts = 0, patches = 0;
    var exists = false, statusOverride = 0;
    Map<String, Object?> document() => {
      'id': gistId,
      'owner': {'login': 'test-user'},
      'history': [
        {'version': 'revision-$revision'},
      ],
      'files': {
        for (final file in files.entries)
          file.key: {'content': file.value, 'truncated': false},
      },
    };
    server.listen((request) async {
      expect(
        request.headers.value('authorization'),
        'Bearer github-test-token',
      );
      expect(request.headers.value('x-github-api-version'), '2022-11-28');
      expect(request.headers.value('user-agent'), 'Harbor-SSH');
      if (statusOverride != 0) {
        request.response.statusCode = statusOverride;
      } else if (request.uri.path == '/user') {
        request.response.write('{"login":"test-user"}');
      } else if (request.method == 'GET' && request.uri.path == '/gists') {
        request.response.write(jsonEncode(exists ? [document()] : []));
      } else if (request.method == 'POST' && request.uri.path == '/gists') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['public'], isFalse);
        expect(body.toString(), isNot(contains('ssh-secret')));
        expect(body.toString(), isNot(contains('private-key')));
        final incoming = body['files'] as Map;
        files[gistSyncFileName] =
            (incoming[gistSyncFileName] as Map)['content'] as String;
        exists = true;
        posts++;
        revision++;
        request.response.statusCode = 201;
        request.response.write(jsonEncode(document()));
      } else if (request.uri.path == '/gists/$gistId' && exists) {
        if (request.method == 'PATCH') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final incoming = body['files'] as Map;
          expect(incoming.keys, [gistSyncFileName]);
          files[gistSyncFileName] =
              (incoming[gistSyncFileName] as Map)['content'] as String;
          patches++;
          revision++;
        }
        request.response.write(jsonEncode(document()));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    GitHubGistClient client(CloudSyncConfig config) => GitHubGistClient(
      config,
      apiBase: Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final a = memoryRepository(), b = memoryRepository();
    final syncA = CloudSync(a, gistClientFactory: client);
    final syncB = CloudSync(b, gistClientFactory: client);
    addTearDown(syncA.dispose);
    addTearDown(syncB.dispose);
    await syncA.saveSettings(gistConfig);
    await syncA.testConnection(gistConfig);
    expect(posts, 0);
    await a.saveHosts([testHost]);
    await a.saveCredentials(
      testHost.id,
      const Credentials(password: 'ssh-secret'),
    );
    const key = SshUser(
      id: 'key-1',
      name: 'private key',
      username: '',
      authMethod: AuthMethod.privateKey,
      publicKey: 'ssh-ed25519 public',
    );
    await a.saveUsers([key]);
    await a.saveUserCredentials(
      key.id,
      const Credentials(privateKey: 'private-key', passphrase: 'key-password'),
    );
    await syncA.synchronize();
    expect(syncA.settings!.gistId, gistId);
    expect(posts, 1);
    expect(files[gistSyncFileName], isNot(contains('ssh-secret')));
    expect(files[gistSyncFileName], isNot(contains('private-key')));
    final reloaded = CloudSync(a, gistClientFactory: client);
    await reloaded.initialize();
    expect(reloaded.settings!.gistId, gistId);
    expect(reloaded.lastSync, isNotNull);
    reloaded.dispose();
    expect(
      (a.preferences as MemoryStore).values.values.join(),
      isNot(contains(gistConfig.token)),
    );
    // A second device only needs the same account and encryption password.
    await syncB.saveSettings(gistConfig);
    await syncB.testConnection(syncB.settings!);
    await syncB.synchronize();
    expect(syncB.settings!.gistId, gistId);
    expect(posts, 1);
    expect((await b.credentials(testHost.id))!.password, 'ssh-secret');
    expect((await b.userCredentials(key.id))!.privateKey, 'private-key');
    expect((await b.loadUsers()).single.publicKey, key.publicKey);
    expect(patches, 0);
    await b.saveHosts([testHost.withFavorite(true)]);
    await syncB.synchronize();
    // Losing the local ID still restores the existing merge baseline.
    await syncA.saveSettings(gistConfig);
    await syncA.synchronize();
    expect((await a.loadHosts()).single.favorite, isTrue);
    Host renamed(String name) =>
        Host.fromJson({...testHost.toJson(), 'name': name});
    await a.saveHosts([renamed('A edit')]);
    await b.saveHosts([renamed('B edit')]);
    await syncA.synchronize();
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
    expect(files['notes.txt'], 'keep this file');
    final before = files[gistSyncFileName];
    final localBefore = (await SyncStorage(a).capture()).encode();
    for (final status in [401, 403, 404, 429]) {
      statusOverride = status;
      await expectLater(syncA.synchronize(), throwsA(isA<SyncFailure>()));
      expect(files[gistSyncFileName], before);
      expect((await SyncStorage(a).capture()).encode(), localBefore);
    }
    statusOverride = 0;
    await syncA.saveSettings(
      CloudSyncConfig(
        provider: SyncProvider.gist,
        gistId: gistId,
        token: gistConfig.token,
        encryptionPassword: 'incorrect-encryption-password',
      ),
    );
    await expectLater(syncA.synchronize(), throwsA(isA<SyncFailure>()));
    expect(files[gistSyncFileName], before);
    expect((await SyncStorage(a).capture()).encode(), localBefore);
    final plaintext = await decryptSync(before!, gistConfig.encryptionPassword);
    expect(
      SyncSnapshot.decode(plaintext).records.containsKey('key:key-1'),
      isTrue,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('版本在提交前改变时停止写入，截断文件读取完整内容', () async {
    final client = _ControlledClient(gistConfig.withGistId(gistId));
    final backend = GistSyncBackend(client.settings, client);
    final previous = await backend.read();
    expect(previous.content, 'full encrypted data');
    expect(client.rawReads, 1);
    client.revision++;
    await expectLater(
      backend.write('new encrypted data', previous),
      throwsA(isA<SyncFailure>()),
    );
    expect(client.patches, 0);
    expect(
      () => GitHubGistClient(gistConfig).readRaw('https://example.com/file'),
      throwsA(isA<SyncFailure>()),
    );
  });
}

class _ControlledClient extends GitHubGistClient {
  _ControlledClient(super.settings);
  int revision = 1, patches = 0, rawReads = 0;
  @override
  Future<GitHubResponse> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    if (method == 'PATCH') patches++;
    return GitHubResponse(
      200,
      jsonEncode({
        'history': [
          {'version': 'revision-$revision'},
        ],
        'files': {
          gistSyncFileName: {
            'truncated': true,
            'content': 'partial',
            'raw_url':
                'https://gist.githubusercontent.com/user/raw/revision/file',
          },
        },
      }),
    );
  }

  @override
  Future<GitHubResponse> readRaw(String url) async {
    rawReads++;
    return const GitHubResponse(200, 'full encrypted data');
  }
}
