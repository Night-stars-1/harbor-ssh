import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/file_copy.dart';
import 'package:harbor_ssh/data/local_files.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/remote_file.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/file_workspace.dart';
import 'package:harbor_ssh/ui/file_workspace_model.dart';
import 'package:harbor_ssh/ui/localization.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/transfer_speed.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import 'file_browser_test.dart' show FileTestSession;
import 'support.dart';

void main() {
  for (final width in [320.0, 1100.0]) {
    testWidgets('底部信息栏固定尺寸，传输进度和结果原位更新 $width', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var elapsed = Duration.zero;
      final model = FileWorkspaceModel(
        transferSpeed: TransferSpeed(elapsed: () => elapsed),
      );
      addTearDown(model.dispose);
      final source = MemoryFiles()..data['/large.bin'] = Uint8List(131072);
      final target = MemoryFiles()
        ..writeGate = Completer<void>()
        ..writeGateAfterBytes = 65536;
      final a = model.add(0, name: 'source', files: source);
      final b = model.add(1, name: 'target', files: target);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: FileWorkspace(
              model: model,
              hosts: const [],
              sessions: const [],
              onConnect: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = find.byKey(const ValueKey('file-status-bar'));
      expect(bar, findsNothing);
      final data = model.dragData(a, a.entries.single);
      final operation = model.drop(data, b);
      await tester.pump();
      expect(model.transferred, 65536);
      final initial = tester.getRect(bar);
      expect(initial.height, 64);
      expect(initial.width, width);
      expect(find.text('64 KB / 128 KB · 50%'), findsOneWidget);
      final speed = find.byKey(const ValueKey('file-transfer-speed'));
      expect(tester.widget<Text>(speed).data, '0 B/s');
      elapsed = const Duration(seconds: 1);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<Text>(speed).data, '64 KB/s');
      expect(tester.getRect(bar).contains(tester.getCenter(speed)), isTrue);
      elapsed = const Duration(seconds: 3);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<Text>(speed).data, '0 B/s');
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      target.writeGate!.complete();
      await operation;
      await tester.pumpAndSettle();
      expect(tester.getRect(bar), initial);
      expect(find.text('已传输 1 个项目'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(speed, findsNothing);
      await model.drop(data, b);
      await tester.pumpAndSettle();
      expect(model.failed, isTrue);
      expect(tester.getRect(bar), initial);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dismiss-file-result')));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(
        await model.drop(data, b, overwriteConflicts: model.conflicts(data, b)),
        isTrue,
      );
      expect(model.failed, isFalse);
      expect(model.message, '已传输 1 个项目');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('真实本地传输经界面暂停、继续、覆盖与放弃，窄屏显示断点进度', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('harbor-resume-ui-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    final payload = Uint8List.fromList(
      List.generate(2 * 1024 * 1024 + 7, (i) => i % 251),
    );
    await tester.runAsync(() async {
      await Directory('${directory!.path}/source').create();
      await Directory('${directory.path}/target').create();
      await File('${directory.path}/source/data.bin').writeAsBytes(payload);
    });
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final a = model.add(
      0,
      name: 'Source',
      files: LocalFiles('${directory!.path}/source'),
      isLocal: true,
      initialPath: '${directory.path}/source',
    );
    final b = model.add(
      1,
      name: 'Target',
      files: LocalFiles('${directory.path}/target'),
      isLocal: true,
      initialPath: '${directory.path}/target',
    );
    await tester.runAsync(() async {
      await a.browse();
      await b.browse();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final data = FileDragData(a, [a.entries.single]);
    var paused = false;
    void interrupt() {
      if (!paused && model.transfer != null && model.transferred > 0) {
        paused = true;
        model.cancel();
      }
    }

    model.addListener(interrupt);
    await tester.runAsync(() async {
      expect(await model.drop(data, b), isFalse);
    });
    model.removeListener(interrupt);
    await tester.pumpAndSettle();
    expect(model.canResume, isTrue);
    expect(model.canClose(a), isFalse);
    expect(find.byKey(const ValueKey('resume-file-transfer')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final resume =
        tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('resume-file-transfer')),
                )
                .onPressed
            as Future<void> Function();
    // Run the real disk action outside Flutter's fake async clock.
    await tester.runAsync(resume);
    await tester.pumpAndSettle();
    expect(model.canResume, isFalse, reason: model.message);
    expect(
      await tester.runAsync(
        () => File('${directory.path}/target/data.bin').readAsBytes(),
      ),
      payload,
    );
    expect(model.message, '已传输 1 个项目');

    // A paused overwrite leaves the original target visible until resumed.
    final replacement = Uint8List.fromList(
      List.generate(payload.length, (i) => (i * 7) % 251),
    );
    await tester.runAsync(
      () => File('${directory.path}/source/data.bin').writeAsBytes(replacement),
    );
    await tester.runAsync(() => a.browse());
    final overwrite = FileDragData(a, [a.entries.single]);
    paused = false;
    model.addListener(interrupt);
    await tester.runAsync(() async {
      expect(
        await model.drop(
          overwrite,
          b,
          overwriteConflicts: model.conflicts(overwrite, b),
        ),
        isFalse,
      );
    });
    model.removeListener(interrupt);
    expect(
      await tester.runAsync(
        () => File('${directory.path}/target/data.bin').readAsBytes(),
      ),
      payload,
    );
    await tester.runAsync(model.resume);
    expect(
      await tester.runAsync(
        () => File('${directory.path}/target/data.bin').readAsBytes(),
      ),
      replacement,
    );

    paused = false;
    model.addListener(interrupt);
    await tester.runAsync(() async {
      expect(
        await model.drop(
          overwrite,
          b,
          overwriteConflicts: model.conflicts(overwrite, b),
        ),
        isFalse,
      );
    });
    model.removeListener(interrupt);
    await tester.pumpAndSettle();
    final discard =
        tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('discard-file-transfer')),
                )
                .onPressed
            as Future<void> Function();
    await tester.runAsync(discard);
    await tester.pumpAndSettle();
    final entries = await tester.runAsync(() => b.files.browse(b.path));
    expect(entries!.entries.map((entry) => entry.name), ['data.bin']);
    expect(
      await tester.runAsync(
        () => File('${directory.path}/target/data.bin').readAsBytes(),
      ),
      replacement,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('手机轻扫多选后长按打开批量菜单，长按未选文件只操作该文件', (tester) async {
    tester.view.physicalSize = const Size(390, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = MemoryFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..data['/b.txt'] = Uint8List(1)
      ..data['/c.txt'] = Uint8List(1);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme().copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Finder row(String name) => find.byKey(ValueKey('entry-${tab.id}-/$name'));
    await tester.drag(row('a.txt'), const Offset(60, 0));
    await tester.pumpAndSettle();
    await tester.drag(row('b.txt'), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-selected-files')), findsNothing);
    await tester.longPress(row('a.txt'));
    await tester.pumpAndSettle();
    expect(tab.selected, {'/a.txt', '/b.txt'});
    expect(find.text('删除 2 个文件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-selected-files')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(files.data, hasLength(3));
    await tester.longPress(row('c.txt'));
    await tester.pumpAndSettle();
    expect(tab.selected, {'/c.txt'});
    expect(find.text('删除 1 个文件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-selected-files')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-files')));
    await tester.pumpAndSettle();
    expect(files.data.keys, ['/a.txt', '/b.txt']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('SFTP 编辑用代码编辑器保存内容，未保存离开不覆盖远端', (tester) async {
    tester.view.physicalSize = const Size(320, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = MemoryFiles()
      ..data['/note.json'] = Uint8List.fromList(utf8.encode('旧内容\n第二行'));
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await tester.pumpWidget(
      MaterialApp(
        locale: harborLocale,
        supportedLocales: harborSupportedLocales,
        localizationsDelegates: harborLocalizationDelegates,
        theme: harborTheme().copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('entry-${tab.id}-/note.json'));
    final content = find.byKey(const ValueKey('remote-text-content'));

    await openRemoteEditor(tester, row);
    final dialog = tester.getRect(
      find.byKey(const ValueKey('remote-text-dialog')),
    );
    expect(dialog.left, greaterThanOrEqualTo(0));
    expect(dialog.right, lessThanOrEqualTo(320));
    expect(dialog.bottom, lessThanOrEqualTo(500));
    expect(
      tester.getBottomRight(find.byKey(const ValueKey('save-remote-text'))).dy,
      lessThanOrEqualTo(500),
    );
    // 代码编辑器接管内容：语言标签按文件路径推断，行号来自内容行数。
    expect(remoteEditorController(tester).text, '旧内容\n第二行');
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(remoteLanguageLabel(tester).toLowerCase(), contains('json'));
    expect(remoteLineNumberCount(tester), 2);

    // 内容未修改时保存只关闭对话框，不写回远端。
    await tester.tap(find.byKey(const ValueKey('save-remote-text')));
    await tester.pumpAndSettle();
    expect(content, findsNothing);
    expect(utf8.decode(files.data['/note.json']!), '旧内容\n第二行');

    // Esc 走对话框原有的放弃确认：继续编辑时草稿与远端都不变。
    await openRemoteEditor(tester, row);
    await tester.tap(content);
    await tester.pump();
    expect(tester.widget<CodeEditor>(content).focusNode!.hasFocus, isTrue);
    await tester.longPressAt(tester.getTopLeft(content) + const Offset(70, 24));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pump();
    replaceRemoteText(tester, '暂存内容');
    await tester.pump();
    expect(find.text('未保存的修改'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keep-editing-remote-text')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(remoteEditorController(tester).text, '暂存内容');
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('discard-remote-text')));
    await tester.pumpAndSettle();
    expect(utf8.decode(files.data['/note.json']!), '旧内容\n第二行');

    // Ctrl+S 与保存按钮走同一条路径，键盘保存同样写回远端。
    await openRemoteEditor(tester, row);
    await tester.tap(content);
    await tester.pump();
    replaceRemoteText(tester, '已保存的内容\n第二行');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(content, findsNothing);
    expect(utf8.decode(files.data['/note.json']!), '已保存的内容\n第二行');
    expect(files.data.keys, ['/note.json']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('远程代码编辑器保持 CRLF，未改动的混合换行不被覆盖', (tester) async {
    tester.view.physicalSize = const Size(390, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = MemoryFiles()
      ..data['/settings.json'] = Uint8List.fromList(
        utf8.encode('{\r\n  "name": "harbor"\r\n}\r\n'),
      );
    files.data['/mixed.json'] = Uint8List.fromList(
      utf8.encode('{\r\n  "name": "harbor"\n}\r\n'),
    );
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme().copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('entry-${tab.id}-/settings.json'));

    await openRemoteEditor(tester, row);
    // 载入不把 CRLF 改写成 LF，编辑区按 CRLF 拼接新行。
    expect(
      remoteEditorController(tester).text,
      '{\r\n  "name": "harbor"\r\n}\r\n',
    );
    expect(
      remoteEditorController(tester).options.lineBreak,
      TextLineBreak.crlf,
    );
    expect(remoteLineNumberCount(tester), 4);
    expect(remoteLanguageLabel(tester).toLowerCase(), contains('json'));

    replaceRemoteText(tester, '{\n  "name": "harbor"\n}');
    await tester.pump();
    expect(remoteEditorController(tester).text, '{\r\n  "name": "harbor"\r\n}');
    await tester.tap(find.byKey(const ValueKey('save-remote-text')));
    await tester.pumpAndSettle();
    expect(
      utf8.decode(files.data['/settings.json']!),
      '{\r\n  "name": "harbor"\r\n}',
    );
    final mixedRow = find.byKey(ValueKey('entry-${tab.id}-/mixed.json'));
    await openRemoteEditor(tester, mixedRow);
    await tester.tap(find.byKey(const ValueKey('save-remote-text')));
    await tester.pumpAndSettle();
    expect(
      utf8.decode(files.data['/mixed.json']!),
      '{\r\n  "name": "harbor"\n}\r\n',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('本地删除只移除指定文件并拒绝递归删除目录', () async {
    final root = await Directory.systemTemp.createTemp('harbor-delete-test-');
    addTearDown(() => root.delete(recursive: true));
    final file = await File('${root.path}/delete.txt').writeAsString('delete');
    final folder = await Directory('${root.path}/keep').create();
    final keep = await File('${folder.path}/keep.txt').writeAsString('keep');
    final files = LocalFiles(root.path);
    await files.deleteFile(file.path);
    expect(await file.exists(), isFalse);
    await expectLater(
      files.deleteFile(folder.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await keep.readAsString(), 'keep');
    await expectLater(
      files.deleteFile(file.path),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('批量删除锁定标签，失败保留剩余文件并清除失效复制缓存', () async {
    final files = MemoryFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..data['/b.txt'] = Uint8List(1)
      ..data['/c.txt'] = Uint8List(1)
      ..failDeletePath = '/b.txt'
      ..deleteGate = Completer<void>();
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    await tab.browse();
    for (final entry in tab.entries.take(2)) {
      tab.toggle(entry);
    }
    model.copySelection(tab);
    final data = model.clipboard!;
    for (final entry in data.files) {
      tab.toggle(entry);
    }
    final deleting = model.deleteFiles(data);
    expect(model.busy, isTrue);
    expect(model.locked(tab), isTrue);
    expect(model.canDelete(data), isFalse);
    model.close(0, tab);
    expect(model.tabs, contains(tab));
    files.deleteGate!.complete();
    await deleting;
    expect(files.data.keys, ['/b.txt', '/c.txt']);
    expect(tab.selected, {'/b.txt'});
    expect(model.failed, isTrue);
    expect(model.message, contains('1/2'));
    expect(model.clipboard, isNull);
    expect(model.busy, isFalse);
    final directory = FileDragData(tab, [
      const RemoteFile(name: 'folder', path: '/folder', isDirectory: true),
    ]);
    expect(model.canDelete(directory), isFalse);
    model.close(0, tab);
    expect(model.canDelete(data), isFalse);
  });

  testWidgets('右键批量删除需确认，取消不删除，右键未选文件仅选中该文件', (tester) async {
    tester.view.physicalSize = const Size(1100, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = MemoryFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..data['/b.txt'] = Uint8List(1)
      ..data['/c.txt'] = Uint8List(1);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    final other = model.add(
      1,
      name: 'right',
      files: MemoryFiles()..data['/right.txt'] = Uint8List(1),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rightRow = find.byKey(ValueKey('entry-${other.id}-/right.txt'));
    final click = tester.getTopLeft(rightRow) + const Offset(32, 24);
    await tester.tapAt(click, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('delete-selected-files'))).width,
      lessThan(240),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('delete-selected-files'))).dx,
      greaterThanOrEqualTo(click.dx),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final edgeClick = tester.getTopRight(rightRow) + const Offset(-4, 24);
    await tester.tapAt(edgeClick, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(
      tester
          .getTopRight(find.byKey(const ValueKey('delete-selected-files')))
          .dx,
      lessThanOrEqualTo(1092),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    tab.select(tab.entries[0]);
    tab.select(tab.entries[1], toggleSelection: true);
    await tester.pumpAndSettle();
    Future<void> openDelete(String name) async {
      await tester.tap(
        find.byKey(ValueKey('entry-${tab.id}-/$name')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-selected-files')));
      await tester.pumpAndSettle();
    }

    await openDelete('b.txt');
    expect(tab.selected, {'/a.txt', '/b.txt'});
    expect(find.text('删除 2 个文件？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(files.data, hasLength(3));
    await openDelete('c.txt');
    expect(tab.selected, {'/c.txt'});
    expect(find.text('删除 1 个文件？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    tab.select(tab.entries[0]);
    tab.select(tab.entries[1], toggleSelection: true);
    await tester.pumpAndSettle();
    await openDelete('a.txt');
    await tester.tap(find.byKey(const ValueKey('confirm-delete-files')));
    await tester.pumpAndSettle();
    expect(files.data.keys, ['/c.txt']);
    expect(tab.entries.single.name, 'c.txt');
    expect(tab.selected, isEmpty);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('file-status-bar'))).width,
      1100,
    );
    await tester.tap(find.byKey(const ValueKey('dismiss-file-result')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-status-bar')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 1100.0]) {
    testWidgets('加号统一显示本地和 SSH，复用会话且无二级弹窗 $width', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FileTestSession();
      addTearDown(session.dispose);
      final home = MemoryFiles()..data['/home-file.txt'] = Uint8List(1);
      final model = FileWorkspaceModel(localHome: () => home);
      addTearDown(model.dispose);
      final saved = Host.fromJson({
        ...session.host.toJson(),
        'id': 'saved',
        'name': 'Saved SSH',
      });
      Host? requested;
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: FileWorkspace(
              model: model,
              initializeLocal: false,
              hosts: [session.host, saved],
              sessions: [session],
              onConnect: (host) async {
                requested = host;
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-file-tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('本地文件'), findsOneWidget);
      expect(find.text(session.host.name), findsOneWidget);
      expect(find.text(saved.name), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(ValueKey('add-file-host-0-${session.host.id}')),
          matching: find.byType(HostOnlineDot),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('add-file-host-0-${saved.id}')),
          matching: find.byType(HostOnlineDot),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(ValueKey('add-file-host-0-${session.host.id}')),
      );
      await tester.pumpAndSettle();
      expect(requested, isNull);
      expect(model.panes[0].active!.session, same(session));
      expect(model.panes[0].active!.ownsSession, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const ValueKey('add-file-tab-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('add-file-host-0-${saved.id}')));
      await tester.pumpAndSettle();
      expect(requested, same(saved));
      await tester.tap(find.byKey(const ValueKey('add-file-tab-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地文件'));
      await tester.pumpAndSettle();
      expect(model.panes[0].active!.isLocal, isTrue);
      expect(model.panes[0].active!.files, same(home));
      expect(model.panes[0].active!.entries.single.name, 'home-file.txt');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('SFTP 目录书签：收藏当前目录、从列表跳回、移除，并按主机保存', (tester) async {
    tester.view.physicalSize = const Size(1100, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = FileTestSession();
    addTearDown(session.dispose);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final workspace = WorkspaceModel(memoryRepository());
    addTearDown(workspace.dispose);
    await workspace.repository.saveHosts([session.host]);
    await workspace.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: workspace,
            builder: (context, _) {
              return FileWorkspace(
                model: model,
                initializeLocal: false,
                hosts: workspace.hosts,
                sessions: [session],
                onConnect: (_) async => null,
                onSetBookmark: workspace.setSftpBookmark,
              );
            },
          ),
        ),
      ),
    );
    final tab = model.add(
      0,
      name: session.host.name,
      files: session.files,
      session: session,
    );
    await tester.pumpAndSettle();
    expect(tab.path, '/home/tester');
    final menu = find.byKey(ValueKey('file-bookmarks-${tab.id}'));
    final toggle = find.byKey(ValueKey('file-bookmark-toggle-${tab.id}'));

    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('收藏当前目录'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await workspace.repository.loadHosts()).single.sftpBookmarks, [
      '/home/tester',
    ]);

    await tab.browse('/home/tester/documents');
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await workspace.repository.loadHosts()).single.sftpBookmarks, [
      '/home/tester',
      '/home/tester/documents',
    ]);

    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('移除当前目录书签'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-bookmark-/home/tester')));
    await tester.pumpAndSettle();
    expect(tab.path, '/home/tester');

    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('file-bookmark-remove-/home/tester/documents')),
    );
    await tester.pumpAndSettle();
    expect((await workspace.repository.loadHosts()).single.sftpBookmarks, [
      '/home/tester',
    ]);
    expect(tab.path, '/home/tester');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('书签随主机 JSON 往返，编辑主机其他字段不丢失书签', () {
    final host = Host.fromJson({
      ...testHost.toJson(),
      'sftpBookmarks': ['/srv', '', 3, '/var/log'],
    });
    expect(host.sftpBookmarks, ['/srv', '/var/log']);
    expect(Host.fromJson(host.toJson()).sftpBookmarks, ['/srv', '/var/log']);
    expect(host.withFavorite(true).sftpBookmarks, ['/srv', '/var/log']);
    expect(testHost.toJson().containsKey('sftpBookmarks'), isFalse);
  });

  test('默认本地标签使用平台安全目录，仅初始化一次且保留已有标签', () async {
    Directory? macDocuments;
    if (Platform.isMacOS) {
      macDocuments = await Directory.systemTemp.createTemp(
        'harbor-macos-documents-',
      );
      addTearDown(() => macDocuments!.delete(recursive: true));
      await LocalFiles.prepareDefaultHome(
        directoryProvider: () async => macDocuments!,
      );
    } else {
      await LocalFiles.prepareDefaultHome();
    }
    final local = LocalFiles.userHome();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final expected = Platform.isMacOS
          ? macDocuments!.path
          : Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      expect(
        local!.root,
        Directory(expected!).absolute.path.replaceAll('\\', '/'),
      );
    }
    final files = MemoryFiles()..data['/document.txt'] = Uint8List(1);
    final model = FileWorkspaceModel(localHome: () => files);
    addTearDown(model.dispose);
    model.initializeDefaultLocal();
    final tab = model.panes[0].active!;
    await tab.browse();
    expect(tab.isLocal, isTrue);
    expect(tab.files, same(files));
    expect(tab.entries.single.name, 'document.txt');
    model.initializeDefaultLocal();
    expect(model.panes[0].tabs, hasLength(1));
    model.close(0, tab);
    model.initializeDefaultLocal();
    expect(model.panes[0].tabs, isEmpty);
    final existing = FileWorkspaceModel(localHome: () => files);
    addTearDown(existing.dispose);
    final remote = existing.add(0, name: 'server', files: MemoryFiles());
    existing.initializeDefaultLocal();
    expect(existing.panes[0].tabs, [remote]);
  });

  test('主机 SFTP 起始目录：打开即进入，目录失效退回主目录，手动路径照常报错', () async {
    final files = _MissingAwareFiles()
      ..directories.add('/var/www')
      ..data['/var/www/index.html'] = Uint8List(1);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(
      0,
      name: 'server',
      files: files,
      initialPath: const Host(
        id: 'h',
        name: 'server',
        address: 'a',
        username: 'u',
        sftpPath: '/var/www',
      ).sftpStartPath,
    );
    await tab.browse();
    expect(tab.path, '/var/www');
    expect(tab.error, isNull);

    final stale = model.add(
      0,
      name: 'stale',
      files: files,
      initialPath: '/removed',
    );
    await stale.browse();
    expect(stale.path, '/');
    expect(stale.error, isNull);

    await stale.browse('/also-missing');
    expect(stale.path, '/');
    expect(stale.error, isNotNull);
  });

  test('范围选择遵循可见顺序，跳过目录并在切换筛选后重置锚点', () async {
    final tab = FileLocationTab(
      id: 'selection',
      name: 'files',
      files: MemoryFiles(),
    );
    addTearDown(tab.dispose);
    const a = RemoteFile(name: 'a.txt', path: '/a.txt');
    const b = RemoteFile(name: 'b.log', path: '/b.log');
    const c = RemoteFile(name: 'c.txt', path: '/c.txt');
    const d = RemoteFile(name: 'd.txt', path: '/d.txt');
    tab.entries = [
      a,
      const RemoteFile(name: 'folder', path: '/folder', isDirectory: true),
      b,
      c,
      d,
    ];
    tab.select(c);
    tab.select(a, range: true);
    expect(tab.selected, {'/a.txt', '/b.log', '/c.txt'});
    tab.select(d, range: true);
    expect(tab.selected, {'/c.txt', '/d.txt'});
    tab.select(a, toggleSelection: true);
    tab.select(b, range: true, toggleSelection: true);
    expect(tab.selected, {'/a.txt', '/b.log', '/c.txt', '/d.txt'});
    tab.filter('.txt');
    tab.select(d, range: true);
    expect(tab.selected, {'/d.txt'});
    tab.select(a, range: true);
    expect(tab.selected, {'/a.txt', '/c.txt', '/d.txt'});
    tab.clearSelection();
    tab.selectOnMobile(d);
    tab.selectOnMobile(a);
    tab.selectOnMobile(d);
    expect(tab.selected, {'/a.txt', '/c.txt', '/d.txt'});
    tab.toggleHidden();
    tab.select(c, range: true);
    expect(tab.selected, {'/c.txt'});
    await tab.browse('/another');
    tab.entries = [a, b, c];
    tab.select(a, range: true);
    expect(tab.selected, {'/a.txt'});
  });

  for (final mobile in [false, true]) {
    testWidgets(mobile ? '手机轻扫选择和端点补选不干扰纵向滚动' : 'PC 普通点击、Ctrl 多选和 Shift 范围选择', (
      tester,
    ) async {
      tester.view.physicalSize = Size(mobile ? 390 : 1100, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = FileWorkspaceModel();
      addTearDown(model.dispose);
      final files = MemoryFiles();
      for (var i = 0; i < 30; i++) {
        files.data['/file$i.txt'] = Uint8List(1);
      }
      final tab = model.add(0, name: 'files', files: files);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme().copyWith(
            platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
          ),
          home: Scaffold(
            body: FileWorkspace(
              model: model,
              hosts: const [],
              sessions: const [],
              onConnect: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder row(int i) => find.byKey(ValueKey('entry-${tab.id}-/file$i.txt'));
      expect(find.byType(Checkbox), findsNothing);
      if (mobile) {
        final originalX = tester.getTopLeft(row(0)).dx;
        final swipe = await tester.startGesture(tester.getCenter(row(0)));
        await swipe.moveBy(const Offset(40, 0));
        await tester.pump();
        expect(tester.getTopLeft(row(0)).dx, greaterThan(originalX + 20));
        expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
        expect(tab.selected, isEmpty);
        await swipe.moveBy(const Offset(20, 0));
        await tester.pump();
        expect(tester.getTopLeft(row(0)).dx, closeTo(originalX + 60, 1));
        await swipe.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final returningX = tester.getTopLeft(row(0)).dx;
        expect(returningX, greaterThan(originalX));
        expect(returningX, lessThan(originalX + 60));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(row(0)).dx, closeTo(originalX, .1));
        expect(tab.selected, {'/file0.txt'});
        final deselect = await tester.startGesture(tester.getCenter(row(0)));
        await deselect.moveBy(const Offset(-60, 0));
        await tester.pump();
        expect(find.byIcon(Icons.remove_circle_rounded), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
        await deselect.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        expect(tab.selected, isEmpty);
        expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
        await tester.pumpAndSettle();
        await tester.drag(row(0), const Offset(70, 0));
        await tester.pumpAndSettle();
        await tester.drag(row(3), const Offset(-70, 0));
        await tester.pumpAndSettle();
        expect(tab.selected, {'/file0.txt', '/file3.txt'});
        final range = await tester.startGesture(tester.getCenter(row(0)));
        await range.moveBy(const Offset(60, 0));
        await tester.pump();
        expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
        expect(find.byIcon(Icons.remove_circle_rounded), findsNothing);
        await range.up();
        await tester.pumpAndSettle();
        expect(tab.selected, {for (var i = 0; i <= 3; i++) '/file$i.txt'});
        await tester.tap(row(1));
        await tester.pumpAndSettle();
        expect(tab.selected.contains('/file1.txt'), isFalse);
        tab.clearSelection();
        await tester.pumpAndSettle();
        // Movement above touch slop but below the selection threshold is ignored.
        await tester.drag(row(2), const Offset(25, 0));
        await tester.pumpAndSettle();
        expect(tab.selected, isEmpty);
        final before = tester.getTopLeft(row(3)).dy;
        await tester.drag(row(4), const Offset(0, -90));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(row(3)).dy, lessThan(before));
        expect(tab.selected, isEmpty);
      } else {
        await tester.tap(row(0));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(row(3));
        await tester.pumpAndSettle();
        expect(tab.selected, {'/file0.txt', '/file3.txt'});
        await tester.tap(row(0));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(tab.selected, {'/file3.txt'});
        await tester.tap(row(0));
        await tester.pumpAndSettle();
        expect(tab.selected, {'/file0.txt'});
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.tap(row(3));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(tab.selected, {for (var i = 0; i <= 3; i++) '/file$i.txt'});
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('流式转发限制读入量，目标失败/源失败/取消均退出并清理', () async {
    final source = MemoryFiles()..data['/large.bin'] = Uint8List(512 * 1024);
    final target = MemoryFiles();
    await copyFileBetween(
      source: source,
      destination: target,
      sourcePath: '/large.bin',
      destinationPath: '/copy.bin',
      cancellation: TransferCancellation(),
      onProgress: (count) {
        expect(source.readBytes - count, lessThanOrEqualTo(65536));
      },
    ).timeout(const Duration(seconds: 3));
    expect(target.data['/copy.bin'], source.data['/large.bin']);
    target.failWrite = true;
    await expectLater(
      copyFileBetween(
        source: source,
        destination: target,
        sourcePath: '/large.bin',
        destinationPath: '/failed.bin',
        cancellation: TransferCancellation(),
        onProgress: (_) {},
      ).timeout(const Duration(seconds: 3)),
      throwsStateError,
    );
    expect(target.data.containsKey('/failed.bin'), isFalse);
    target.failWrite = false;
    source.failRead = true;
    await expectLater(
      copyFileBetween(
        source: source,
        destination: target,
        sourcePath: '/large.bin',
        destinationPath: '/read-failed.bin',
        cancellation: TransferCancellation(),
        onProgress: (_) {},
      ).timeout(const Duration(seconds: 3)),
      throwsStateError,
    );
    expect(target.data.containsKey('/read-failed.bin'), isFalse);
    source.failRead = false;
    final cancellation = TransferCancellation();
    await expectLater(
      copyFileBetween(
        source: source,
        destination: target,
        sourcePath: '/large.bin',
        destinationPath: '/cancelled.bin',
        cancellation: cancellation,
        onProgress: (_) => cancellation.cancel(),
      ).timeout(const Duration(seconds: 3)),
      throwsA(isA<TransferCancelled>()),
    );
    expect(target.data.containsKey('/cancelled.bin'), isFalse);
  });

  test('本地文件夹读取、两个本地面板复制及同名保护', () async {
    final root = await Directory.systemTemp.createTemp('harbor-pane-test-');
    addTearDown(() => root.delete(recursive: true));
    final left = await Directory('${root.path}/left').create();
    final right = await Directory('${root.path}/right').create();
    await File('${left.path}/文件.bin').writeAsBytes([1, 2, 3, 4]);
    final folder = await Directory('${left.path}/folder').create();
    final sub = await Directory('${folder.path}/sub').create();
    await Directory('${folder.path}/empty').create();
    await File('${sub.path}/nested.txt').writeAsBytes([5, 6]);
    final source = LocalFiles(left.path), target = LocalFiles(right.path);
    final listing = await source.browse('~');
    if (Platform.isWindows) {
      expect(
        () => target.childPath(target.root, r'..\outside'),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      listing.entries.map((entry) => entry.name),
      containsAll(['folder', '文件.bin']),
    );
    final file = listing.entries.singleWhere((entry) => entry.name == '文件.bin');
    final destination = '${target.root}/文件.bin';
    await copyFileBetween(
      source: source,
      destination: target,
      sourcePath: file.path,
      destinationPath: destination,
      cancellation: TransferCancellation(),
      onProgress: (_) {},
    );
    expect(await File(destination).readAsBytes(), [1, 2, 3, 4]);
    await expectLater(
      copyFileBetween(
        source: source,
        destination: target,
        sourcePath: file.path,
        destinationPath: destination,
        cancellation: TransferCancellation(),
        onProgress: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(destination).readAsBytes(), [1, 2, 3, 4]);
    final folderEntry = listing.entries.singleWhere(
      (entry) => entry.name == 'folder',
    );
    final folderDestination = '${target.root}/folder';
    await copyDirectoryBetween(
      source: source,
      destination: target,
      sourcePath: folderEntry.path,
      destinationPath: folderDestination,
      cancellation: TransferCancellation(),
      onPrepared: (result) {
        expect(result.files, 1);
        expect(result.directories, 3);
      },
      onProgress: (_) {},
    );
    expect(await Directory('$folderDestination/empty').exists(), isTrue);
    expect(await File('$folderDestination/sub/nested.txt').readAsBytes(), [
      5,
      6,
    ]);
    await expectLater(
      copyDirectoryBetween(
        source: source,
        destination: target,
        sourcePath: folderEntry.path,
        destinationPath: folderDestination,
        cancellation: TransferCancellation(),
        onPrepared: (_) {},
        onProgress: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('本地安全重命名不覆盖同时出现的目标', () async {
    final root = await Directory.systemTemp.createTemp('harbor-rename-');
    addTearDown(() => root.delete(recursive: true));
    final files = LocalFiles(root.path);
    final source = File('${root.path}/source.txt')..writeAsStringSync('new');
    final target = File('${root.path}/target.txt')..writeAsStringSync('old');

    await expectLater(
      files.renameExclusive(source.path, target.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsStringSync(), 'new');
    expect(target.readAsStringSync(), 'old');

    final published = '${root.path}/published.txt';
    await files.renameExclusive(source.path, published);
    expect(await File(published).readAsString(), 'new');
    expect(source.existsSync(), isFalse);
  });

  test('文件夹可在 SFTP 与本地间双向递归拖动，保留空目录并回滚失败目标', () async {
    final remote = MemoryFiles()
      ..directories.addAll({'/folder', '/folder/sub', '/folder/empty'})
      ..data['/folder/root.txt'] = Uint8List.fromList([1, 2])
      ..data['/folder/sub/nested.txt'] = Uint8List.fromList([3, 4, 5]);
    final local = MemoryFiles();
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final remoteSource = model.add(0, name: 'sftp', files: remote);
    final localTarget = model.add(
      1,
      name: 'local',
      files: local,
      isLocal: true,
    );
    await remoteSource.browse('/');
    await localTarget.browse('/');
    final folder = remoteSource.entries.singleWhere(
      (entry) => entry.name == 'folder',
    );
    final drag = model.dragData(remoteSource, folder);
    expect(drag.files.single.isDirectory, isTrue);
    expect(model.canDrop(drag, localTarget), isTrue);
    expect(await model.drop(drag, localTarget), isTrue);
    expect(
      local.directories,
      containsAll({'/folder', '/folder/sub', '/folder/empty'}),
    );
    expect(local.data['/folder/root.txt'], [1, 2]);
    expect(local.data['/folder/sub/nested.txt'], [3, 4, 5]);
    expect(model.message, '已传输 1 个项目');

    await localTarget.browse('/');
    final secondRemote = MemoryFiles();
    final remoteTarget = model.add(0, name: 'other-sftp', files: secondRemote);
    await remoteTarget.browse('/');
    final localFolder = localTarget.entries.singleWhere(
      (entry) => entry.name == 'folder',
    );
    expect(
      await model.drop(model.dragData(localTarget, localFolder), remoteTarget),
      isTrue,
    );
    expect(secondRemote.directories, contains('/folder/empty'));
    expect(secondRemote.data['/folder/sub/nested.txt'], [3, 4, 5]);

    final descendant = model.add(
      1,
      name: 'same-server-child',
      files: remote,
      initialPath: '/folder/sub',
    );
    await descendant.browse('/folder/sub');
    expect(model.canDrop(drag, descendant), isFalse);

    final failing = MemoryFiles()..failWrite = true;
    final failingTarget = model.add(1, name: 'failing', files: failing);
    await failingTarget.browse('/');
    expect(await model.drop(drag, failingTarget), isFalse);
    expect(failing.directories, {'/'});
    expect(failing.data, isEmpty);
    expect(model.failed, isTrue);

    final cancelTarget = MemoryFiles()
      ..writeGate = Completer<void>()
      ..writeGateAfterBytes = 0;
    final cancellingTab = model.add(1, name: 'cancel', files: cancelTarget);
    await cancellingTab.browse('/');
    final cancelling = model.drop(drag, cancellingTab);
    await Future<void>.delayed(Duration.zero);
    cancelTarget.data['/folder/external.txt'] = Uint8List.fromList([9]);
    model.cancel();
    cancelTarget.writeGate!.complete();
    expect(await cancelling, isFalse);
    expect(cancelTarget.directories, containsAll({'/', '/folder'}));
    expect(cancelTarget.data['/folder/external.txt'], [9]);
    const duplicateA = Host(
      id: 'duplicate-a',
      name: 'same server A',
      address: 'server.example.com',
      username: 'deploy',
    );
    const duplicateB = Host(
      id: 'duplicate-b',
      name: 'same server B',
      address: 'SERVER.EXAMPLE.COM',
      username: 'deploy',
    );
    final sessionA = SshConnection(id: 'duplicate-a', host: duplicateA)
      ..status = ConnectionStatus.connected;
    final sessionB = SshConnection(id: 'duplicate-b', host: duplicateB)
      ..status = ConnectionStatus.connected;
    addTearDown(sessionA.dispose);
    addTearDown(sessionB.dispose);
    final duplicateSourceFiles = MemoryFiles()
      ..directories.addAll({'/folder', '/folder/sub'});
    final duplicateTargetFiles = MemoryFiles()
      ..directories.addAll({'/folder', '/folder/sub'});
    final duplicateModel = FileWorkspaceModel();
    addTearDown(duplicateModel.dispose);
    final duplicateSource = duplicateModel.add(
      0,
      name: 'source',
      files: duplicateSourceFiles,
      session: sessionA,
    );
    final duplicateTarget = duplicateModel.add(
      1,
      name: 'target',
      files: duplicateTargetFiles,
      initialPath: '/folder/sub',
      session: sessionB,
    );
    await duplicateSource.browse('/');
    await duplicateTarget.browse('/folder/sub');
    final duplicateFolder = duplicateSource.entries.singleWhere(
      (entry) => entry.name == 'folder',
    );
    expect(
      duplicateModel.canDrop(
        duplicateModel.dragData(duplicateSource, duplicateFolder),
        duplicateTarget,
      ),
      isFalse,
    );

    final emptySource = MemoryFiles()..directories.add('/empty');
    final delayedTarget = MemoryFiles()
      ..createDirectoryGate = Completer<void>();
    final mkdirCancellation = TransferCancellation();
    final emptyCopy = copyDirectoryBetween(
      source: emptySource,
      destination: delayedTarget,
      sourcePath: '/empty',
      destinationPath: '/empty',
      cancellation: mkdirCancellation,
      onPrepared: (_) {},
      onProgress: (_) {},
    );
    final cancelledCopy = expectLater(
      emptyCopy,
      throwsA(isA<TransferCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    mkdirCancellation.cancel();
    delayedTarget.createDirectoryGate!.complete();
    await cancelledCopy;
    expect(delayedTarget.directories, {'/'});
  });

  test('覆盖传输失败或取消时保留原项目', () async {
    final source = MemoryFiles()
      ..data['/same.txt'] = Uint8List.fromList([2, 3])
      ..failRead = true;
    final target = MemoryFiles()..data['/same.txt'] = Uint8List.fromList([1]);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final sourceTab = model.add(0, name: 'source', files: source);
    final targetTab = model.add(1, name: 'target', files: target);
    await Future.wait([sourceTab.browse('/'), targetTab.browse('/')]);
    final drag = model.dragData(sourceTab, sourceTab.entries.single);

    expect(
      await model.drop(
        drag,
        targetTab,
        overwriteConflicts: model.conflicts(drag, targetTab),
      ),
      isFalse,
    );
    expect(target.data, {
      '/same.txt': [1],
    });
    expect(target.directories, {'/'});

    source.failRead = false;
    target.writeGate = Completer<void>();
    final cancelled = model.drop(
      drag,
      targetTab,
      overwriteConflicts: model.conflicts(drag, targetTab),
    );
    await Future<void>.delayed(Duration.zero);
    model.cancel();
    target.writeGate!.complete();
    expect(await cancelled, isFalse);
    expect(target.data, {
      '/same.txt': [1],
    });
    expect(target.directories, {'/'});

    target.writeGate = null;
    target.failPublish = true;
    expect(
      await model.drop(
        drag,
        targetTab,
        overwriteConflicts: model.conflicts(drag, targetTab),
      ),
      isFalse,
    );
    expect(target.data, {
      '/same.txt': [1],
    });
    expect(target.directories, {'/'});

    target.failPublish = false;
    target.failBackupAfterMove = true;
    expect(
      await model.drop(
        drag,
        targetTab,
        overwriteConflicts: model.conflicts(drag, targetTab),
      ),
      isFalse,
    );
    expect(target.data, {
      '/same.txt': [1],
    });
    expect(target.directories, {'/'});
  });

  testWidgets('拖动同名文件夹先确认，取消不修改，覆盖后替换目标', (tester) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = MemoryFiles()
      ..directories.add('/folder')
      ..data['/folder/new.txt'] = Uint8List.fromList([2]);
    final target = MemoryFiles()
      ..directories.add('/folder')
      ..data['/folder/old.txt'] = Uint8List.fromList([1]);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final sourceTab = model.add(0, name: 'source', files: source);
    final targetTab = model.add(1, name: 'target', files: target);
    await Future.wait([sourceTab.browse('/'), targetTab.browse('/')]);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
            initializeLocal: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> dragFolder() async {
      final row = find.byKey(ValueKey('entry-${sourceTab.id}-/folder'));
      final drag = await tester.startGesture(
        tester.getCenter(row),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(24, 0));
      await tester.pump();
      await drag.moveTo(
        tester.getCenter(find.byKey(const ValueKey('file-drop-panel-1'))),
      );
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragFolder();
    expect(find.text('覆盖 1 个同名项目？'), findsOneWidget);
    expect(find.text('folder'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('cancel-overwrite-files')));
    await tester.pumpAndSettle();
    expect(target.data['/folder/old.txt'], [1]);
    expect(target.data.containsKey('/folder/new.txt'), isFalse);

    await dragFolder();
    target.directories.add('/other');
    await targetTab.browse('/other');
    await tester.tap(find.byKey(const ValueKey('confirm-overwrite-files')));
    await tester.pumpAndSettle();
    expect(find.text('目标目录内容已变化，请重新操作'), findsOneWidget);
    expect(target.data['/folder/old.txt'], [1]);
    expect(target.data.containsKey('/folder/new.txt'), isFalse);
    await targetTab.browse('/');
    await tester.pumpAndSettle();

    await dragFolder();
    await tester.tap(find.byKey(const ValueKey('confirm-overwrite-files')));
    await tester.pumpAndSettle();
    expect(target.data.containsKey('/folder/old.txt'), isFalse);
    expect(target.data['/folder/new.txt'], [2]);
    expect(tester.takeException(), isNull);
  });

  test('多标签独立目录与选择，复制固定目标，关闭不影响借用 SSH', () async {
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final source = MemoryFiles()
      ..data['/file.txt'] = Uint8List.fromList([1, 2]);
    final target = MemoryFiles()..writeGate = Completer<void>();
    final session = FileTestSession();
    addTearDown(session.dispose);
    final a = model.add(0, name: 'local', files: source, isLocal: true);
    final b = model.add(1, name: 'remote', files: target, session: session);
    await Future.wait([a.browse(), b.browse()]);
    a.toggle(a.entries.single);
    final copying = model.copy(0);
    await Future<void>.delayed(Duration.zero);
    expect(model.locked(a), isTrue);
    model.close(1, b);
    expect(model.panes[1].tabs, contains(b));
    final other = model.add(1, name: 'other', files: MemoryFiles());
    await other.browse();
    target.writeGate!.complete();
    await copying.timeout(const Duration(seconds: 3));
    expect(target.data['/file.txt'], [1, 2]);
    expect(model.panes[1].active, other);
    model.activate(1, b.id);
    expect(b.entries.single.name, 'file.txt');
    model.close(1, b);
    expect(session.status, ConnectionStatus.connected);
    expect(model.panes[1].active, other);
  });

  test('复制缓存跨目录保持源文件，粘贴成功清空，失败保留且关闭源标签清空', () async {
    final root = await Directory.systemTemp.createTemp(
      'harbor-clipboard-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final nested = await Directory('${root.path}/nested').create();
    await File('${root.path}/first.txt').writeAsBytes([1, 2, 3]);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(
      0,
      name: 'local',
      files: LocalFiles(root.path),
      isLocal: true,
    );
    await tab.browse();
    tab.select(tab.entries.firstWhere((file) => file.name == 'first.txt'));
    model.copySelection(tab);
    final originalPath = model.clipboard!.files.single.path;
    expect(model.canPaste(tab), isFalse);
    await tab.browse(nested.path);
    expect(model.clipboard!.files.single.path, originalPath);
    expect(model.canPaste(tab), isTrue);
    await model.paste(tab);
    expect(await File('${nested.path}/first.txt').readAsBytes(), [1, 2, 3]);
    expect(model.clipboard, isNull);
    await tab.browse(root.path);
    tab.select(tab.entries.firstWhere((file) => file.name == 'first.txt'));
    model.copySelection(tab);
    await tab.browse(nested.path);
    await model.paste(tab);
    expect(model.failed, isTrue);
    expect(model.clipboard, isNotNull);
    expect(await File('${nested.path}/first.txt').readAsBytes(), [1, 2, 3]);
    model.close(0, tab);
    expect(model.clipboard, isNull);
  });

  for (final size in [
    const Size(1100, 740),
    const Size(620, 640),
    const Size(320, 568),
  ]) {
    testWidgets('SFTP 双面板与多标签适配 ${size.width}', (tester) async {
      final mobile = size.width < 600;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = FileWorkspaceModel();
      addTearDown(model.dispose);
      final source = MemoryFiles()
        ..directories.add('/folder')
        ..data['/folder/nested.txt'] = Uint8List.fromList([2])
        ..data['/file.txt'] = Uint8List.fromList([1]);
      final a = model.add(0, name: '本地文件夹', files: source, isLocal: true);
      final second = model.add(0, name: '开发服务器', files: MemoryFiles());
      model.activate(0, a.id);
      final b = model.add(1, name: '生产服务器', files: MemoryFiles());
      model.activate(0, a.id);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme().copyWith(
            platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
          ),
          home: Scaffold(
            body: FileWorkspace(
              model: model,
              hosts: const [],
              sessions: const [],
              onConnect: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('传到右侧'), findsNothing);
      expect(find.text('传到左侧'), findsNothing);
      final tabRect = tester.getRect(find.byKey(ValueKey('file-tab-${a.id}')));
      final addRect = tester.getRect(
        find.byKey(const ValueKey('add-file-tab-0')),
      );
      expect(tabRect.center.dy, closeTo(addRect.center.dy, 1));
      final toolbar = find.byKey(ValueKey('file-toolbar-${a.id}'));
      expect(tester.getSize(toolbar).height, mobile ? 48 : 40);
      expect(find.byKey(ValueKey('query-${a.id}-${a.path}')), findsNothing);
      await tester.tap(
        find.descendant(
          of: toolbar,
          matching: find.byIcon(Icons.search_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(ValueKey('query-${a.id}-${a.path}')),
        'missing',
      );
      await tester.pumpAndSettle();
      expect(a.visibleEntries, isEmpty);
      await tester.tap(
        find.descendant(
          of: toolbar,
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();
      expect(a.query, isEmpty);
      expect(find.byKey(ValueKey('path-${a.id}-${a.path}')), findsOneWidget);
      if (mobile) {
        expect(find.text('左侧面板'), findsNothing);
        expect(find.text('右侧面板'), findsNothing);
        expect(find.byKey(const ValueKey('file-panel-1')), findsNothing);
        expect(find.byKey(const ValueKey('paste-files')), findsNothing);
        await tester.drag(
          find.byKey(ValueKey('entry-${a.id}-/file.txt')),
          const Offset(70, 0),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FloatingActionButton>(
                find.byKey(const ValueKey('copy-files')),
              )
              .elevation,
          0,
        );
        await tester.tap(find.byKey(const ValueKey('copy-files')));
        await tester.pumpAndSettle();
        expect(model.clipboard!.files.single.name, 'file.txt');
        expect(
          tester
              .widget<FloatingActionButton>(
                find.byKey(const ValueKey('paste-files')),
              )
              .onPressed,
          isNull,
        );
        await tester.ensureVisible(find.byKey(ValueKey('file-tab-${b.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('file-tab-${b.id}')));
        await tester.pumpAndSettle();
        expect(model.activeTab, b);
        await tester.tap(find.byKey(const ValueKey('paste-files')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('paste-files')), findsNothing);
      } else {
        // Desktop still supports direct file dragging between panels.
        final drag = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('entry-${a.id}-/file.txt'))),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(24, 0));
        await tester.pump();
        await drag.moveTo(
          tester.getCenter(find.byKey(const ValueKey('file-drop-panel-1'))),
        );
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
        final folderRow = find.byKey(ValueKey('entry-${a.id}-/folder'));
        expect(
          find.ancestor(
            of: folderRow,
            matching: find.byType(Draggable<FileDragData>),
          ),
          findsOneWidget,
        );
        final folderDrag = await tester.startGesture(
          tester.getCenter(folderRow),
          kind: PointerDeviceKind.mouse,
        );
        await folderDrag.moveBy(const Offset(24, 0));
        await tester.pump();
        await folderDrag.moveTo(
          tester.getCenter(find.byKey(const ValueKey('file-drop-panel-1'))),
        );
        await tester.pump();
        await folderDrag.up();
        await tester.pumpAndSettle();
      }
      expect(b.entries.map((entry) => entry.name), contains('file.txt'));
      if (!mobile) {
        expect(b.entries.map((entry) => entry.name), contains('folder'));
      }
      await tester.ensureVisible(find.byKey(ValueKey('file-tab-${second.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('file-tab-${second.id}')));
      await tester.pumpAndSettle();
      expect(model.panes[0].active, second);
      await tester.tap(find.byKey(ValueKey('close-file-tab-${second.id}')));
      await tester.pumpAndSettle();
      expect(model.panes[0].active, a);
      if (size.width >= 600) {
        final before = tester
            .getSize(find.byKey(const ValueKey('file-panel-0')))
            .width;
        await tester.drag(
          find.byKey(const ValueKey('sftp-split-handle')),
          const Offset(40, 0),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('file-panel-0'))).width,
          greaterThan(before),
        );
      } else {
        await tester.ensureVisible(find.byKey(ValueKey('file-tab-${b.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('file-tab-${b.id}')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('file-tab-${b.id}')), findsOneWidget);
        // Expanding the window restores both desktop panels without losing tabs.
        tester.view.physicalSize = const Size(1100, 740);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('file-panel-0')), findsOneWidget);
        expect(find.byKey(const ValueKey('file-panel-1')), findsOneWidget);
        expect(model.panes[0].tabs, contains(a));
        expect(model.panes[1].tabs, contains(b));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('独立 SFTP 导航，终端入口复用标签，切换后终端状态保留', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = FileTestSession();
    final workspace = _SessionWorkspace(session);
    await tester.pumpWidget(HarborApp(model: workspace));
    await tester.pumpAndSettle();
    final terminal = tester.state(find.byType(TerminalView));
    await tester.tap(find.byKey(const ValueKey('open-sftp')));
    await tester.pumpAndSettle();
    expect(workspace.showingFiles, isTrue);
    expect(workspace.fileWorkspace.panes[1].tabs, hasLength(1));
    await tester.tap(find.byKey(ValueKey('session-menu-${session.id}')));
    await tester.pumpAndSettle();
    expect(workspace.showingFiles, isFalse);
    expect(tester.state(find.byType(TerminalView)), same(terminal));
    await tester.tap(find.byKey(const ValueKey('open-sftp')));
    await tester.pumpAndSettle();
    expect(workspace.fileWorkspace.panes[1].tabs, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('拖放固定源文件，支持批量并拒绝自身、关闭和忙碌目标', () async {
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final files = MemoryFiles()
      ..data['/a.txt'] = Uint8List.fromList([1])
      ..data['/b.txt'] = Uint8List.fromList([2])
      ..data['/c.txt'] = Uint8List.fromList([3]);
    final target = MemoryFiles()..writeGate = Completer<void>();
    final sourceTab = model.add(0, name: 'source', files: files);
    final targetTab = model.add(1, name: 'target', files: target);
    await Future.wait([sourceTab.browse(), targetTab.browse()]);
    sourceTab.toggle(sourceTab.entries[0]);
    sourceTab.toggle(sourceTab.entries[1]);
    final batch = model.dragData(sourceTab, sourceTab.entries[0]);
    final single = model.dragData(sourceTab, sourceTab.entries[2]);
    expect(single.files.map((file) => file.name), ['c.txt']);
    expect(model.canDrop(batch, sourceTab), isFalse);
    final other = model.add(0, name: 'other', files: MemoryFiles());
    await other.browse();
    sourceTab.selected.clear();
    final copying = model.drop(batch, targetTab);
    await Future<void>.delayed(Duration.zero);
    expect(model.canDrop(single, targetTab), isFalse);
    target.writeGate!.complete();
    await copying.timeout(const Duration(seconds: 3));
    expect(target.data.keys, unorderedEquals(['/a.txt', '/b.txt']));
    expect(model.panes[0].active, other);
    model.close(0, sourceTab);
    expect(model.canDrop(single, targetTab), isFalse);
  });

  testWidgets('目录与空白区右键菜单在当前目录创建文件夹和文件，名称校验与独占生效', (tester) async {
    final files = MemoryFiles()
      ..data['/a.txt'] = Uint8List.fromList([7])
      ..directories.add('/folder');
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    await pumpFileWorkspace(tester, model);

    Finder menu(String key) => find.byKey(ValueKey(key));
    Future<void> openRowMenu(String path) async {
      await tester.tap(
        find.byKey(ValueKey('entry-${tab.id}-$path')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
    }

    // 目录右键同样打开菜单，创建项齐全且不带删除项。
    await openRowMenu('/folder');
    expect(menu('create-directory-entry'), findsOneWidget);
    expect(menu('create-file-entry'), findsOneWidget);
    expect(menu('copy-entry-path'), findsOneWidget);
    expect(menu('delete-selected-files'), findsNothing);

    // 空名不创建。
    await tester.tap(menu('create-directory-entry'));
    await tester.pumpAndSettle();
    expect(menu('create-directory-dialog'), findsOneWidget);
    expect(find.text('位置：/'), findsOneWidget);
    await tester.tap(menu('confirm-create-entry'));
    await tester.pumpAndSettle();
    expect(menu('create-directory-dialog'), findsOneWidget);
    expect(files.directories, unorderedEquals(['/', '/folder']));

    // 斜杠名称被拒绝，回车走同一套校验而不是绕过它。
    await tester.enterText(menu('create-entry-name'), 'a/b');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(menu('create-directory-dialog'), findsOneWidget);
    expect(files.directories, unorderedEquals(['/', '/folder']));

    // 合法名称落在标签页当前目录，而不是右键的目录。
    await tester.enterText(menu('create-entry-name'), 'logs');
    await tester.tap(menu('confirm-create-entry'));
    await tester.pumpAndSettle();
    expect(files.directories, contains('/logs'));
    expect(tab.entries.map((entry) => entry.name), contains('logs'));

    // 空白区只提供创建，不涉及任何条目。
    final panel = tester.getRect(find.byKey(const ValueKey('file-panel-0')));
    await tester.tapAt(
      Offset(panel.center.dx, panel.bottom - 120),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(menu('blank-create-directory'), findsOneWidget);
    expect(menu('blank-create-file'), findsOneWidget);
    expect(menu('copy-entry-path'), findsNothing);
    await tester.tap(menu('blank-create-file'));
    await tester.pumpAndSettle();
    await tester.enterText(menu('create-entry-name'), 'notes.txt');
    await tester.tap(menu('confirm-create-entry'));
    await tester.pumpAndSettle();
    expect(files.data.containsKey('/notes.txt'), isTrue);

    // 独占创建：同名文件保持原样。
    await openRowMenu('/a.txt');
    await tester.tap(menu('create-file-entry'));
    await tester.pumpAndSettle();
    await tester.enterText(menu('create-entry-name'), 'a.txt');
    await tester.tap(menu('confirm-create-entry'));
    await tester.pumpAndSettle();
    expect(files.data['/a.txt'], [7]);
    expect(model.failed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('空目录空白区右键菜单在空目录当前路径创建', (tester) async {
    final files = MemoryFiles()..directories.add('/empty');
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    await pumpFileWorkspace(tester, model);
    await tab.browse('/empty');
    await tester.pumpAndSettle();
    expect(tab.entries, isEmpty);

    final panel = tester.getRect(find.byKey(const ValueKey('file-panel-0')));
    await tester.tapAt(panel.center, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('blank-create-directory')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('blank-create-directory')));
    await tester.pumpAndSettle();
    expect(find.text('位置：/empty'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('create-entry-name')),
      'inner',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-create-entry')));
    await tester.pumpAndSettle();
    expect(files.directories, contains('/empty/inner'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('移动端长按目录打开菜单，不再只对文件生效', (tester) async {
    final files = MemoryFiles()..directories.add('/folder');
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    await pumpFileWorkspace(
      tester,
      model,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );
    await tester.longPress(find.byKey(ValueKey('entry-${tab.id}-/folder')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('create-directory-entry')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('copy-entry-path')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 空目录在移动端用长按空白区打开同一份创建菜单。
    await tab.browse('/folder');
    await tester.pumpAndSettle();
    expect(tab.entries, isEmpty);
    final panel = tester.getRect(find.byKey(const ValueKey('file-panel-0')));
    await tester.longPressAt(panel.center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('blank-create-file')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄低视口加软键盘时新建对话框可滚动，输入与确认都能到达', (tester) async {
    final files = MemoryFiles();
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    tester.view.physicalSize = const Size(360, 400);
    tester.view.devicePixelRatio = 1;
    // 横屏手机软键盘占掉一半高度，对话框只剩很窄的一条。
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme().copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: FileWorkspace(
            model: model,
            hosts: const [],
            sessions: const [],
            onConnect: (_) async => null,
            initializeLocal: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 空目录的空白区就在列表面板中间，短视口下也只有它能可靠命中。
    final empty = find.text('没有可显示的文件');
    expect(empty, findsOneWidget);
    await tester.tapAt(tester.getCenter(empty), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('blank-create-directory')));
    await tester.pumpAndSettle();

    final dialog = find.byKey(const ValueKey('create-directory-dialog'));
    expect(dialog, findsOneWidget);
    // 对话框本体（标题与按钮）留在软键盘之上，内容改为可滚动而不是溢出。
    expect(
      tester.getRect(find.text('创建文件夹')).bottom,
      lessThanOrEqualTo(200.0),
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(SingleChildScrollView)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // 名称输入在滚动区域内可达，滚动到可见后可以正常输入。
    final name = find.byKey(const ValueKey('create-entry-name'));
    await tester.ensureVisible(name);
    await tester.pumpAndSettle();
    await tester.enterText(name, 'short-view');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(name).controller!.text, 'short-view');
    expect(tester.takeException(), isNull);

    // 确认按钮始终可达，并且真的创建了目录。
    final confirm = find.byKey(const ValueKey('confirm-create-entry'));
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(200.0));
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(files.directories, contains('/short-view'));
    expect(tab.entries.map((entry) => entry.name), contains('short-view'));
    // 创建成功后状态栏出现，面板更矮：工具条和列表仍然留在视口内。
    expect(
      tester
          .getRect(find.byKey(ValueKey('file-toolbar-${tab.id}')))
          .bottom,
      lessThanOrEqualTo(200.0),
    );
    expect(
      find.byKey(ValueKey('entry-${tab.id}-/short-view')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('复制路径使用真实完整路径，多选换行且不改动原多选', (tester) async {
    final copies = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copies.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final files = MemoryFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..data['/b.txt'] = Uint8List(1)
      ..data['/c.txt'] = Uint8List(1)
      ..directories.add('/folder');
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'files', files: files);
    await pumpFileWorkspace(tester, model);

    Future<void> copyFrom(String path) async {
      await tester.tap(
        find.byKey(ValueKey('entry-${tab.id}-$path')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('copy-entry-path')));
      await tester.pumpAndSettle();
    }

    tab.select(tab.entries.firstWhere((entry) => entry.name == 'a.txt'));
    tab.select(
      tab.entries.firstWhere((entry) => entry.name == 'b.txt'),
      toggleSelection: true,
    );
    await tester.pumpAndSettle();
    await copyFrom('/b.txt');
    expect(copies, ['/a.txt\n/b.txt']);
    expect(tab.selected, {'/a.txt', '/b.txt'});

    // 目录没有可写能力也照样复制路径，并且不改动已有选择。
    await copyFrom('/folder');
    expect(copies.last, '/folder');
    expect(tab.selected, {'/a.txt', '/b.txt'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('设置权限读取远端权限，勾选与八进制同步并保留特殊位', (tester) async {
    final files = MemoryPermissionsFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..permissions = const FilePermissions(
        mode: 420,
        userId: 1000,
        groupId: 1000,
      );
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await pumpFileWorkspace(tester, model);

    await tester.tap(
      find.byKey(ValueKey('entry-${tab.id}-/a.txt')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('set-entry-permissions')), findsOneWidget);
    expect(find.byKey(const ValueKey('set-entry-owner')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('set-entry-permissions')));
    await tester.pumpAndSettle();
    expect(files.readCalls, 1);

    Checkbox box(String id) =>
        tester.widget<Checkbox>(find.byKey(ValueKey('permission-$id')));
    final octal = find.byKey(const ValueKey('permission-octal'));
    expect(tester.widget<TextField>(octal).controller!.text, '644');
    expect(box('user-read').value, isTrue);
    expect(box('user-write').value, isTrue);
    expect(box('user-exec').value, isFalse);
    expect(box('group-exec').value, isFalse);
    expect(box('setuid').value, isFalse);

    // 勾选回写八进制。
    await tester.tap(find.byKey(const ValueKey('permission-user-exec')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(octal).controller!.text, '744');

    // 八进制回写勾选，4 位含特殊位（5 = setuid + 粘滞位）。
    await tester.enterText(octal, '5755');
    await tester.pumpAndSettle();
    expect(box('setuid').value, isTrue);
    expect(box('setgid').value, isFalse);
    expect(box('sticky').value, isTrue);
    expect(box('user-read').value, isTrue);
    expect(box('other-exec').value, isTrue);

    // 特殊位勾选同样回写八进制。
    await tester.tap(find.byKey(const ValueKey('permission-sticky')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(octal).controller!.text, '4755');
    await tester.tap(find.byKey(const ValueKey('permission-sticky')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(octal).controller!.text, '5755');

    await tester.tap(find.byKey(const ValueKey('confirm-entry-permissions')));
    await tester.pumpAndSettle();
    final write = files.writes.single;
    expect(write.$1, 3053);
    expect(write.$2, isNull);
    expect(write.$3, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('权限组同时提交 UID 和 GID，未知身份保持空白不回填 0', (tester) async {
    final files = MemoryPermissionsFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..permissions = const FilePermissions(
        mode: 420,
        userId: 1000,
        groupId: 1000,
      );
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await pumpFileWorkspace(tester, model);

    final uid = find.byKey(const ValueKey('permission-uid'));
    final gid = find.byKey(const ValueKey('permission-gid'));
    Future<void> openOwner() async {
      await tester.tap(
        find.byKey(ValueKey('entry-${tab.id}-/a.txt')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('set-entry-owner')));
      await tester.pumpAndSettle();
    }

    await openOwner();
    expect(tester.widget<TextField>(uid).controller!.text, '1000');
    expect(tester.widget<TextField>(gid).controller!.text, '1000');
    await tester.enterText(gid, '2000');
    await tester.tap(find.byKey(const ValueKey('confirm-entry-permissions')));
    await tester.pumpAndSettle();
    final owner = files.writes.single;
    expect(owner.$1, isNull);
    expect(owner.$2, 1000);
    expect(owner.$3, 2000);

    // 服务器没有报告身份：两个字段都是空白，既不是 0 也不能只提交一个。
    files.permissions = const FilePermissions(mode: 420);
    await openOwner();
    expect(tester.widget<TextField>(uid).controller!.text, isEmpty);
    expect(tester.widget<TextField>(gid).controller!.text, isEmpty);
    await tester.tap(find.byKey(const ValueKey('confirm-entry-permissions')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('permission-owner-error')),
      findsOneWidget,
    );
    expect(files.writes, hasLength(1));
    await tester.enterText(uid, '0');
    await tester.tap(find.byKey(const ValueKey('confirm-entry-permissions')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('permission-owner-error')),
      findsOneWidget,
    );
    expect(files.writes, hasLength(1));
    await tester.enterText(gid, '4294967295');
    await tester.tap(find.byKey(const ValueKey('confirm-entry-permissions')));
    await tester.pumpAndSettle();
    final last = files.writes.last;
    expect(last.$1, isNull);
    expect(last.$2, 0);
    expect(last.$3, 4294967295);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('符号链接条目不提供权限入口', (tester) async {
    final files = MemoryPermissionsFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..links.add('/shortcut');
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await pumpFileWorkspace(tester, model);

    await tester.tap(
      find.byKey(ValueKey('entry-${tab.id}-/shortcut')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('set-entry-permissions')), findsNothing);
    expect(find.byKey(const ValueKey('set-entry-owner')), findsNothing);
    expect(find.byKey(const ValueKey('copy-entry-path')), findsOneWidget);
    expect(files.readCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('权限读取防重入、失败提示、取消与提交失败都有实际效果', (tester) async {
    final files = MemoryPermissionsFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..readGate = Completer<void>();
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await pumpFileWorkspace(tester, model);

    Finder row() => find.byKey(ValueKey('entry-${tab.id}-/a.txt'));
    Future<void> openRowMenu() async {
      await tester.tap(row(), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
    }

    // 读取挂起时再次右键不会重入。
    await openRowMenu();
    await tester.tap(find.byKey(const ValueKey('set-entry-permissions')));
    await tester.pumpAndSettle();
    expect(files.readCalls, 1);
    await tester.tap(row(), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('set-entry-permissions')), findsNothing);
    expect(find.byKey(const ValueKey('blank-create-directory')), findsNothing);
    expect(files.readCalls, 1);
    files.readGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('entry-permissions-dialog')),
      findsOneWidget,
    );

    // 取消不提交。
    await tester.tap(find.byKey(const ValueKey('cancel-entry-permissions')));
    await tester.pumpAndSettle();
    expect(files.writes, isEmpty);

    // 读取异常沿用既有错误反馈，且不打开对话框。
    files.readGate = null;
    files.readError = StateError('permission denied');
    await openRowMenu();
    await tester.tap(find.byKey(const ValueKey('set-entry-permissions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-permissions-dialog')), findsNothing);
    expect(find.textContaining('permission denied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    files.readError = null;

    // 提交失败只反映在状态栏，界面不报成功。
    files.writeError = StateError('operation not permitted');
    await openRowMenu();
    await tester.tap(find.byKey(const ValueKey('set-entry-permissions')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('permission-octal')),
      '700',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-entry-permissions')));
    await tester.pumpAndSettle();
    expect(files.writes, isEmpty);
    expect(model.failed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('读取期间标签页被关闭后不再提交到错误目标', (tester) async {
    final files = MemoryPermissionsFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..readGate = Completer<void>();
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await pumpFileWorkspace(tester, model);

    await tester.tap(
      find.byKey(ValueKey('entry-${tab.id}-/a.txt')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('set-entry-permissions')));
    await tester.pumpAndSettle();
    expect(files.readCalls, 1);
    model.close(0, tab);
    await tester.pumpAndSettle();
    files.readGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('entry-permissions-dialog')), findsNothing);
    expect(files.writes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('删除进行中右键不打开菜单，权限与创建项都不出现', (tester) async {
    final files = MemoryPermissionsFiles()
      ..data['/a.txt'] = Uint8List(1)
      ..data['/b.txt'] = Uint8List(1)
      ..deleteGate = Completer<void>();
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final tab = model.add(0, name: 'SFTP', files: files);
    await pumpFileWorkspace(tester, model);

    final first = tab.entries.firstWhere((entry) => entry.name == 'a.txt');
    tab.select(first);
    final deleting = model.deleteFiles(model.dragData(tab, first));
    await tester.pump();
    expect(model.busy, isTrue);
    await tester.tap(
      find.byKey(ValueKey('entry-${tab.id}-/b.txt')),
      buttons: kSecondaryMouseButton,
    );
    // 删除进行中状态栏是不定进度条，pumpAndSettle 永远不会静止。
    await tester.pump();
    expect(find.byKey(const ValueKey('set-entry-permissions')), findsNothing);
    expect(find.byKey(const ValueKey('blank-create-directory')), findsNothing);
    files.deleteGate!.complete();
    await deleting;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 以固定窗口尺寸渲染文件工作区，供菜单、剪贴板与权限对话框测试复用。
Future<void> pumpFileWorkspace(
  WidgetTester tester,
  FileWorkspaceModel model, {
  TargetPlatform platform = TargetPlatform.windows,
  Size size = const Size(1100, 740),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: harborTheme().copyWith(platform: platform),
      home: Scaffold(
        body: FileWorkspace(
          model: model,
          hosts: const [],
          sessions: const [],
          onConnect: (_) async => null,
          initializeLocal: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 打开远端文件菜单里的代码编辑器，并等待内容读取完成。
///
/// 编辑器获得焦点后光标会周期性闪烁，因此打开期间只能显式 `pump`。
Future<void> openRemoteEditor(WidgetTester tester, Finder row) async {
  await tester.longPress(row);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('edit-remote-file')));
  await tester.pump();
  // Covers the 500 ms emphasized dialog entrance so geometry is final.
  await tester.pump(const Duration(milliseconds: 600));
}

/// 远端代码编辑器的内容控制器。
CodeLineEditingController remoteEditorController(WidgetTester tester) => tester
    .widget<CodeEditor>(find.byKey(const ValueKey('remote-text-content')))
    .controller!;

/// 模拟用户在编辑器里整段替换输入（IME 之外的控制器交互）。
void replaceRemoteText(WidgetTester tester, String text) {
  final controller = remoteEditorController(tester);
  controller.selectAll();
  controller.replaceSelection(text);
}

/// 行号栏实际渲染出的行数。
int remoteLineNumberCount(WidgetTester tester) => tester
    .widget<DefaultCodeLineNumber>(find.byType(DefaultCodeLineNumber))
    .notifier
    .value!
    .paragraphs
    .length;

/// 头部展示的语法高亮语言标签。
String remoteLanguageLabel(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('remote-text-language')),
        matching: find.byType(Text),
      ),
    )
    .data!;

class MemoryFiles implements RemoteFileSystem {
  @override
  String childPath(String directory, String name) =>
      remoteChild(directory, name);
  String? failDeletePath;
  Completer<void>? deleteGate;
  Completer<void>? createDirectoryGate;
  bool failPublish = false;
  @override
  Future<void> deleteFile(String path) async {
    if (deleteGate != null) await deleteGate!.future;
    if (path == failDeletePath) throw StateError('permission denied');
    if (data.remove(path) == null) throw StateError('missing file');
  }

  final directories = <String>{'/'};

  @override
  Future<void> createDirectory(String path) async {
    if (createDirectoryGate != null) await createDirectoryGate!.future;
    if (directories.contains(path) || data.containsKey(path)) {
      throw StateError('already exists');
    }
    directories.add(path);
  }

  /// 独占创建：已有同名文件、目录或链接时抛出，绝不覆盖。
  @override
  Future<void> createFileExclusive(String path) async {
    if (data.containsKey(path) || directories.contains(path)) {
      throw StateError('already exists');
    }
    data[path] = Uint8List(0);
  }

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) async {
    if (!directories.contains(path)) throw StateError('missing directory');
    final prefix = path.endsWith('/') ? path : '$path/';
    final children =
        directories.any((item) => item.startsWith(prefix)) ||
        data.keys.any((item) => item.startsWith(prefix));
    if (children && !recursive) throw StateError('directory not empty');
    directories.removeWhere((item) => item == path || item.startsWith(prefix));
    data.removeWhere((item, _) => item.startsWith(prefix));
  }

  @override
  Future<void> renameExclusive(String oldPath, String newPath) async {
    if (failPublish &&
        oldPath.split('/').last.startsWith('.harbor-incoming-')) {
      throw StateError('publish failed');
    }
    if (directories.contains(newPath) || data.containsKey(newPath)) {
      throw StateError('already exists');
    }
    final file = data.remove(oldPath);
    if (file != null) {
      data[newPath] = file;
      if (failBackupAfterMove &&
          !oldPath.split('/').last.startsWith('.harbor-')) {
        failBackupAfterMove = false;
        throw StateError('rename reply lost');
      }
      return;
    }
    if (!directories.contains(oldPath)) throw StateError('missing entry');
    final prefix = '$oldPath/';
    final movedDirectories = [
      for (final item in directories)
        if (item == oldPath || item.startsWith(prefix)) item,
    ];
    final movedFiles = {
      for (final entry in data.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
    directories.removeAll(movedDirectories);
    data.removeWhere((path, _) => movedFiles.containsKey(path));
    for (final path in movedDirectories) {
      directories.add('$newPath${path.substring(oldPath.length)}');
    }
    for (final entry in movedFiles.entries) {
      data['$newPath${entry.key.substring(oldPath.length)}'] = entry.value;
    }
  }

  final data = <String, Uint8List>{};
  bool failRead = false, failWrite = false, failBackupAfterMove = false;
  int readBytes = 0;
  Completer<void>? writeGate;
  int writeGateAfterBytes = 0;
  @override
  Future<RemoteDirectory> browse(String path) async {
    final directory = path == '~' ? '/' : path;
    return RemoteDirectory(directory, [
      for (final item in directories)
        if (item != directory && remoteParent(item) == directory)
          RemoteFile(name: item.split('/').last, path: item, isDirectory: true),
      for (final entry in data.entries)
        if (remoteParent(entry.key) == directory)
          RemoteFile(
            name: entry.key.split('/').last,
            path: entry.key,
            size: entry.value.length,
          ),
    ]);
  }

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    readBytes = 0;
    final bytes = data[path]!;
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      cancellation.check();
      final chunk = Uint8List.sublistView(
        bytes,
        offset,
        (offset + 65536).clamp(0, bytes.length),
      );
      readBytes += chunk.length;
      await write(chunk);
      if (failRead) throw StateError('source failed');
      onProgress(readBytes);
    }
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int) onProgress,
  }) async {
    if (data.containsKey(path) || directories.contains(path)) {
      throw StateError('already exists');
    }
    final bytes = BytesBuilder();
    await for (final chunk in source) {
      if (writeGate != null && bytes.length >= writeGateAfterBytes) {
        await writeGate!.future;
      }
      cancellation.check();
      if (failWrite) throw StateError('destination failed');
      bytes.add(chunk);
      onProgress(bytes.length);
    }
    cancellation.check();
    data[path] = bytes.takeBytes();
  }
}

/// 只有明确实现权限能力的替身才带权限语义，本地 fake 不会自动获得。
class MemoryPermissionsFiles extends MemoryFiles
    implements RemoteFilePermissions {
  FilePermissions permissions = const FilePermissions();
  final links = <String>{};
  int readCalls = 0;
  Completer<void>? readGate;
  Object? readError;
  Completer<void>? setPermissionsGate;
  Object? writeError;
  final writes = <(int?, int?, int?)>[];

  @override
  Future<RemoteDirectory> browse(String path) async {
    final directory = await super.browse(path);
    if (links.isEmpty) return directory;
    return RemoteDirectory(directory.path, [
      ...directory.entries,
      for (final link in links)
        if (remoteParent(link) == directory.path)
          RemoteFile(name: link.split('/').last, path: link, isLink: true),
    ]);
  }

  @override
  Future<FilePermissions> readPermissions(String path) async {
    readCalls++;
    if (readGate != null) await readGate!.future;
    if (readError != null) throw readError!;
    return permissions;
  }

  @override
  Future<void> setPermissions(
    String path, {
    int? mode,
    int? userId,
    int? groupId,
  }) async {
    if (setPermissionsGate != null) await setPermissionsGate!.future;
    if (writeError != null) throw writeError!;
    writes.add((mode, userId, groupId));
    permissions = FilePermissions(
      mode: mode ?? permissions.mode,
      userId: userId ?? permissions.userId,
      groupId: groupId ?? permissions.groupId,
    );
  }
}

/// Like a real SFTP server, rejects directories that do not exist.
class _MissingAwareFiles extends MemoryFiles {
  @override
  Future<RemoteDirectory> browse(String path) {
    if (path != '~' && !directories.contains(path)) {
      throw StateError('no such directory');
    }
    return super.browse(path);
  }
}

class _SessionWorkspace extends WorkspaceModel {
  final _files = FileWorkspaceModel(localHome: () => MemoryFiles());
  @override
  FileWorkspaceModel get fileWorkspace => _files;
  _SessionWorkspace(this.session) : super(memoryRepository()) {
    activeSessionId = session.id;
  }
  final SshConnection session;
  @override
  List<SshConnection> get sessions => [session];
  @override
  SshConnection? get activeSession =>
      activeSessionId == session.id ? session : null;
  @override
  void dispose() {
    super.dispose();
    session.dispose();
  }
}
