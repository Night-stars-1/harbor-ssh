import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/app_update.dart';
import 'package:harbor_ssh/domain/app_update.dart';
import 'package:harbor_ssh/ui/about_settings.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

class _FakeUpdater extends AppUpdater {
  _FakeUpdater(
    this.release, {
    this.onDownload,
    super.platform = TargetPlatform.android,
  });
  final AppRelease release;
  final Future<File> Function(void Function(int, int)?)? onDownload;
  int checks = 0, installs = 0, quits = 0;
  bool cancelled = false;

  @override
  Future<String> currentVersion() async => '1.0.25';

  @override
  Future<AppRelease> latest() async {
    checks++;
    return release;
  }

  @override
  Future<File> download(
    ReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) => onDownload!(onProgress);

  @override
  Future<void> install(File package) async => installs++;

  @override
  void cancel() => cancelled = true;

  @override
  void quit() => quits++;
}

AppRelease _release(String version) => AppRelease(
  version: version,
  notes: '## 新功能\n\n- 应用内更新\n\n## 下载\n\n| 平台 | 安装包 |',
  page: Uri.https('github.com', '/x/releases'),
  publishedAt: DateTime.utc(2026, 10, 12),
  asset: ReleaseAsset(
    name: 'harbor-ssh-android-arm64-v8a.apk',
    url: Uri.https('github.com', '/x.apk'),
    size: 4 * 1024 * 1024,
  ),
);

void main() {
  testWidgets('关于页检查更新，下载显示进度并交给安装程序', (tester) async {
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    addTearDown(controller.dispose);
    addTearDown(model.dispose);
    final progress = Completer<File>();
    void Function(int, int)? report;
    final updater = _FakeUpdater(
      _release('1.1.0'),
      onDownload: (onProgress) {
        report = onProgress;
        return progress.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AboutSettings(
            controller: controller,
            updaterFactory: () => updater,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('版本 1.0.25'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('v1.1.0'), findsOneWidget);
    expect(find.text('应用内更新'), findsOneWidget);
    // The release page's download table is not repeated in the dialog.
    expect(find.text('安装包'), findsNothing);
    // Manual checks never offer to skip the release.
    expect(find.byKey(const ValueKey('update-skip')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('update-install')));
    await tester.pump();
    report!(1024 * 1024, 4 * 1024 * 1024);
    await tester.pump();
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('1.0 MB / 4.0 MB'), findsOneWidget);
    progress.complete(File('update.apk'));
    await tester.pumpAndSettle();
    expect(updater.installs, 1);
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('可更新到 v1.1.0'), findsOneWidget);
  });

  testWidgets('下载失败显示原因并可重试', (tester) async {
    var attempts = 0;
    final updater = _FakeUpdater(
      _release('1.1.0'),
      onDownload: (_) async {
        if (++attempts == 1) throw const UpdateFailure('安装包校验失败，已删除');
        return File('update.apk');
      },
    );
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    addTearDown(controller.dispose);
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AboutSettings(
            controller: controller,
            updaterFactory: () => updater,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-install')));
    await tester.pumpAndSettle();
    expect(find.text('安装包校验失败，已删除'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-install')));
    await tester.pumpAndSettle();
    expect(updater.installs, 1);
  });

  testWidgets('macOS 打开安装包后只提供「退出软件」，点击退出应用', (tester) async {
    final updater = _FakeUpdater(
      _release('1.1.0'),
      onDownload: (_) async => File('update.dmg'),
      platform: TargetPlatform.macOS,
    );
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    addTearDown(controller.dispose);
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AboutSettings(
            controller: controller,
            updaterFactory: () => updater,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('update-check')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-install')));
    await tester.pumpAndSettle();
    expect(updater.installs, 1);
    expect(find.textContaining('请先退出软件'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    final quit = find.byKey(const ValueKey('update-quit'));
    expect(
      find.descendant(of: quit, matching: find.text('退出软件')),
      findsOneWidget,
    );
    expect(updater.quits, 0);
    await tester.tap(quit);
    await tester.pump();
    expect(updater.quits, 1);
  });

  testWidgets('启动检查：跳过的版本不再提示，关闭自动检查后不请求', (tester) async {
    final repository = memoryRepository();
    Future<_FakeUpdater> launch(String version) async {
      final updater = _FakeUpdater(_release(version));
      final model = WorkspaceModel(repository);
      await tester.pumpWidget(
        HarborApp(
          key: UniqueKey(),
          model: model,
          updaterFactory: () => updater,
        ),
      );
      await tester.pumpAndSettle();
      return updater;
    }

    var updater = await launch('1.1.0');
    expect(updater.checks, 1);
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-skip')));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);

    updater = await launch('1.1.0');
    expect(updater.checks, 1);
    expect(find.text('发现新版本'), findsNothing);

    updater = await launch('1.2.0');
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-later')));
    await tester.pumpAndSettle();

    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveUpdatePreferences(
      model.updatePreferences.copyWith(autoCheck: false),
    );
    model.dispose();
    updater = await launch('1.2.0');
    expect(updater.checks, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('更新偏好缺失或损坏时默认自动检查', () {
    expect(UpdatePreferences.fromJson(const {}).autoCheck, isTrue);
    final saved = UpdatePreferences.fromJson(
      const UpdatePreferences(
        autoCheck: false,
        skippedVersion: '1.1.0',
      ).toJson(),
    );
    expect(saved.autoCheck, isFalse);
    expect(saved.skippedVersion, '1.1.0');
    expect(
      UpdatePreferences.fromJson(const {'skippedVersion': 3}).skippedVersion,
      '',
    );
  });
}
