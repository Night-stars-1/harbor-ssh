import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

class _AutomaticWorkspace extends WorkspaceModel {
  _AutomaticWorkspace() : super(memoryRepository());
  int syncCalls = 0;

  @override
  Future<void> syncNow({SyncConflictChoice? choice}) async {
    syncCalls++;
  }
}

const _automatic = WebDavSettings(
  url: 'https://dav.example.com/HarborSSH/',
  username: 'test',
  password: 'app-password',
  encryptionPassword: 'encryption-password',
  automatic: true,
);

// Follow the same intermediate states as the engine, rather than sending
// illegal direct transitions such as paused -> resumed to framework listeners.
void _resume(WidgetTester tester) {
  final binding = tester.binding;
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState != AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

void _hide(WidgetTester tester) {
  final binding = tester.binding;
  if (binding.lifecycleState == null ||
      binding.lifecycleState == AppLifecycleState.detached) {
    _resume(tester);
  }
  if (binding.lifecycleState == AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState != AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
}

void _pause(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) return;
  _hide(tester);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void main() {
  testWidgets('启动时已处于后台不会安排自动同步', (tester) async {
    _hide(tester);
    final model = _AutomaticWorkspace();
    await model.configureSync(_automatic);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 3));
    expect(model.syncCalls, 0);
    _resume(tester);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(model.syncCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform 生命周期暂停并恢复自动同步', (tester) async {
      _resume(tester);
      final model = _AutomaticWorkspace();
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      await model.configureSync(_automatic);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 2));
      expect(model.syncCalls, 1);

      _pause(tester);
      await tester.pump(const Duration(minutes: 3));
      expect(model.syncCalls, 1);
      _resume(tester);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(model.syncCalls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(model.syncCalls, 2);

      _pause(tester);
      _resume(tester);
      _pause(tester);
      await tester.pump(const Duration(minutes: 3));
      expect(model.syncCalls, 2);
      // Resume rendering before replacing the root; a paused scheduler does
      // not draw the frame which would dispose HarborApp and its model.
      _resume(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      _pause(tester);
      _resume(tester);
      await tester.pump(const Duration(minutes: 3));
      expect(model.syncCalls, 2);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('桌面失焦和隐藏不停止自动同步', (tester) async {
    _resume(tester);
    final model = _AutomaticWorkspace();
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    await model.configureSync(_automatic);
    _pause(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(model.syncCalls, 1);
    await tester.pump(const Duration(minutes: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(model.syncCalls, 2);
    _resume(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
}
