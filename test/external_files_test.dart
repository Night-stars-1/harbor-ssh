import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/external_files.dart';
import 'package:harbor_ssh/domain/remote_file.dart';

import 'file_workspace_test.dart' show MemoryFiles;

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory temp;
  late MemoryFiles files;
  late List<String> launched;
  late ExternalEdits edits;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('harbor-external-test-');
    files = MemoryFiles()..data['/etc/app.conf'] = _bytes('port=80\n');
    files.directories.add('/etc');
    launched = [];
    edits = ExternalEdits(
      launch: (path) async => launched.add(path),
      temporaryDirectory: () async => temp,
      pollInterval: const Duration(hours: 1),
      syncBack: true,
    );
  });

  tearDown(() async {
    edits.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  const remote = RemoteFile(name: 'app.conf', path: '/etc/app.conf', size: 8);

  /// One poll records the new size/time, the next uploads once it is stable.
  Future<void> settle(ExternalEditSession session) async {
    await session.check();
    await session.check();
  }

  test('外部保存后回传远端，未改动或改动尚未稳定时不上传', () async {
    final session = await edits.openRemote(files, remote);
    expect(session.status, ExternalEditStatus.synced);
    expect(launched, [session.local.path]);
    expect(await session.local.readAsString(), 'port=80\n');

    // Unchanged copy: nothing is uploaded.
    await settle(session);
    expect(files.data.keys, ['/etc/app.conf']);

    await session.local.writeAsString('port=8080\n');
    await session.check();
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=80\n');
    await session.check();
    expect(session.status, ExternalEditStatus.synced);
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=8080\n');
    // Published through a staged file: no temporaries are left behind.
    expect(files.data.keys, ['/etc/app.conf']);

    // A second save is uploaded against the newly synced content.
    await session.local.writeAsString('port=9090\n');
    await settle(session);
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=9090\n');

    // Opening the same file again reuses the session and only relaunches.
    expect(identical(await edits.openRemote(files, remote), session), isTrue);
    expect(launched, [session.local.path, session.local.path]);
  });

  test('远端被其他人修改时不覆盖，确认后才强制上传', () async {
    final session = await edits.openRemote(files, remote);
    files.data['/etc/app.conf'] = _bytes('port=81\n');
    await session.local.writeAsString('port=8080\n');
    await settle(session);
    expect(session.status, ExternalEditStatus.conflict);
    expect(session.error.toString(), contains('已被其他人修改'));
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=81\n');

    // Further polls never retry a conflicting upload on their own.
    await session.local.writeAsString('port=8081\n');
    await settle(session);
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=81\n');

    await session.upload(overwrite: true);
    expect(session.status, ExternalEditStatus.synced);
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=8081\n');
    expect(files.data.keys, ['/etc/app.conf']);
  });

  test('远端文件被删除时拒绝上传，强制上传也不重新创建', () async {
    final session = await edits.openRemote(files, remote);
    files.data.remove('/etc/app.conf');
    await session.local.writeAsString('port=8080\n');
    await settle(session);
    expect(session.status, ExternalEditStatus.conflict);
    await session.upload(overwrite: true);
    expect(session.status, ExternalEditStatus.conflict);
    expect(files.data, isEmpty);
  });

  test('上传失败保留远端原件，可重试', () async {
    final session = await edits.openRemote(files, remote);
    files.failPublish = true;
    await session.local.writeAsString('port=8080\n');
    await settle(session);
    expect(session.status, ExternalEditStatus.failed);
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=80\n');
    expect(files.data.keys, ['/etc/app.conf']);

    files.failPublish = false;
    await session.upload();
    expect(session.status, ExternalEditStatus.synced);
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=8080\n');
  });

  test('停止同步删除本机副本，之后的保存不再上传', () async {
    final session = await edits.openRemote(files, remote);
    final copy = session.local;
    await edits.stop(session);
    expect(edits.sessions, isEmpty);
    expect(await copy.exists(), isFalse);
    await session.check();
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=80\n');
  });

  test('只读模式只交出副本，不回传', () async {
    final readOnly = ExternalEdits(
      launch: (path) async => launched.add(path),
      temporaryDirectory: () async => temp,
      pollInterval: const Duration(hours: 1),
      syncBack: false,
    );
    addTearDown(readOnly.dispose);
    final session = await readOnly.openRemote(files, remote);
    expect(session.status, ExternalEditStatus.readOnly);
    await session.local.writeAsString('port=8080\n');
    await settle(session);
    await session.upload();
    expect(utf8.decode(files.data['/etc/app.conf']!), 'port=80\n');
  });

  test('远端文件名含 Windows 不允许的字符时本机副本仍可创建', () async {
    files.data['/etc/a:b?.conf'] = _bytes('x');
    final session = await edits.openRemote(
      files,
      const RemoteFile(name: 'a:b?.conf', path: '/etc/a:b?.conf'),
    );
    expect(session.status, ExternalEditStatus.synced);
    expect(session.local.path.split(Platform.pathSeparator).last, 'a_b_.conf');
  });

  test('读取失败时显示失败，再次打开会重新复制', () async {
    final session = await edits.openRemote(
      files,
      const RemoteFile(name: 'missing.conf', path: '/etc/missing.conf'),
    );
    expect(session.status, ExternalEditStatus.failed);
    expect(launched, isEmpty);
    files.data['/etc/missing.conf'] = _bytes('ok');
    final retried = await edits.openRemote(
      files,
      const RemoteFile(name: 'missing.conf', path: '/etc/missing.conf'),
    );
    expect(identical(retried, session), isFalse);
    expect(retried.status, ExternalEditStatus.synced);
    expect(edits.sessions, [retried]);
  });
}
