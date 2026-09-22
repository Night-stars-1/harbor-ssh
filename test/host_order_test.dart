import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

const _alpha = Host(
  id: 'alpha',
  name: 'Alpha',
  address: 'alpha.example.com',
  username: 'root',
);
const _bravo = Host(
  id: 'bravo',
  name: 'Bravo',
  address: 'bravo.example.com',
  username: 'root',
  favorite: true,
);
const _charlie = Host(
  id: 'charlie',
  name: 'Charlie',
  address: 'charlie.example.com',
  username: 'root',
);

List<String> _ids(WorkspaceModel model) =>
    model.filteredHosts.map((h) => h.id).toList();

String? _stored(WorkspaceModel model) =>
    (model.repository.preferences as MemoryStore)
        .values['harbor.host-order.v1'];

void main() {
  test('未手动排序时保持收藏优先再按名称，不写入本地顺序', () async {
    final repository = memoryRepository();
    await repository.saveHosts([_alpha, _bravo, _charlie]);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    expect(_ids(model), ['bravo', 'alpha', 'charlie']);
    expect(_stored(model), isNull);
  });

  test('重排后按本地顺序排序、持久化并在重载后保留', () async {
    final repository = memoryRepository();
    await repository.saveHosts([_alpha, _bravo, _charlie]);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    await model.reorderHost('charlie', 'bravo');
    expect(_ids(model), ['charlie', 'bravo', 'alpha']);

    final reloaded = WorkspaceModel(repository);
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(_ids(reloaded), ['charlie', 'bravo', 'alpha']);

    // A host added after manual ordering is appended, not inserted by name.
    const zeta = Host(
      id: 'zeta',
      name: 'AAA',
      address: 'zeta.example.com',
      username: 'root',
    );
    await reloaded.saveHost(zeta, null);
    expect(_ids(reloaded), ['charlie', 'bravo', 'alpha', 'zeta']);
  });

  test('过滤子集重排只重排可见槽位，隐藏主机保持原有位置', () async {
    final repository = memoryRepository();
    const a = Host(
      id: 'a',
      name: 'A',
      address: 'a.example.com',
      username: 'root',
    );
    const b = Host(
      id: 'b',
      name: 'B',
      address: 'b.example.com',
      username: 'root',
      tags: ['prod'],
    );
    const c = Host(
      id: 'c',
      name: 'C',
      address: 'c.example.com',
      username: 'root',
    );
    const d = Host(
      id: 'd',
      name: 'D',
      address: 'd.example.com',
      username: 'root',
      tags: ['prod'],
    );
    await repository.saveHosts([a, b, c, d]);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    model.filter(tag: 'prod');
    expect(_ids(model), ['b', 'd']);
    await model.reorderHost('d', 'b');
    expect(_ids(model), ['d', 'b']);
    model.filter();
    expect(_ids(model), ['a', 'd', 'c', 'b']);
  });

  test('未知或重复的旧ID被忽略，删除主机不影响后续重排', () async {
    final repository = memoryRepository();
    (repository.preferences as MemoryStore).values['harbor.host-order.v1'] =
        '["ghost","alpha","bravo","charlie","alpha",42]';
    await repository.saveHosts([_alpha, _bravo, _charlie]);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    expect(_ids(model), ['alpha', 'bravo', 'charlie']);
    await model.deleteHost(_bravo);
    await model.reorderHost('charlie', 'alpha');
    expect(_ids(model), ['charlie', 'alpha']);
  });

  test('本地顺序写入失败时保留原顺序', () async {
    final repository = memoryRepository();
    await repository.saveHosts([_alpha, _bravo, _charlie]);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    (repository.preferences as MemoryStore).failWrites = true;
    await expectLater(model.reorderHost('charlie', 'bravo'), throwsStateError);
    expect(model.saving, isFalse);
    expect(_ids(model), ['bravo', 'alpha', 'charlie']);
    expect(_stored(model), isNull);
  });

  test('本地顺序不写入主机数据或同步快照', () async {
    final repository = memoryRepository();
    await repository.saveHosts([_alpha, _bravo, _charlie]);
    final model = WorkspaceModel(repository);
    addTearDown(model.dispose);
    await model.initialize();
    final storage = SyncStorage(repository);
    final before = await storage.capture();
    await model.reorderHost('charlie', 'bravo');
    final after = await storage.capture();
    expect(after.records, before.records);
  });
}
