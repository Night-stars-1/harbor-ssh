import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';

void main() {
  test('Windows 直接使用逐项存储，不访问旧合并存档', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final backend = _Backend()..items[SecretStore.bundleKey] = 'old-archive';
    final store = SecretStore(backend: backend);
    await store.write('key', 'value');
    expect(await store.read('key'), 'value');
    await store.delete('key');
    expect(backend.items, {SecretStore.bundleKey: 'old-archive'});
    expect(backend.readKeys, ['key']);
    expect(backend.deletedKeys, ['key']);
  });

  test('macOS 默认只读写当前单条钥匙串归档', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final backend = _Backend();
    final store = SecretStore(backend: backend);
    await store.write('key', 'value');
    expect(await store.read('key'), 'value');
    expect(backend.items.keys, [SecretStore.bundleKey]);
    expect(backend.readKeys, [SecretStore.bundleKey]);
  });

  test('只有旧逐项凭证时不迁移不读取不删除，首次保存只建立新归档', () async {
    final backend = _Backend()
      ..items['harbor.credentials.old'] = 'old-private-key'
      ..items['harbor.ai.v1'] = 'old-ai-settings';
    final original = Map.of(backend.items);
    final store = SecretStore(backend: backend, useBundle: true);
    expect(await store.read('harbor.credentials.old'), isNull);
    expect(await store.read('harbor.ai.v1'), isNull);
    expect(await store.read('harbor.sync.pending.v1'), isNull);
    expect(backend.items, original);
    expect(backend.readKeys, [SecretStore.bundleKey]);
    expect(backend.writes, isEmpty);
    expect(backend.deletedKeys, isEmpty);
    await store.write('harbor.credentials.new', 'new-private-key');
    expect(jsonDecode(backend.items[SecretStore.bundleKey]!), {
      'harbor.credentials.new': 'new-private-key',
    });
    expect(backend.items['harbor.credentials.old'], 'old-private-key');
    expect(backend.items['harbor.ai.v1'], 'old-ai-settings');
    expect(backend.deletedKeys, isEmpty);
  });

  test('当前归档缺项时不回退读取旧凭证', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({'current': 'saved'})
      ..items['old'] = 'old-private-key';
    final original = Map.of(backend.items);
    final store = SecretStore(backend: backend, useBundle: true);
    expect(await store.read('current'), 'saved');
    expect(await store.read('old'), isNull);
    await store.delete('old');
    expect(backend.items, original);
    expect(backend.readKeys, [SecretStore.bundleKey]);
    expect(backend.writes, isEmpty);
    expect(backend.deletedKeys, isEmpty);
  });

  test('删除当前凭证后不会从旧记录恢复，旧记录留给用户清理', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({'key': 'current'})
      ..items['key'] = 'old';
    final store = SecretStore(backend: backend, useBundle: true);
    await store.delete('key');
    expect(await store.read('key'), isNull);
    expect(
      await SecretStore(backend: backend, useBundle: true).read('key'),
      isNull,
    );
    expect(backend.items['key'], 'old');
    expect(backend.deletedKeys, isEmpty);
  });

  test('逐项模式不从旧合并存档恢复凭证', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({'key': 'archived'});
    final store = SecretStore(backend: backend, useBundle: false);
    expect(await store.read('key'), isNull);
    await store.write('key', 'current');
    expect(await store.read('key'), 'current');
    expect(jsonDecode(backend.items[SecretStore.bundleKey]!), {
      'key': 'archived',
    });
    expect(backend.readKeys, ['key', 'key']);
    expect(backend.deletedKeys, isEmpty);
  });

  test('逐项模式每次读取最新值', () async {
    final backend = _Backend()..items['key'] = 'one';
    final store = SecretStore(backend: backend, useBundle: false);
    expect(await store.read('key'), 'one');
    backend.items['key'] = 'changed';
    expect(await store.read('key'), 'changed');
  });

  test('重复保存相同值不写入，重开后能读取所有当前值', () async {
    final backend = _Backend();
    final store = SecretStore(backend: backend, useBundle: true);
    await store.write('a', 'one');
    await store.write('b', 'two');
    await store.write('a', 'one');
    expect(backend.writes, [SecretStore.bundleKey, SecretStore.bundleKey]);
    final reopened = SecretStore(backend: backend, useBundle: true);
    expect(await reopened.read('a'), 'one');
    expect(await reopened.read('b'), 'two');
  });

  test('损坏的当前归档不能被空数据覆盖', () async {
    final backend = _Backend()..items[SecretStore.bundleKey] = 'not-json';
    final store = SecretStore(backend: backend, useBundle: true);
    await expectLater(store.read('key'), throwsFormatException);
    await expectLater(store.write('key', 'new'), throwsFormatException);
    expect(backend.items[SecretStore.bundleKey], 'not-json');
    expect(backend.writes, isEmpty);
    expect(backend.deletedKeys, isEmpty);
  });

  test('归档授权失败后可重试，不清空或覆盖现有凭证', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({'key': 'saved'})
      ..failReads = true;
    final store = SecretStore(backend: backend, useBundle: true);
    await expectLater(store.read('key'), throwsStateError);
    await expectLater(store.write('key', 'new'), throwsStateError);
    expect(backend.writes, isEmpty);
    backend.failReads = false;
    expect(await store.read('key'), 'saved');
  });

  test('保存失败不污染缓存，相同内容重试仍会落盘', () async {
    final backend = _Backend()..items[SecretStore.bundleKey] = '{}';
    final store = SecretStore(backend: backend, useBundle: true);
    backend.failWrites = true;
    await expectLater(store.write('key', 'new'), throwsStateError);
    expect(await store.read('key'), isNull);
    backend.failWrites = false;
    await store.write('key', 'new');
    expect(
      await SecretStore(backend: backend, useBundle: true).read('key'),
      'new',
    );
  });

  test('删除保存失败保留原缓存并允许再次删除', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({'key': 'saved'});
    final store = SecretStore(backend: backend, useBundle: true);
    backend.failWrites = true;
    await expectLater(store.delete('key'), throwsStateError);
    expect(await store.read('key'), 'saved');
    backend.failWrites = false;
    await store.delete('key');
    expect(
      await SecretStore(backend: backend, useBundle: true).read('key'),
      isNull,
    );
  });
}

class _Backend implements SecretBackend {
  final items = <String, String>{};
  final writes = <String>[];
  final readKeys = <String>[];
  final deletedKeys = <String>[];
  var failReads = false;
  var failWrites = false;

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    if (failReads) throw StateError('authorization denied');
    return items[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('storage unavailable');
    writes.add(key);
    items[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    items.remove(key);
  }
}
