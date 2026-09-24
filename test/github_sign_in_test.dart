import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/github_device_auth.dart';
import 'package:harbor_ssh/data/sync_config.dart';
import 'package:harbor_ssh/ui/github_sign_in.dart';
import 'package:harbor_ssh/ui/settings_widgets.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  for (final (width, scale) in [(320.0, 1.0), (1280.0, 1.0), (320.0, 2.0)]) {
    testWidgets('网页登录 $width × $scale：先自动复制再打开网页，保存账号并可退出', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      final controller = LocalSyncSettingsController(model);
      addTearDown(model.dispose);
      addTearDown(controller.dispose);
      final auth = _FakeAuth();
      final opened = <Uri>[];
      final busy = <bool>[];
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
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SettingsList(
              children: [
                SettingsGroup(
                  title: 'GitHub Gist',
                  children: [
                    GitHubSignIn(
                      controller: controller,
                      enabled: true,
                      onBusyChanged: busy.add,
                      authFactory: () => auth,
                      openBrowser: (uri) async {
                        expect(copies, ['ABCD-EFGH']);
                        opened.add(uri);
                        return true;
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('网页登录'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://github.com/login/device');
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(find.text('在 GitHub 完成登录'), findsOneWidget);
      expect(find.text('验证码已复制，在网页中粘贴并授权'), findsOneWidget);
      expect(copies, ['ABCD-EFGH']);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('github-copy-code')));
      await tester.pumpAndSettle();
      expect(copies, ['ABCD-EFGH', 'ABCD-EFGH']);
      expect(tester.takeException(), isNull);
      auth.result.complete(
        GitHubAccount(
          token: 'oauth-token',
          login: 'harbor-user',
          refreshToken: 'rotating-refresh',
          expiresAt: DateTime.utc(2026, 9, 25, 8),
          refreshExpiresAt: DateTime.utc(2027, 3, 25),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('@harbor-user'), findsOneWidget);
      expect(find.text('ABCD-EFGH'), findsNothing);
      expect(model.cloudSync.settings!.token, 'oauth-token');
      expect(model.cloudSync.settings!.refreshToken, 'rotating-refresh');
      expect(model.cloudSync.settings!.expiresAt, DateTime.utc(2026, 9, 25, 8));
      expect(find.text('当前登录无法自动续期，请重新登录一次'), findsNothing);
      expect(busy, [true, false]);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('未登录'), findsOneWidget);
      expect(model.cloudSync.settings!.token, isEmpty);
      expect(model.cloudSync.settings!.refreshToken, isEmpty);
      expect(model.cloudSync.settings!.expiresAt, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('自动复制失败仍打开授权页，并可重新复制', (tester) async {
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    addTearDown(model.dispose);
    addTearDown(controller.dispose);
    final auth = _FakeAuth();
    var failCopy = true, opened = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData' && failCopy) {
        throw PlatformException(code: 'clipboard-unavailable');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: GitHubSignIn(
            controller: controller,
            enabled: true,
            onBusyChanged: (_) {},
            authFactory: () => auth,
            openBrowser: (_) async {
              opened++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('网页登录'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('无法复制，请手动输入验证码'), findsOneWidget);
    expect(find.text('验证码已复制，在网页中粘贴并授权'), findsNothing);
    failCopy = false;
    await tester.tap(find.byKey(const ValueKey('github-copy-code')));
    await tester.pumpAndSettle();
    expect(find.text('验证码已复制，在网页中粘贴并授权'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.cloudSync.settings, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('等待剪贴板时取消，不再打开网页或保存登录', (tester) async {
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    addTearDown(model.dispose);
    addTearDown(controller.dispose);
    final auth = _FakeAuth();
    final copied = Completer<void>();
    var opened = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') await copied.future;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: GitHubSignIn(
            controller: controller,
            enabled: true,
            onBusyChanged: (_) {},
            authFactory: () => auth,
            openBrowser: (_) async {
              opened++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('网页登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    copied.complete();
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(model.cloudSync.settings, isNull);
    expect(find.text('验证码已复制'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('浏览器打开失败仍可手动授权；取消、拒绝和离开页面保留原账号', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    await model.saveGitHubAccount('existing-token', 'existing-user');
    final controller = LocalSyncSettingsController(model);
    addTearDown(model.dispose);
    addTearDown(controller.dispose);
    var auth = _FakeAuth();
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: GitHubSignIn(
            controller: controller,
            enabled: true,
            onBusyChanged: (_) {},
            authFactory: () => auth,
            openBrowser: (_) async => false,
          ),
        ),
      ),
    );
    expect(find.text('当前登录无法自动续期，请重新登录一次'), findsOneWidget);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(find.text('无法打开浏览器，请访问 github.com/login/device'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.cloudSync.settings!.token, 'existing-token');
    expect(find.text('ABCD-EFGH'), findsNothing);
    auth = _FakeAuth();
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    auth.result.completeError(const SyncFailure('已拒绝 GitHub 授权，可重新登录'));
    await tester.pumpAndSettle();
    expect(find.text('已拒绝 GitHub 授权，可重新登录'), findsOneWidget);
    expect(model.cloudSync.settings!.token, 'existing-token');
    auth = _FakeAuth();
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(auth.cancelled, isTrue);
    expect(model.cloudSync.settings!.token, 'existing-token');
    expect(tester.takeException(), isNull);
  });
}

class _FakeAuth extends GitHubDeviceAuth {
  _FakeAuth() {
    result.future.ignore();
  }
  final result = Completer<GitHubAccount>();
  bool cancelled = false;
  @override
  Future<GitHubDeviceCode> start() async => GitHubDeviceCode(
    deviceCode: 'private-code',
    userCode: 'ABCD-EFGH',
    expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    interval: const Duration(seconds: 5),
  );
  @override
  Future<GitHubAccount> waitForAuthorization(GitHubDeviceCode code) =>
      result.future;
  @override
  void cancel() {
    cancelled = true;
    if (!result.isCompleted) result.completeError(const GitHubAuthCancelled());
  }
}
