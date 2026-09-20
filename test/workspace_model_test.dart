import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  test('编辑配置失败时恢复原有凭据', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveHost(testHost, const Credentials(password: 'original'));
    (repository.preferences as MemoryStore).failWrites = true;
    await expectLater(
      model.saveHost(testHost, const Credentials(password: 'replacement')),
      throwsStateError,
    );
    expect((await repository.credentials(testHost.id))!.password, 'original');
    model.dispose();
  });
  test('保存、查询、分组、收藏和删除均持久化', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveHost(testHost, const Credentials(password: 'example'));
    expect(model.groups, ['开发']);
    model.search('DEV.EXAMPLE');
    expect(model.filteredHosts.single.id, testHost.id);
    model.search('missing');
    expect(model.filteredHosts, isEmpty);
    model.search('');
    model.filter(favorites: true);
    expect(model.filteredHosts, isEmpty);
    await model.toggleFavorite(testHost);
    expect(model.filteredHosts.single.favorite, isTrue);
    final reloaded = WorkspaceModel(repository);
    await reloaded.initialize();
    expect(reloaded.hosts.single.favorite, isTrue);
    await model.deleteHost(testHost);
    expect(model.hosts, isEmpty);
    expect(await repository.credentials(testHost.id), isNull);
    model.dispose();
    reloaded.dispose();
  });
  test('保存、查询和删除用户均持久化', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    const user = SshUser(id: 'user-1', name: '生产部署', username: 'deploy');
    await model.saveUser(user, const Credentials(password: 'example'));
    model.filter(users: true);
    model.search('DEPLOY');
    expect(model.filteredUsers.single.id, user.id);
    model.search('missing');
    expect(model.filteredUsers, isEmpty);
    final reloaded = WorkspaceModel(repository);
    await reloaded.initialize();
    expect(reloaded.users.single.name, '生产部署');
    expect((await repository.userCredentials(user.id))!.password, 'example');
    await model.deleteUser(user);
    expect(model.users, isEmpty);
    expect(await repository.userCredentials(user.id), isNull);
    model.dispose();
    reloaded.dispose();
  });
  test('保存失败不把未保存配置显示为成功', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    (repository.preferences as MemoryStore).failWrites = true;
    await expectLater(model.saveHost(testHost, null), throwsStateError);
    expect(model.hosts, isEmpty);
    expect(model.saving, isFalse);
    model.dispose();
  });
  test('损坏配置提示错误且不覆盖原数据', () async {
    final repository = memoryRepository();
    (repository.preferences as MemoryStore).values['harbor.hosts.v1'] =
        'broken';
    final model = WorkspaceModel(repository);
    await model.initialize();
    expect(model.loadError, isNotNull);
    expect(
      (repository.preferences as MemoryStore).values['harbor.hosts.v1'],
      'broken',
    );
    model.dispose();
  });
}
