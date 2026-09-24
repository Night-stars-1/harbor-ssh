import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/local_transfer.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/remote_file.dart';
import 'package:harbor_ssh/ui/file_browser.dart';
import 'package:harbor_ssh/ui/remote_file_tile.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('文件列表浏览、筛选、上传下载适配 $width', (tester) async {
      tester.view.physicalSize = Size(width, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FileTestSession();
      final local = FakeLocalTransfer();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: FileBrowser(session: session, local: local),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('report.txt'), findsOneWidget);
      expect(find.text('.config'), findsNothing);
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();
      expect(find.text('.config'), findsOneWidget);
      await tester.tap(find.text('documents'));
      await tester.pumpAndSettle();
      expect(find.text('此目录没有可显示的文件'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '筛选文件'), 'nothing');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的文件'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '筛选文件'), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('report.txt'));
      await tester.pumpAndSettle();
      expect(local.target.bytes, [1, 2, 3]);
      expect(local.target.finished, isTrue);
      expect(find.text('已下载 report.txt'), findsOneWidget);
      await tester.tap(find.text('上传'));
      await tester.pumpAndSettle();
      expect(session.fake.uploads, {
        '/home/tester/new.txt': [4, 5, 6],
      });
      expect(find.text('已上传 1 个文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('下载取消清理目标，失败与断线不会报成功', (tester) async {
    final session = FileTestSession();
    final local = FakeLocalTransfer();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: FileBrowser(session: session, local: local),
      ),
    );
    await tester.pumpAndSettle();
    session.fake.gate = Completer<void>();
    await tester.tap(find.text('report.txt'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close_rounded));
    session.fake.gate!.complete();
    await tester.pumpAndSettle();
    expect(local.target.aborted, isTrue);
    expect(local.target.finished, isFalse);
    expect(find.text('传输已取消'), findsOneWidget);
    session.fake.gate = null;
    session.fake.failDownload = true;
    await tester.tap(find.text('report.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('模拟读取失败'), findsOneWidget);
    expect(local.target.finished, isFalse);
    session.close();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '上传'))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('SSH 已断开'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同名上传不覆盖；目录错误可重试', (tester) async {
    final session = FileTestSession();
    final local = FakeLocalTransfer()..name = 'report.txt';
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: FileBrowser(session: session, local: local),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(session.fake.uploads, isEmpty);
    expect(find.textContaining('已存在'), findsOneWidget);
    session.fake.failBrowse = true;
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    session.fake.failBrowse = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteFileTile), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('文件入口返回后保留终端和选择状态', (tester) async {
    final session = FileTestSession();
    addTearDown(session.dispose);
    session.terminal.write('retained terminal');
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(session: session, onReconnect: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final terminal = tester.state(find.byType(TerminalView));
    await tester.tap(find.byKey(const ValueKey('open-sftp')));
    await tester.pumpAndSettle();
    expect(find.byType(FileBrowser), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(TerminalView)), same(terminal));
    expect(session.terminal.buffer.getText(), contains('retained terminal'));
    expect(session.status, ConnectionStatus.connected);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class FileTestSession extends SshConnection {
  FileTestSession() : super(id: 'files', host: testHost) {
    status = ConnectionStatus.connected;
  }
  final fake = FakeRemoteFiles();
  @override
  RemoteFileSystem get files => fake;
}

class FakeRemoteFiles implements RemoteFileSystem {
  @override
  String childPath(String directory, String name) =>
      remoteChild(directory, name);
  @override
  Future<void> deleteFile(String path) async => throw UnimplementedError();
  @override
  Future<void> createDirectory(String path) async => throw UnimplementedError();
  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) async =>
      throw UnimplementedError();
  @override
  Future<void> renameExclusive(String oldPath, String newPath) async =>
      throw UnimplementedError();
  final uploads = <String, List<int>>{};
  Completer<void>? gate;
  bool failDownload = false, failBrowse = false;
  @override
  Future<RemoteDirectory> browse(String path) async {
    if (failBrowse) throw StateError('模拟目录读取失败');
    if (path == '~') path = '/home/tester';
    return RemoteDirectory(
      path,
      path.endsWith('/documents')
          ? []
          : const [
              RemoteFile(
                name: 'documents',
                path: '/home/tester/documents',
                isDirectory: true,
              ),
              RemoteFile(
                name: 'report.txt',
                path: '/home/tester/report.txt',
                size: 3,
              ),
              RemoteFile(
                name: '.config',
                path: '/home/tester/.config',
                size: 0,
              ),
            ],
    );
  }

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    await write(Uint8List.fromList([1, 2, 3]));
    onProgress(3);
    if (gate != null) await gate!.future;
    cancellation.check();
    if (failDownload) throw StateError('模拟读取失败');
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      cancellation.check();
      bytes.addAll(chunk);
      onProgress(bytes.length);
    }
    uploads[path] = bytes;
  }
}

class FakeLocalTransfer implements LocalTransfer {
  final target = FakeDownload();
  String name = 'new.txt';
  @override
  Future<List<UploadFile>> pickUploads() async => [
    UploadFile(name, 3, () => Stream.value(Uint8List.fromList([4, 5, 6]))),
  ];
  @override
  Future<DownloadTarget?> pickDownload(String name) async => target;
}

class FakeDownload implements DownloadTarget {
  final bytes = <int>[];
  bool finished = false, aborted = false;
  @override
  Future<void> write(Uint8List chunk) async {
    bytes.addAll(chunk);
  }

  @override
  Future<void> finish() async {
    finished = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}
