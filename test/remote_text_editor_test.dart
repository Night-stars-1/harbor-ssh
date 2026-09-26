import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/remote_text_editor.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late _FakeFiles files;
  late RemoteTextEditor editor;

  setUp(() {
    files = _FakeFiles();
    editor = RemoteTextEditor(files);
  });

  RemoteFile remote(
    String path, {
    bool isDirectory = false,
    bool isLink = false,
  }) {
    final name = path.split('/').last;
    return RemoteFile(
      name: name,
      path: path,
      isDirectory: isDirectory,
      isLink: isLink,
      size: files.data[path]?.length,
    );
  }

  test('读取严格 UTF-8 内容，拒绝链接、目录、超大与非法文本', () async {
    files.data['/note.txt'] = _bytes('你好\nworld');
    expect(await editor.load(remote('/note.txt')), '你好\nworld');

    files.data['/empty.txt'] = Uint8List(0);
    expect(await editor.load(remote('/empty.txt')), '');

    files.data['/bad.txt'] = Uint8List.fromList([0x41, 0xff, 0xfe]);
    await expectLater(
      editor.load(remote('/bad.txt')),
      throwsA(_stateErrorContaining('UTF-8')),
    );

    files.data['/nul.txt'] = _bytes('a\x00b');
    await expectLater(
      editor.load(remote('/nul.txt')),
      throwsA(_stateErrorContaining('NUL')),
    );

    files.data['/huge.txt'] = _bytes('small');
    await expectLater(
      editor.load(remote('/huge.txt').copyWith(size: remoteTextMaxBytes + 1)),
      throwsA(_stateErrorContaining('过大')),
    );

    files.data['/streamed.txt'] = Uint8List(remoteTextMaxBytes + 1);
    await expectLater(
      editor.load(remote('/streamed.txt').copyWith(size: null)),
      throwsA(_stateErrorContaining('过大')),
    );

    await expectLater(
      editor.load(remote('/note.txt', isDirectory: true)),
      throwsA(_stateErrorContaining('目录')),
    );
    await expectLater(
      editor.load(remote('/note.txt', isLink: true)),
      throwsA(_stateErrorContaining('符号链接')),
    );
  });

  test('保存发布 UTF-8 编辑内容并清理临时文件', () async {
    files.data['/note.txt'] = _bytes('hello');
    await editor.save(remote('/note.txt'), 'hello', '你好世界\n');

    expect(files.data['/note.txt'], _bytes('你好世界\n'));
    expect(files.temporaryPaths, isEmpty);
    expect(editor.leftoverBackupPath, isNull);
  });

  test('保存拒绝含 NUL 或超大的编辑内容，原件不变', () async {
    files.data['/note.txt'] = _bytes('hello');

    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'a\x00b'),
      throwsA(_stateErrorContaining('NUL')),
    );
    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'x' * (remoteTextMaxBytes + 1)),
      throwsA(_stateErrorContaining('过大')),
    );

    expect(files.data['/note.txt'], _bytes('hello'));
    expect(files.temporaryPaths, isEmpty);
  });

  test('外部修改内容时拒绝保存并保留对方内容', () async {
    files.data['/note.txt'] = _bytes('external');
    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'edited'),
      throwsA(_stateErrorContaining('外部修改')),
    );

    expect(utf8.decode(files.data['/note.txt']!), 'external');
    expect(files.temporaryPaths, isEmpty);
  });

  test('保存前文件被替换为链接时拒绝且不覆盖', () async {
    files.data['/note.txt'] = _bytes('hello');
    files.links.add('/note.txt');
    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'edited'),
      throwsA(_stateErrorContaining('普通文件')),
    );

    expect(utf8.decode(files.data['/note.txt']!), 'hello');
    expect(files.temporaryPaths, isEmpty);
  });

  test('暂存上传失败时保留原件且不留临时文件', () async {
    files.data['/note.txt'] = _bytes('hello');
    files.failUpload = true;
    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'edited'),
      throwsA(_stateErrorContaining('上传失败')),
    );

    expect(utf8.decode(files.data['/note.txt']!), 'hello');
    expect(files.temporaryPaths, isEmpty);
  });

  test('发布 rename 失败时回滚原件并清理临时文件', () async {
    files.data['/note.txt'] = _bytes('hello');
    files.failPublish = true;
    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'edited'),
      throwsA(_stateErrorContaining('发布失败')),
    );

    expect(utf8.decode(files.data['/note.txt']!), 'hello');
    expect(files.temporaryPaths, isEmpty);
  });

  test('备份 rename 成功但响应丢失时仍恢复原件', () async {
    files.data['/note.txt'] = _bytes('hello');
    files.failAfterBackupMove = true;
    await expectLater(
      editor.save(remote('/note.txt'), 'hello', 'edited'),
      throwsA(_stateErrorContaining('响应丢失')),
    );

    expect(utf8.decode(files.data['/note.txt']!), 'hello');
    expect(files.temporaryPaths, isEmpty);
  });

  test('备份清理失败时保存成功并保留可恢复路径', () async {
    files.data['/note.txt'] = _bytes('hello');
    files.failBackupDelete = true;
    await editor.save(remote('/note.txt'), 'hello', 'edited');

    expect(utf8.decode(files.data['/note.txt']!), 'edited');
    final leftover = editor.leftoverBackupPath;
    expect(leftover, isNotNull);
    expect(utf8.decode(files.data[leftover!]!), 'hello');
    expect(files.temporaryPaths, [leftover]);
  });

  test('取消后原件不变且不留临时文件', () async {
    files.data['/note.txt'] = _bytes('hello');
    final cancellation = TransferCancellation()..cancel();

    await expectLater(
      editor.load(remote('/note.txt'), cancellation: cancellation),
      throwsA(isA<TransferCancelled>()),
    );
    await expectLater(
      editor.save(
        remote('/note.txt'),
        'hello',
        'edited',
        cancellation: cancellation,
      ),
      throwsA(isA<TransferCancelled>()),
    );

    expect(utf8.decode(files.data['/note.txt']!), 'hello');
    expect(files.temporaryPaths, isEmpty);
  });
}

Matcher _stateErrorContaining(String text) => isA<StateError>().having(
  (error) => error.toString(),
  'message',
  contains(text),
);

extension on RemoteFile {
  RemoteFile copyWith({int? size}) => RemoteFile(
    name: name,
    path: path,
    isDirectory: isDirectory,
    isLink: isLink,
    size: size,
  );
}

class _FakeFiles implements RemoteFileSystem {
  final data = <String, Uint8List>{};
  final directories = <String>{'/'};
  final links = <String>{};

  bool failUpload = false;
  bool failPublish = false;
  bool failBackupDelete = false;
  bool failAfterBackupMove = false;

  Iterable<String> get temporaryPaths =>
      data.keys.where((path) => path.split('/').last.startsWith('.harbor-'));

  @override
  String childPath(String directory, String name) =>
      remoteChild(directory, name);

  @override
  Future<RemoteDirectory> browse(String path) async {
    final entries = <RemoteFile>[];
    for (final entry in data.entries) {
      if (remoteParent(entry.key) != path) continue;
      entries.add(
        RemoteFile(
          name: entry.key.split('/').last,
          path: entry.key,
          isLink: links.contains(entry.key),
          size: entry.value.length,
        ),
      );
    }
    for (final link in links) {
      if (data.containsKey(link) || remoteParent(link) != path) continue;
      entries.add(
        RemoteFile(name: link.split('/').last, path: link, isLink: true),
      );
    }
    for (final directory in directories) {
      if (directory == path || remoteParent(directory) != path) continue;
      entries.add(
        RemoteFile(
          name: directory.split('/').last,
          path: directory,
          isDirectory: true,
        ),
      );
    }
    return RemoteDirectory(path, entries);
  }

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    cancellation.check();
    final stored = data[path];
    if (stored == null) throw StateError('文件不存在');
    for (var offset = 0; offset < stored.length; offset += 4096) {
      cancellation.check();
      final chunk = Uint8List.sublistView(
        stored,
        offset,
        min(offset + 4096, stored.length),
      );
      await write(chunk);
      onProgress(offset + chunk.length);
    }
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    if (failUpload) throw StateError('上传失败');
    cancellation.check();
    if (data.containsKey(path) || directories.contains(path)) {
      throw StateError('目标已存在');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source) {
      cancellation.check();
      builder.add(chunk);
      onProgress(builder.length);
    }
    cancellation.check();
    data[path] = builder.takeBytes();
  }

  @override
  Future<void> renameExclusive(String oldPath, String newPath) async {
    final name = oldPath.split('/').last;
    final staged = name.startsWith('.harbor-incoming-');
    final backup = name.startsWith('.harbor-backup-');
    if (failPublish && staged) throw StateError('发布失败');
    if (data.containsKey(newPath) || directories.contains(newPath)) {
      throw StateError('目标已存在');
    }
    final stored = data.remove(oldPath);
    if (stored == null) throw StateError('源文件不存在');
    links.remove(oldPath);
    data[newPath] = stored;
    if (failAfterBackupMove && !staged && !backup) {
      failAfterBackupMove = false;
      throw StateError('备份响应丢失');
    }
  }

  @override
  Future<void> deleteFile(String path) async {
    if (failBackupDelete &&
        path.split('/').last.startsWith('.harbor-backup-')) {
      throw StateError('权限不足');
    }
    if (data.remove(path) == null) throw StateError('文件不存在');
  }

  @override
  Future<void> createDirectory(String path) async {
    if (data.containsKey(path) || directories.contains(path)) {
      throw StateError('目标已存在');
    }
    directories.add(path);
  }

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) async {
    if (!directories.remove(path)) throw StateError('目录不存在');
    final prefix = '$path/';
    data.removeWhere((key, _) => key.startsWith(prefix));
    directories.removeWhere((key) => key.startsWith(prefix));
  }
}
