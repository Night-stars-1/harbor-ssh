import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/cloud_sync_settings.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';

import 'support.dart';

void main() {
  testWidgets('自动同步在更改后触发、定时拉取，关闭后停止', (tester) async {
    final model = _AutomaticModel();
    await model.initialize();
    const settings = WebDavSettings(
      url: 'https://dav.example.com/HarborSSH/',
      username: 'test',
      password: 'app-password',
      encryptionPassword: 'encryption-password',
      automatic: true,
    );
    await model.configureSync(settings);
    await model.saveHost(testHost, null);
    await tester.pump(const Duration(seconds: 1));
    expect(model.syncCalls, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(model.syncCalls, 1);
    await tester.pump(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(model.syncCalls, 2);
    await model.configureSync(
      WebDavSettings(
        url: settings.url,
        username: settings.username,
        password: settings.password,
        encryptionPassword: settings.encryptionPassword,
      ),
    );
    await tester.pump(const Duration(minutes: 3));
    expect(model.syncCalls, 2);
    model.dispose();
  });
  for (final width in [320.0, 1280.0]) {
    testWidgets('Gist 设置适配 $width，保留服务草稿并回填创建的 ID', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = _GistModel();
      await model.initialize();
      final controller = LocalSyncSettingsController(model);
      addTearDown(model.dispose);
      addTearDown(controller.dispose);
      Widget page(int version) => MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: CloudSyncSettings(
            key: ValueKey(version),
            controller: controller,
          ),
        ),
      );
      Finder field(String name) => find.byKey(ValueKey('sync-field-$name'));
      Future<void> select(String name) async {
        final dropdown = find.byKey(const ValueKey('sync-provider'));
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(name).last);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(page(0));
      await tester.enterText(field('目录地址'), 'https://dav.example.com/');
      await select('GitHub Gist');
      expect(field('目录地址'), findsNothing);
      expect(field('GitHub Token'), findsNothing);
      expect(find.text('网页登录'), findsOneWidget);
      await controller.saveGitHubAccount('github-test-token', 'harbor-user');
      await tester.pumpAndSettle();
      expect(find.text('@harbor-user'), findsOneWidget);
      await tester.ensureVisible(field('加密密码'));
      await tester.enterText(field('加密密码'), 'shared-encryption-password');
      await select('WebDAV');
      expect(
        tester.widget<TextField>(field('目录地址')).controller!.text,
        'https://dav.example.com/',
      );
      await select('GitHub Gist');
      expect(find.text('@harbor-user'), findsOneWidget);
      await tester.ensureVisible(find.text('保存并同步'));
      await tester.tap(find.text('保存并同步'));
      await tester.pumpAndSettle();
      expect(model.cloudSync.settings!.provider, SyncProvider.gist);
      expect(
        tester.widget<TextField>(field('Gist ID')).controller!.text,
        '0123456789abcdef',
      );
      await tester.pumpWidget(page(1));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('Gist ID')).controller!.text,
        '0123456789abcdef',
      );
      expect(field('GitHub Token'), findsNothing);
      expect(find.text('@harbor-user'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets('WebDAV 设置适配 $width，保存并重新打开保留配置', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Workspace(model: model, onToggleTheme: () {}),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('settings-button')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('cloud-sync-button')), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.tap(find.text('云同步').first);
      await tester.pumpAndSettle();
      for (final action in ['测试连接', '保存', '保存并同步']) {
        await tester.ensureVisible(find.text(action));
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        expect(find.text('请输入 HTTPS WebDAV 目录地址'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('请输入 HTTPS WebDAV 目录地址'),
          ),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('请输入 HTTPS WebDAV 目录地址'), findsNothing);
      }
      final fields = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('sync-field-'),
      );
      await tester.enterText(
        fields.at(0),
        'https://dav.example.com/HarborSSH/',
      );
      await tester.enterText(fields.at(1), 'test-user');
      await tester.enterText(fields.at(2), 'webdav-app-password');
      await tester.ensureVisible(fields.at(3));
      await tester.enterText(fields.at(3), 'shared-encryption-password');
      expect(tester.widget<TextField>(fields.at(2)).obscureText, isTrue);
      expect(tester.widget<TextField>(fields.at(3)).obscureText, isTrue);
      for (final index in [2, 3]) {
        final toggle = find.descendant(
          of: fields.at(index),
          matching: find.byType(IconButton),
        );
        final original = tester
            .widget<TextField>(fields.at(index))
            .controller!
            .text;
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(fields.at(index)).obscureText, isFalse);
        expect(
          tester.widget<TextField>(fields.at(index == 2 ? 3 : 2)).obscureText,
          isTrue,
        );
        expect(
          tester.widget<TextField>(fields.at(index)).controller!.text,
          original,
        );
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(fields.at(index)).obscureText, isTrue);
      }
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(model.cloudSync.settings!.username, 'test-user');
      expect(model.cloudSync.message, '同步设置已保存');
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('同步设置已保存'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('同步设置已保存'), findsNothing);
      expect(tester.takeException(), isNull);
      if (width < 700) {
        await tester.tap(find.byKey(const ValueKey('settings-category-back')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-button')));
      await tester.pumpAndSettle();
      if (width < 700) {
        await tester.tap(find.byKey(const ValueKey('settings-category-1')));
        await tester.pumpAndSettle();
      }
      expect(
        tester.widget<TextField>(fields.at(0)).controller!.text,
        'https://dav.example.com/HarborSSH/',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _GistModel extends WorkspaceModel {
  _GistModel() : super(memoryRepository());
  @override
  Future<void> syncNow({SyncConflictChoice? choice}) async {
    await cloudSync.saveSettings(
      cloudSync.settings!.withGistId('0123456789abcdef'),
    );
  }
}

class _AutomaticModel extends WorkspaceModel {
  _AutomaticModel() : super(memoryRepository());
  int syncCalls = 0;
  @override
  Future<void> syncNow({SyncConflictChoice? choice}) async {
    syncCalls++;
  }
}
