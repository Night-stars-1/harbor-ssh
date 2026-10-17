import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/local_files.dart';
import 'package:harbor_ssh/ui/file_workspace_model.dart';

/// 操作系统拖入的顶层项目是绝对路径，可能来自不同目录；目标用真实的
/// [LocalFiles]，这样字节、空目录和断点续传都走和 SFTP 完全相同的路径。
void main() {
  // 本地目录的独占创建会先试平台通道，测试里必须已经初始化绑定，才能拿到
  // MissingPluginException 并退回 dart:io。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory target;
  late FileWorkspaceModel model;
  late FileLocationTab destination;
  late int released;

  /// 有的用例自己关闭工作区（关闭状态是 ChangeNotifier 的一次性状态），
  /// 此时 tearDown 不能再关一次。
  late bool modelDisposed;

  String joined(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('harbor-external-drop-');
    target = await Directory('${root.path}/target').create();
    model = FileWorkspaceModel();
    destination = model.add(
      1,
      name: 'target',
      files: LocalFiles(target.path),
      isLocal: true,
      initialPath: target.path,
    );
    await destination.browse();
    released = 0;
    modelDisposed = false;
  });

  tearDown(() async {
    if (!modelDisposed) model.dispose();
    await root.delete(recursive: true);
  });

  Future<void> release() async {
    released++;
  }

  /// 拖入一批项目并让传输暂停在断点处，返回批次和已经写进目标的字节。
  Future<(FileDragData, Uint8List)> pauseDrop(
    Directory source,
    Uint8List payload,
  ) async {
    await File(joined(source.path, 'data.bin')).writeAsBytes(payload);
    final data = await model.prepareExternalDrop([
      joined(source.path, 'data.bin'),
    ], release: release);
    var paused = false;
    void interrupt() {
      if (!paused && model.transfer != null && model.transferred > 0) {
        paused = true;
        model.cancel();
      }
    }

    model.addListener(interrupt);
    expect(await model.drop(data, destination), isFalse);
    model.removeListener(interrupt);
    expect(model.canResume, isTrue, reason: model.message);
    return (data, payload);
  }

  test('外部拖入多目录文件与空文件夹：字节一致、空目录保留、不新增可见标签', () async {
    final one = Directory('${root.path}/one')..createSync();
    final two = Directory('${root.path}/two')..createSync();
    final empty = Directory('${two.path}/empty')..createSync();
    final payload = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    await File(joined(one.path, 'a.bin')).writeAsBytes(payload);
    await File(joined(two.path, 'nested.txt')).writeAsString('嵌套');
    final visible = List<FileLocationTab>.of(model.tabs);
    final active = model.activeTab;

    final data = await model.prepareExternalDrop([
      joined(one.path, 'a.bin'),
      empty.path,
      joined(two.path, 'nested.txt'),
    ], release: release);

    // 准备只读取元数据：没有导航、没有激活、也没有新增标签。
    expect(model.tabs, visible);
    expect(identical(model.activeTab, active), isTrue);
    expect(model.tabs.contains(data.source), isFalse);
    expect(data.files.map((file) => file.name).toSet(), {
      'a.bin',
      'empty',
      'nested.txt',
    });
    expect(
      data.files.singleWhere((file) => file.name == 'a.bin').size,
      payload.length,
    );
    expect(
      data.files.singleWhere((file) => file.name == 'empty').isDirectory,
      isTrue,
    );
    expect(data.source.isLocal, isTrue);
    expect(model.canAcceptExternalDrop(destination), isTrue);
    expect(model.canDrop(data, destination), isTrue);

    expect(await model.drop(data, destination), isTrue);
    expect(model.failed, isFalse);
    expect(await File('${target.path}/a.bin').readAsBytes(), payload);
    expect(await File('${target.path}/nested.txt').readAsString(), '嵌套');
    expect(await Directory('${target.path}/empty').exists(), isTrue);
    expect(await Directory('${target.path}/empty').list().toList(), isEmpty);
    expect(model.tabs, visible);

    // 传输成功已经释放过一次；界面在 finally 里的释放不会再释放一次。
    expect(released, 1);
    model.releaseExternalDrop(data);
    expect(released, 1);
    expect(model.canDrop(data, destination), isFalse);
    expect(model.canAcceptExternalDrop(null), isFalse);
  });

  test('批次内的同名目标在准备阶段被拒绝，目标目录一个字节都没写', () async {
    final one = Directory('${root.path}/one')..createSync();
    final two = Directory('${root.path}/two')..createSync();
    await File(joined(one.path, 'same.txt')).writeAsString('a');
    await File(joined(two.path, 'same.txt')).writeAsString('b');
    final visible = List<FileLocationTab>.of(model.tabs);
    final active = model.activeTab;

    await expectLater(
      model.prepareExternalDrop([
        joined(one.path, 'same.txt'),
        joined(two.path, 'same.txt'),
      ], release: release),
      throwsA(isA<FileSystemException>()),
    );

    expect(model.tabs, visible);
    expect(identical(model.activeTab, active), isTrue);
    expect(await target.list().toList(), isEmpty);
    expect(model.canResume, isFalse);
    expect(model.message, isNull);
    // 准备失败也要释放系统资源，界面在 finally 里的释放是幂等的。
    expect(released, 1);
  });

  test('同名比较按目标的命名规则：本地 Windows 目标拒绝只差大小写的批次', () async {
    final one = Directory('${root.path}/one')..createSync();
    final two = Directory('${root.path}/two')..createSync();
    await File(joined(one.path, 'Same.txt')).writeAsString('a');
    await File(joined(two.path, 'same.txt')).writeAsString('b');

    final data = await model.prepareExternalDrop([
      joined(one.path, 'Same.txt'),
      joined(two.path, 'same.txt'),
    ], release: release);

    expect(
      model.canDrop(data, destination),
      Platform.isWindows ? isFalse : isTrue,
    );
    if (Platform.isWindows) {
      expect(await model.drop(data, destination), isFalse);
      expect(await target.list().toList(), isEmpty);
    }
    model.releaseExternalDrop(data);
    expect(released, 1);
  });

  test('空批次、不存在的项目、符号链接与磁盘根目录都被拒绝并释放系统资源', () async {
    final visible = List<FileLocationTab>.of(model.tabs);
    await expectLater(
      model.prepareExternalDrop(const [], release: release),
      throwsA(isA<FileSystemException>()),
    );
    expect(released, 1);
    await expectLater(
      model.prepareExternalDrop([
        joined(root.path, 'missing.txt'),
      ], release: release),
      throwsA(isA<FileSystemException>()),
    );
    expect(released, 2);
    await expectLater(
      model.prepareExternalDrop([
        Platform.isWindows ? 'C:/' : '/',
      ], release: release),
      throwsA(isA<FileSystemException>()),
    );
    expect(released, 3);
    expect(model.tabs, visible);
    expect(model.canResume, isFalse);

    final real = await File(joined(root.path, 'real.txt')).writeAsString('x');
    final link = joined(root.path, 'link.txt');
    var linked = false;
    try {
      await Link(link).create(real.path);
      linked = true;
    } on FileSystemException {
      // Windows 上创建符号链接需要额外权限，拿不到就跳过这一段断言。
    }
    if (linked) {
      await expectLater(
        model.prepareExternalDrop([link], release: release),
        throwsA(isA<FileSystemException>()),
      );
      expect(released, 4);
    }
  });

  test('暂停的传输保留外部源并可以继续，继续成功后只释放一次', () async {
    final source = Directory('${root.path}/source')..createSync();
    final payload = Uint8List.fromList(
      List.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
    );
    final (data, _) = await pauseDrop(source, payload);

    expect(model.message, '传输已暂停 · 可继续传输');
    expect(model.canContinue, isTrue);
    expect(model.canAcceptExternalDrop(destination), isFalse);
    // 界面确认之后照常释放，但断点仍在使用这个源。
    model.releaseExternalDrop(data);
    expect(released, 0);

    await model.resume();
    expect(model.canResume, isFalse, reason: model.message);
    expect(model.message, '已传输 1 个项目');
    expect(await File('${target.path}/data.bin').readAsBytes(), payload);
    expect(released, 1);
    // 源已经释放，同一个批次不能再落到任何目标上。
    expect(model.canDrop(data, destination), isFalse);
    model.releaseExternalDrop(data);
    expect(released, 1);
  });

  test('放弃断点清理缓存、只释放一次，并让源退出保留', () async {
    final source = Directory('${root.path}/source')..createSync();
    final payload = Uint8List.fromList(
      List.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
    );
    final (data, _) = await pauseDrop(source, payload);

    model.releaseExternalDrop(data);
    expect(released, 0);

    await model.discardTransfer();
    expect(model.canResume, isFalse);
    expect(model.message, '已放弃传输并清理缓存');
    expect(released, 1);
    // 暂存文件被清理，目标目录回到原始状态。
    expect(await target.list().toList(), isEmpty);
    expect(model.canDrop(data, destination), isFalse);
  });

  test('工作区关闭时释放尚未使用的隐藏源', () async {
    final other = FileWorkspaceModel();
    final file = await File(joined(root.path, 'idle.txt')).writeAsString('x');
    await other.prepareExternalDrop([file.path], release: release);
    expect(released, 0);
    other.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(released, 1);
  });

  test('被同名拒绝的拖入不留下隐藏源，界面 finally 的释放就是最后一次', () async {
    final source = Directory('${root.path}/source')..createSync();
    await File(joined(source.path, 'taken.txt')).writeAsString('new');
    await File(joined(target.path, 'taken.txt')).writeAsString('keep');
    await destination.browse();

    final data = await model.prepareExternalDrop([
      joined(source.path, 'taken.txt'),
    ], release: release);
    expect(model.canDrop(data, destination), isTrue);
    expect(await model.drop(data, destination), isFalse);
    expect(model.message, '目标目录存在同名项目');
    expect(await File('${target.path}/taken.txt').readAsString(), 'keep');
    // 同名拒绝没有建立断点，所以源由界面 finally 的释放直接回收。
    expect(model.canResume, isFalse);
    model.releaseExternalDrop(data);
    expect(released, 1);
    expect(model.canDrop(data, destination), isFalse);
  });

  test('拖入的批次不能落回它自己所在的目录', () async {
    final resolved = await target.resolveSymbolicLinks();
    await File(joined(resolved, 'here.txt')).writeAsString('x');
    final data = await model.prepareExternalDrop([
      joined(resolved, 'here.txt'),
    ], release: release);
    expect(model.canDrop(data, destination), isFalse);
    expect(await model.drop(data, destination), isFalse);
    expect(await File('${target.path}/here.txt').readAsString(), 'x');
    model.releaseExternalDrop(data);
    expect(released, 1);
  });

  test('工作区关闭时保留正在传输的外部源，等传输退出后再释放', () async {
    final source = Directory('${root.path}/source')..createSync();
    final payload = Uint8List.fromList(List.generate(1 << 20, (i) => i % 251));
    await File(joined(source.path, 'data.bin')).writeAsBytes(payload);
    final data = await model.prepareExternalDrop([
      joined(source.path, 'data.bin'),
    ], release: release);
    expect(model.canDrop(data, destination), isTrue);

    // 传输刚进入第一次挂起点，本地的读取还在用它；此刻关闭工作区。
    final operation = model.drop(data, destination);
    expect(model.transfer, isNotNull);
    modelDisposed = true;
    model.dispose();
    // 读取还在进行，系统作用域不能提前停掉。
    expect(released, 0);

    expect(await operation, isFalse);
    // 传输退出之后才释放，而且关闭后不再保留断点。
    expect(released, 1);
    expect(model.canResume, isFalse);
    expect(model.canDrop(data, destination), isFalse);
  });

  test('暂停的断点在关闭工作区时立即释放外部源', () async {
    final source = Directory('${root.path}/source')..createSync();
    final payload = Uint8List.fromList(
      List.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
    );
    final (data, _) = await pauseDrop(source, payload);
    expect(model.canResume, isTrue);

    modelDisposed = true;
    model.dispose();
    // 暂停的源没有读取在用，关闭时立刻释放，断点也不再保留。
    expect(released, 1);
    expect(model.canResume, isFalse);
    expect(model.canDrop(data, destination), isFalse);
  });

  test('放弃传输途中关闭工作区只释放一次，清理照常完成', () async {
    final source = Directory('${root.path}/source')..createSync();
    final payload = Uint8List.fromList(
      List.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
    );
    final (data, _) = await pauseDrop(source, payload);
    model.releaseExternalDrop(data);
    expect(released, 0);

    // 放弃只清理目标侧的缓存，源没有本地读取在用，所以关闭时可以先释放。
    final discarding = model.discardTransfer();
    modelDisposed = true;
    model.dispose();
    expect(released, 1);

    await discarding;
    expect(released, 1);
    expect(await target.list().toList(), isEmpty);
  });

  test('内部拖动照常工作，外部源的释放不影响它', () async {
    final source = Directory('${root.path}/source')..createSync();
    await File(joined(source.path, 'internal.bin')).writeAsBytes([1, 2, 3, 4]);
    final internal = model.add(
      0,
      name: 'source',
      files: LocalFiles(source.path),
      isLocal: true,
      initialPath: source.path,
    );
    await internal.browse();
    final data = model.dragData(internal, internal.entries.single);
    expect(model.canDrop(data, destination), isTrue);
    expect(await model.drop(data, destination), isTrue);
    expect(await File('${target.path}/internal.bin').readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
    expect(released, 0);

    // 内部批次不是外部源，释放调用直接忽略，标签照旧留在面板里。
    model.releaseExternalDrop(data);
    expect(released, 0);
    expect(model.tabs.contains(internal), isTrue);

    // 同名再次拖入仍走原来的确认流程，而不是被当成批次内重名。
    expect(model.canDrop(data, destination), isTrue);
    expect(await model.drop(data, destination), isFalse);
    expect(model.message, '目标目录存在同名项目');
    expect(await File('${target.path}/internal.bin').readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
  });
}
