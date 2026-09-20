import 'dart:async';

import 'package:flutter/material.dart';
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
  for (final width in [320.0, 1280.0]) {
    testWidgets('网页登录 $width：打开官方网页、显示验证码并保存账号，退出后清除凭据', (tester) async {
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
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
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
      expect(find.text('等待授权…'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      auth.result.complete(
        const GitHubAccount(token: 'oauth-token', login: 'harbor-user'),
      );
      await tester.pumpAndSettle();
      expect(find.text('@harbor-user'), findsOneWidget);
      expect(find.text('ABCD-EFGH'), findsNothing);
      expect(model.cloudSync.settings!.token, 'oauth-token');
      expect(busy, [true, false]);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('未登录'), findsOneWidget);
      expect(model.cloudSync.settings!.token, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('浏览器打开失败仍可手动授权；取消、拒绝和离开页面保留原账号', (tester) async {
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
