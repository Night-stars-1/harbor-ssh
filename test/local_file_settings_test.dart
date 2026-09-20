import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/ui/local_file_settings.dart';
import 'package:harbor_ssh/ui/settings_page.dart';
import 'package:harbor_ssh/ui/settings_window_bridge.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  test('路径持久化，初始面板与新增标签使用默认路径，旧标签保留位置', () async {
    final directory = await Directory.systemTemp.createTemp(
      'harbor-local-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final first = await Directory('${directory.path}/first').create();
    final second = await Directory('${directory.path}/second').create();
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    addTearDown(model.dispose);
    await model.saveDefaultLocalPath(first.path);
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    addTearDown(restored.dispose);
    expect(restored.defaultLocalPath, first.path.replaceAll('\\', '/'));
    restored.fileWorkspace.initializeDefaultLocal();
    final initial = restored.fileWorkspace.panes[0].active!;
    await initial.browse();
    expect(initial.path, restored.defaultLocalPath);
    await restored.saveDefaultLocalPath(second.path);
    final next = (await restored.fileWorkspace.addLocal(1))!;
    await next.browse();
    expect(next.path, second.path.replaceAll('\\', '/'));
    expect(initial.path, first.path.replaceAll('\\', '/'));
    for (final invalid in ['relative/path', '${directory.path}/missing']) {
      await expectLater(
        restored.saveDefaultLocalPath(invalid),
        throwsA(isA<SyncFailure>()),
      );
      expect(restored.defaultLocalPath, second.path.replaceAll('\\', '/'));
    }
    await restored.saveDefaultLocalPath('');
    final reset = WorkspaceModel(repository);
    await reset.initialize();
    expect(reset.defaultLocalPath, isEmpty);
    reset.dispose();
  });

  testWidgets('独立设置窗口保存路径后主窗口立即生效', (tester) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'harbor-path-bridge-',
      );
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      final host = SettingsWindowHost(LocalSyncSettingsController(model));
      final remote = RemoteSyncSettingsController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(settingsWindowChannel, host.handle);
      try {
        await remote.initialize();
        await remote.saveDefaultLocalPath(directory.path);
        expect(remote.defaultLocalPath, model.defaultLocalPath);
        expect(model.defaultLocalPath, directory.path.replaceAll('\\', '/'));
        await expectLater(
          remote.saveDefaultLocalPath('relative'),
          throwsA(isA<SyncFailure>()),
        );
        await remote.saveDefaultLocalPath('');
        expect(model.defaultLocalPath, isEmpty);
      } finally {
        remote.dispose();
        host.dispose();
        model.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(settingsWindowChannel, null);
        await directory.delete();
      }
    });
  });

  for (final size in [const Size(320, 640), const Size(840, 820)]) {
    testWidgets('路径设置适配 $size，切换分类保留草稿，可保存和恢复', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      final controller = _FormController(model);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: SettingsPage(
              controller: controller,
              desktop: true,
              standalone: true,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('settings-category-0')));
      await tester.pumpAndSettle();
      final path = find.byKey(const ValueKey('default-local-path'));
      await tester.enterText(path, '/example/folder');
      if (size.width < 700) {
        await tester.tap(find.byKey(const ValueKey('settings-category-back')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('settings-category-1')));
      await tester.pumpAndSettle();
      expect(find.byType(LocalFileSettings), findsNothing);
      if (size.width < 700) {
        await tester.tap(find.byKey(const ValueKey('settings-category-back')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('settings-category-0')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(path).controller!.text,
        '/example/folder',
      );
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(model.defaultLocalPath, '/example/folder');
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('默认本地文件路径已保存'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('恢复用户目录'));
      await tester.tap(find.text('恢复用户目录'));
      await tester.pumpAndSettle();
      expect(model.defaultLocalPath, isEmpty);
      expect(tester.widget<TextField>(path).controller!.text, isEmpty);
      expect(find.text('默认本地文件路径已保存'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('已恢复用户目录'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('已恢复用户目录'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      model.dispose();
    });
  }
}

class _FormController extends LocalSyncSettingsController {
  _FormController(super.model);
  @override
  Future<void> saveDefaultLocalPath(String path) async {
    model.fileWorkspace.defaultLocalPath = path;
    notifyListeners();
  }
}
