import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';

import 'support.dart';

Map<String, dynamic> hostJson(Map<String, dynamic> overrides) => {
  'id': 'host-1',
  'name': '开发服务器',
  'address': 'dev.example.com',
  'username': 'deploy',
  'port': 22,
  'authMethod': 'password',
  ...overrides,
};

void main() {
  test('旧 group 字段读取为单个标签', () {
    final host = Host.fromJson(hostJson({'group': '开发'}));
    expect(host.tags, ['开发']);
  });

  test('tags 优先于 group，并去除空白、空项与重复', () {
    final host = Host.fromJson(
      hostJson({
        'tags': ['  生产 ', '生产', '', '   ', 'dev'],
        'group': '旧分组',
      }),
    );
    expect(host.tags, ['生产', 'dev']);
  });

  test('显式空 tags 不会回落到旧 group', () {
    final host = Host.fromJson(hostJson({'tags': [], 'group': '旧分组'}));
    expect(host.tags, isEmpty);
  });

  test('类型错误的标签数据抛出格式异常而非静默丢弃', () {
    expect(
      () => Host.fromJson(hostJson({'tags': '生产'})),
      throwsFormatException,
    );
    expect(
      () => Host.fromJson(hostJson({'tags': ['生产', 3]})),
      throwsFormatException,
    );
    expect(
      () => Host.fromJson(hostJson({'group': 5})),
      throwsFormatException,
    );
  });

  test('多个标签本地保存读回，且不再写出旧 group 字段', () async {
    final store = MemoryStore();
    final repository = HostRepository(preferences: store, secrets: MemoryStore());
    const host = Host(
      id: 'host-1',
      name: '开发服务器',
      address: 'dev.example.com',
      username: 'deploy',
      tags: ['生产', 'dev'],
    );
    await repository.saveHosts([host]);
    final stored =
        jsonDecode(store.values['harbor.hosts.v1']!) as List<dynamic>;
    expect((stored.single as Map<String, dynamic>)['tags'], ['生产', 'dev']);
    expect((stored.single as Map<String, dynamic>).containsKey('group'), false);
    expect((await repository.loadHosts()).single.tags, ['生产', 'dev']);
  });

  test('多标签主机经同步快照往返不丢失', () async {
    final source = memoryRepository();
    await source.saveHosts([
      const Host(
        id: 'host-1',
        name: '开发服务器',
        address: 'dev.example.com',
        username: 'deploy',
        tags: ['生产', 'dev'],
      ),
    ]);
    final snapshot = await SyncStorage(source).capture();
    final destination = memoryRepository();
    await SyncStorage(
      destination,
    ).apply(SyncSnapshot.decode(snapshot.encode()));
    expect(
      (await destination.loadHosts()).single.tags,
      ['生产', 'dev'],
    );
  });

  test('云端旧数据（group 字段）同步落地为一个标签', () async {
    final local = memoryRepository();
    final legacy = SyncSnapshot({
      'host:host-1': {
        'data': hostJson({'group': '运维'}),
        'secret': null,
      },
    });
    await SyncStorage(local).apply(legacy);
    expect((await local.loadHosts()).single.tags, ['运维']);
    expect(
      (await SyncStorage(local).capture()).records['host:host-1']!['data'],
      containsPair('tags', ['运维']),
    );
  });
}
