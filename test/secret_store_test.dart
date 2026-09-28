import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';

void main() {
  test('多次写入只保留一个钥匙串项', () async {
    final backend = _Backend();
    final store = SecretStore(backend: backend);

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
    final store = SecretStore(backend: backend);

    expect(await store.read('harbor.ai.v1'), 'settings');
    expect(backend.items.keys, [SecretStore.bundleKey]);
    expect(backend.readAlls, 1);

    final reopened = SecretStore(backend: backend);
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
    final store = SecretStore(backend: backend);

    await expectLater(store.read('harbor.ai.v1'), throwsFormatException);
    expect(backend.items[SecretStore.bundleKey], 'not-json');
    expect(backend.writes, isEmpty);
  });
}

class _Backend implements SecretBackend {
  final items = <String, String>{};
  final writes = <String>[];
  var reads = 0;
  var readAlls = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return items[key];
  }

  @override
  Future<void> write(String key, String value) async {
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
