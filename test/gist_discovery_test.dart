import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/gist_sync.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';

import 'support.dart';

const _id = '0123456789abcdef';
const _config = CloudSyncConfig(
  provider: SyncProvider.gist,
  token: 'test-token',
  githubLogin: 'alice',
  encryptionPassword: 'shared-password',
);

Map<String, Object?> _gist(
  String id, {
  String owner = 'alice',
  bool sync = true,
}) => {
  'id': id,
  'owner': {'login': owner},
  'files': {
    sync ? gistSyncFileName : 'notes.txt': {'content': 'encrypted-content'},
  },
  'history': [
    {'version': 'revision-1'},
  ],
};

void main() {
  test('跨页查找账号自己的旧存档，忽略其他账号的同名文件', () async {
    final client = _Client();
    client.pages = [
      [
        for (var i = 0; i < 99; i++)
          _gist((100000 + i).toRadixString(16), sync: false),
        _gist('abcdef', owner: 'other-user'),
      ],
      [_gist(_id)],
    ];
    final backend = GistSyncBackend(_config, client);
    expect(await backend.resolve(), _id);
    expect(client.listedPages, [1, 2]);
    expect((await backend.read()).content, 'encrypted-content');
    expect(client.writes, 0);
  });

  test('新账号只创建自己的 Secret Gist，不引用其他账号的文件', () async {
    final client = _Client()
      ..pages = [
        [_gist('abcdef', owner: 'other-user')],
      ];
    final backend = GistSyncBackend(_config, client);
    expect(await backend.resolve(), isNull);
    final previous = await backend.read();
    expect(previous.content, isNull);
    expect(await backend.write('new encrypted content', previous), _id);
    expect(client.writes, 1);
    expect(client.lastWrite!['public'], isFalse);
    expect((client.lastWrite!['files'] as Map).keys, [gistSyncFileName]);
  });

  test('创建前再次发现其他设备的存档，不重复创建', () async {
    final client = _Client();
    final backend = GistSyncBackend(_config, client);
    expect(await backend.resolve(), isNull);
    final previous = await backend.read();
    client.pages = [
      [_gist(_id)],
    ];
    await expectLater(
      backend.write('encrypted', previous),
      throwsA(isA<SyncFailure>()),
    );
    expect(client.writes, 0);
  });

  test('多个匹配或列表失败都停止，不创建或更新存档', () async {
    final client = _Client()
      ..pages = [
        [_gist(_id), _gist('abcdef')],
      ];
    await expectLater(
      GistSyncBackend(_config, client).resolve(),
      throwsA(isA<SyncFailure>()),
    );
    client.pages = [[]];
    client.listStatus = 403;
    await expectLater(
      GistSyncBackend(_config, client).resolve(),
      throwsA(isA<SyncFailure>()),
    );
    expect(client.writes, 0);
    client.listStatus = 200;
    client.pages = [
      [
        {
          'id': _id,
          'files': {gistSyncFileName: {}},
        },
      ],
    ];
    await expectLater(
      GistSyncBackend(_config, client).resolve(),
      throwsA(isA<SyncFailure>()),
    );
    expect(client.writes, 0);
  });

  test('缓存指向其他账号时查找本账号，已删除且无法找回则停止', () async {
    final cached = _config.withGistId('abcdef');
    final client = _Client(cached)
      ..pages = [
        [_gist('abcdef', owner: 'bob'), _gist(_id)],
      ];
    expect(await GistSyncBackend(cached, client).resolve(), _id);
    client.pages = [[]];
    await expectLater(
      GistSyncBackend(cached, client).resolve(),
      throwsA(isA<SyncFailure>()),
    );
    expect(client.writes, 0);
  });

  test('同一账号重新登录保留地址，切换账号与退出清除地址并暂停自动同步', () async {
    final sync = CloudSync(memoryRepository());
    addTearDown(sync.dispose);
    const original = CloudSyncConfig(
      provider: SyncProvider.gist,
      gistId: _id,
      token: 'old-token',
      githubLogin: 'alice',
      encryptionPassword: 'shared-password',
      automatic: true,
    );
    await sync.saveSettings(original);
    await sync.saveGitHubAccount('renewed-token', 'Alice');
    expect(sync.settings!.gistId, _id);
    expect(sync.settings!.automatic, isTrue);
    sync.lastSync = DateTime.now();
    await sync.saveGitHubAccount('bob-token', 'bob');
    expect(sync.settings!.gistId, isEmpty);
    expect(sync.settings!.automatic, isFalse);
    expect(sync.lastSync, isNull);
    await sync.saveSettings(original);
    await sync.saveGitHubAccount('', '');
    expect(sync.settings!.gistId, isEmpty);
    expect(sync.settings!.token, isEmpty);
    expect(sync.settings!.automatic, isFalse);
  });
}

class _Client extends GitHubGistClient {
  _Client([super.settings = _config]);
  List<List<Map<String, Object?>>> pages = [[]];
  final listedPages = <int>[];
  int writes = 0, listStatus = 200;
  Map<String, Object?>? lastWrite;
  @override
  Future<GitHubResponse> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse(path);
    if (method == 'GET' && path == 'user') {
      return const GitHubResponse(200, '{"login":"alice"}');
    }
    if (method == 'GET' && uri.path == 'gists') {
      final page = int.parse(uri.queryParameters['page']!);
      expect(uri.queryParameters['per_page'], '100');
      listedPages.add(page);
      return GitHubResponse(
        listStatus,
        jsonEncode(page <= pages.length ? pages[page - 1] : []),
      );
    }
    if (method == 'GET' && uri.path.startsWith('gists/')) {
      final id = uri.pathSegments.last;
      final gist = pages
          .expand((page) => page)
          .where((gist) => gist['id'] == id)
          .firstOrNull;
      return GitHubResponse(gist == null ? 404 : 200, jsonEncode(gist));
    }
    if (method == 'POST' && path == 'gists') {
      writes++;
      lastWrite = body;
      return const GitHubResponse(201, '{"id":"$_id"}');
    }
    fail('Unexpected request: $method $path');
  }
}
