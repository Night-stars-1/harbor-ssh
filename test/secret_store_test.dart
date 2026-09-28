import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';

void main() {
  test('Windows 默认保留旧版可读取的逐项存储', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final backend = _Backend();
    final store = SecretStore(backend: backend);
    await store.write('harbor.credentials.user.key', 'private-key');
    expect(await backend.read('harbor.credentials.user.key'), 'private-key');
    expect(backend.items.containsKey(SecretStore.bundleKey), isFalse);
    expect(backend.readAlls, 0);
  });

  test('macOS 默认继续使用单条钥匙串记录', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final backend = _Backend();
    await SecretStore(backend: backend).write('key', 'value');
    expect(backend.items.keys, [SecretStore.bundleKey]);
  });

  test('逐项模式拆回 1.0.10 存档，旧版立即可读且保留其较新记录', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({
        'harbor.credentials.user.key': 'private-key',
        'harbor.sync.settings.v1': 'older-settings',
      })
      ..items['harbor.sync.settings.v1'] = 'newer-settings';
    final store = SecretStore(backend: backend, useBundle: false);
    expect(await store.read('harbor.credentials.user.key'), 'private-key');
    expect(await backend.read('harbor.credentials.user.key'), 'private-key');
    expect(await store.read('harbor.sync.settings.v1'), 'newer-settings');
    expect(backend.items.containsKey(SecretStore.bundleKey), isFalse);
  });

  test('拆回逐项存储失败保留原存档，重试不覆盖已写入的新值', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({
        'first': 'one',
        'second': 'two',
      })
      ..failWriteKey = 'second';
    final store = SecretStore(backend: backend, useBundle: false);
    await expectLater(store.read('first'), throwsStateError);
    expect(backend.items.containsKey(SecretStore.bundleKey), isTrue);
    expect(backend.items['first'], 'one');
    backend.items['first'] = 'updated-by-legacy';
    backend.failWriteKey = null;
    expect(await store.read('first'), 'updated-by-legacy');
    expect(await store.read('second'), 'two');
    expect(backend.items.containsKey(SecretStore.bundleKey), isFalse);
  });

  test('逐项模式每次读取最新值，不以旧缓存覆盖其他客户端的凭据', () async {
    final backend = _Backend()..items['key'] = 'one';
    final store = SecretStore(backend: backend, useBundle: false);
    expect(await store.read('key'), 'one');
    await backend.write('key', 'changed-by-legacy');
    await store.write('other', 'value');
    expect(await store.read('key'), 'changed-by-legacy');
    await store.delete('key');
    expect(await backend.read('key'), isNull);
    expect(await store.read('other'), 'value');
  });

  test('损坏存档不能在拆分迁移时被删除或覆盖', () async {
    final backend = _Backend()..items[SecretStore.bundleKey] = 'corrupt';
    final store = SecretStore(backend: backend, useBundle: false);
    await expectLater(store.write('key', 'value'), throwsFormatException);
    expect(backend.items, {SecretStore.bundleKey: 'corrupt'});
    expect(backend.writes, isEmpty);
  });

  test('多次写入只保留一个钥匙串项', () async {
    final backend = _Backend();
    final store = SecretStore(backend: backend, useBundle: true);

    await store.write('harbor.credentials.a', 'one');
    await store.write('harbor.credentials.b', 'two');
    await store.write('harbor.credentials.a', 'one');

    expect(backend.items.keys, [SecretStore.bundleKey]);
    expect(await store.read('harbor.credentials.a'), 'one');
    expect(await store.read('harbor.credentials.b'), 'two');
    expect(backend.reads, 1);
    expect(backend.readAlls, 1);
  });

  test('旧的逐条记录合并进同一个项后删除', () async {
    final backend = _Backend()
      ..items['harbor.credentials.a'] = '{"password":"secret"}'
      ..items['harbor.ai.v1'] = 'settings';
    final store = SecretStore(backend: backend, useBundle: true);

    expect(await store.read('harbor.ai.v1'), 'settings');
    expect(backend.items.keys, [SecretStore.bundleKey]);
    expect(backend.readAlls, 1);

    final reopened = SecretStore(backend: backend, useBundle: true);
    expect(
      await reopened.read('harbor.credentials.a'),
      '{"password":"secret"}',
    );
    expect(backend.readAlls, 1, reason: '已有存档时不再逐条读取旧记录');

    await reopened.delete('harbor.credentials.a');
    expect(await reopened.read('harbor.credentials.a'), isNull);
    expect(await reopened.read('harbor.ai.v1'), 'settings');
    expect(backend.items.keys, [SecretStore.bundleKey]);
  });

  test('损坏的存档不会被空数据覆盖', () async {
    final backend = _Backend()..items[SecretStore.bundleKey] = 'not-json';
    final store = SecretStore(backend: backend, useBundle: true);

    await expectLater(store.read('harbor.ai.v1'), throwsFormatException);
    expect(backend.items[SecretStore.bundleKey], 'not-json');
    expect(backend.writes, isEmpty);
  });

  test('已有存档漏掉的旧凭据按键读取并迁移，保留其他记录', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({'harbor.ai.v1': 'settings'})
      ..items['harbor.credentials.user.key'] = 'saved-private-key';
    final store = SecretStore(backend: backend, useBundle: true);
    expect(
      await store.read('harbor.credentials.user.key'),
      'saved-private-key',
    );
    expect(await store.read('harbor.ai.v1'), 'settings');
    expect(backend.items.keys, [SecretStore.bundleKey]);
    expect(backend.readAlls, 0);
    final reopened = SecretStore(backend: backend, useBundle: true);
    expect(
      await reopened.read('harbor.credentials.user.key'),
      'saved-private-key',
    );
  });

  test('迁移保存失败时保留旧凭据并允许重试', () async {
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = '{}'
      ..items['harbor.credentials.user.key'] = 'saved-private-key'
      ..failWrites = true;
    final store = SecretStore(backend: backend, useBundle: true);
    await expectLater(
      store.read('harbor.credentials.user.key'),
      throwsStateError,
    );
    expect(backend.items['harbor.credentials.user.key'], 'saved-private-key');
    backend.failWrites = false;
    expect(
      await store.read('harbor.credentials.user.key'),
      'saved-private-key',
    );
    expect(backend.items.keys, [SecretStore.bundleKey]);
  });

  test('存档中已更新的凭据优先于残留旧记录，删除后不会复活', () async {
    const key = 'harbor.credentials.user.key';
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = jsonEncode({key: 'new'})
      ..items[key] = 'old';
    final store = SecretStore(backend: backend, useBundle: true);
    expect(await store.read(key), 'new');
    await store.delete(key);
    expect(await store.read(key), isNull);
    expect(
      await SecretStore(backend: backend, useBundle: true).read(key),
      isNull,
    );
  });

  test('删除未迁移的旧凭据不会被后续读取恢复', () async {
    const key = 'harbor.credentials.user.key';
    final backend = _Backend()
      ..items[SecretStore.bundleKey] = '{}'
      ..items[key] = 'old';
    final store = SecretStore(backend: backend, useBundle: true);
    await store.delete(key);
    expect(await store.read(key), isNull);
    expect(backend.items.keys, [SecretStore.bundleKey]);
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
  var reads = 0;
  var readAlls = 0;
  var failWrites = false;
  String? failWriteKey;

  @override
  Future<String?> read(String key) async {
    reads++;
    return items[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites || failWriteKey == key) {
      throw StateError('storage unavailable');
    }
    writes.add(key);
    items[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    items.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    readAlls++;
    return Map<String, String>.from(items);
  }
}
