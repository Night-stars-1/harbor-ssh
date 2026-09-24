import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/settings_window_bridge.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  testWidgets('独立设置入口不切换主窗口，不打开对话框', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Workspace(
          model: model,
          onToggleTheme: () {},
          onOpenSettings: () async {
            opened++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('settings-button')));
      await tester.pumpAndSettle();
    }
    expect(opened, 2);
    expect(model.showingSettings, isFalse);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('所有连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets('独立窗口通过主服务保存与同步，冲突和错误可以往返', (tester) async {
    final model = _SyncModel();
    await model.initialize();
    final host = SettingsWindowHost(LocalSyncSettingsController(model));
    final remote = RemoteSyncSettingsController();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(settingsWindowChannel, host.handle);
    addTearDown(() {
      remote.dispose();
      host.dispose();
      model.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(settingsWindowChannel, null);
    });
    await remote.initialize();
    expect(remote.settings, isNull);
    const ai = AiSettings(
      baseUrl: 'https://ai.example.com/v1',
      apiKey: 'test-key',
      model: 'model',
      protocol: AiProtocol.anthropic,
      provider: 'anthropic',
    );
    await remote.saveAiSettings(ai);
    expect(model.aiSettings.toJson(), ai.toJson());
    expect(remote.aiSettings.toJson(), ai.toJson());
    const settings = WebDavSettings(
      url: 'https://dav.example.com/HarborSSH/',
      username: 'user',
      password: 'application-password',
      encryptionPassword: 'shared-password',
    );
    await remote.save(settings);
    expect(model.cloudSync.settings!.username, 'user');
    expect(remote.settings!.url, settings.url);
    expect(remote.message, '同步设置已保存');
    // Invalid credentials are sanitized and returned as a user-facing failure.
    await expectLater(
      remote.save(
        const WebDavSettings(
          url: 'http://example.com/',
          username: 'user',
          password: 'secret',
          encryptionPassword: 'shared-password',
        ),
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect(model.cloudSync.settings!.url, settings.url);
    await expectLater(
      remote.sync(),
      throwsA(isA<SyncConflict>().having((e) => e.names, 'names', ['服务器'])),
    );
    await remote.sync(choice: SyncConflictChoice.local);
    expect(model.choice, SyncConflictChoice.local);
    expect(model.calls, 2);
    final state = await host.handle(const MethodCall('state')) as Map;
    expect(state['busy'], isFalse);
    const gist = CloudSyncConfig(
      provider: SyncProvider.gist,
      gistId: '0123456789abcdef',
      token: 'github-test-token',
      encryptionPassword: 'shared-password',
    );
    await remote.save(gist);
    expect(model.cloudSync.settings!.provider, SyncProvider.gist);
    expect(remote.settings!.toJson(), gist.toJson());
    await remote.initialize();
    expect(remote.settings!.toJson(), gist.toJson());
    await remote.saveGitHubAccount(
      'oauth-test-token',
      'harbor-user',
      refreshToken: 'rotating-refresh',
      expiresAt: DateTime.utc(2026, 9, 25, 8),
      refreshExpiresAt: DateTime.utc(2027, 3, 25),
    );
    expect(model.cloudSync.settings!.token, 'oauth-test-token');
    expect(remote.settings!.githubLogin, 'harbor-user');
    expect(remote.settings!.refreshToken, 'rotating-refresh');
    expect(remote.settings!.expiresAt, DateTime.utc(2026, 9, 25, 8));
    expect(remote.settings!.refreshExpiresAt, DateTime.utc(2027, 3, 25));
    expect(remote.settings!.gistId, isEmpty);
    await remote.saveGitHubAccount('', '');
    expect(remote.settings!.token, isEmpty);
    expect(remote.settings!.githubLogin, isEmpty);
    expect(remote.settings!.refreshToken, isEmpty);
    expect(remote.settings!.expiresAt, isNull);
    expect(remote.settings!.automatic, isFalse);
  });
}

class _SyncModel extends WorkspaceModel {
  _SyncModel() : super(memoryRepository());
  int calls = 0;
  SyncConflictChoice? choice;
  @override
  Future<void> syncNow({SyncConflictChoice? choice}) async {
    calls++;
    if (choice == null) throw const SyncConflict(['服务器']);
    this.choice = choice;
  }
}
