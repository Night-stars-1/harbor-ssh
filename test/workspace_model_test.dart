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
  test('保存、查询、标签、收藏和删除均持久化', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveHost(testHost, const Credentials(password: 'example'));
    expect(model.tags, ['开发']);
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
  test('标签全集去重排序且空标签不产生标签', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    for (final host in const [
      Host(
        id: 'host-a',
        name: 'A',
        address: 'a.example.com',
        username: 'deploy',
        tags: ['test', 'dev'],
      ),
      Host(
        id: 'host-b',
        name: 'B',
        address: 'b.example.com',
        username: 'deploy',
        tags: ['dev', 'prod'],
      ),
      Host(
        id: 'host-c',
        name: 'C',
        address: 'c.example.com',
        username: 'deploy',
      ),
    ]) {
      await model.saveHost(host, null);
    }
    expect(model.tags, ['dev', 'prod', 'test']);
    model.dispose();
  });
  test('按任一标签筛中多标签主机并搜索非首个标签', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    const multi = Host(
      id: 'host-multi',
      name: '构建机',
      address: 'build.internal',
      username: 'deploy',
      tags: ['dev', '夜间构建'],
    );
    const ops = Host(
      id: 'host-ops',
      name: '运维机',
      address: 'ops.internal',
      username: 'deploy',
      tags: ['夜间构建'],
    );
    await model.saveHost(multi, null);
    await model.saveHost(ops, null);
    model.filter(tag: 'dev');
    expect(model.filteredHosts.single.id, multi.id);
    model.filter(tag: '夜间构建');
    expect(
      model.filteredHosts.map((host) => host.id).toSet(),
      {'host-multi', 'host-ops'},
    );
    model.filter();
    model.search('夜间构建');
    expect(model.filteredHosts.map((host) => host.id).toSet(), {'host-multi', 'host-ops'});
    model.search('dev');
    expect(model.filteredHosts.single.id, multi.id);
    model.search('');
    model.filter(tag: 'missing');
    expect(model.filteredHosts, isEmpty);
    model.dispose();
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
