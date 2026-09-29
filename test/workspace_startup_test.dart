import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

class _FailingStore extends MemoryStore {
  String? failingKey;
  Object? failure;

  @override
  Future<String?> read(String key) async {
    if (key == failingKey && failure != null) throw failure!;
    return super.read(key);
  }
}

void main() {
  test('钥匙串恢复失败保留数据并阻止同步，授权恢复后可重试', () async {
    final preferences = MemoryStore();
    final secrets = _FailingStore();
    final repository = HostRepository(
      preferences: preferences,
      secrets: secrets,
    );
    await repository.saveHosts([testHost]);
    await repository.saveCredentials(
      testHost.id,
      const Credentials(password: 'saved-password'),
    );
    final originalPreferences = Map.of(preferences.values);
    final originalSecrets = Map.of(secrets.values);
    secrets
      ..failingKey = 'harbor.sync.pending.v1'
      ..failure = PlatformException(
        code: 'Unexpected security result code',
        details: -34018,
      );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);

    await model.initialize();
    expect(model.loading, isFalse);
    expect(model.loadError, contains('凭据与同步恢复'));
    expect(model.loadError, contains('-34018'));
    expect(preferences.values, originalPreferences);
    expect(secrets.values, originalSecrets);
    await expectLater(model.syncNow(), throwsA(isA<SyncFailure>()));

    secrets.failure = null;
    await model.initialize();
    expect(model.loadError, isNull);
    expect(model.hosts.single.id, testHost.id);
    expect(
      (await repository.credentials(testHost.id))!.password,
      'saved-password',
    );
    expect(preferences.values, originalPreferences);
    expect(secrets.values, originalSecrets);
  });

  test('损坏的用户配置不展示半份主机数据或覆盖原数据', () async {
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final preferences = repository.preferences as MemoryStore;
    preferences.values['harbor.users.v1'] = '{invalid-sensitive-json';
    final original = Map.of(preferences.values);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);

    await model.initialize();
    expect(model.loadError, contains('用户配置'));
    expect(model.loadError, contains('格式无法解析'));
    expect(model.loadError, isNot(contains('sensitive')));
    expect(model.hosts, isEmpty);
    expect(preferences.values, original);
    await expectLater(model.syncNow(), throwsA(isA<SyncFailure>()));
  });

  test('本地路径存储失败不会误报为钥匙串或主机配置问题', () async {
    final preferences = _FailingStore()
      ..failingKey = 'harbor.files.default-local-path.v1'
      ..failure = PlatformException(code: 'storage-failure');
    final repository = HostRepository(
      preferences: preferences,
      secrets: MemoryStore(),
    );
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    expect(model.loadError, contains('本地文件目录'));
    expect(model.loadError, isNot(contains('钥匙串')));
  });
}
