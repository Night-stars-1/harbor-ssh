import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/network_identity.dart';
import 'package:harbor_ssh/ui/settings_page.dart';
import 'package:harbor_ssh/ui/settings_window_bridge.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

const _office = Host(
  id: 'office',
  name: '办公室服务器',
  address: '192.168.10.105',
  username: 'root',
);

void main() {
  for (final size in [const Size(360, 720), const Size(1100, 820)]) {
    testWidgets('新建身份后进入规则页添加替换，启用后重启仍生效且不进入云同步 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = memoryRepository();
      await repository.saveHosts([testHost, _office]);
      final model = WorkspaceModel(repository);
      await model.initialize();
      final controller = LocalSyncSettingsController(model);
      await tester.pumpWidget(
        MaterialApp(
          // Narrow runs as a phone, so the menu opens by long press.
          theme: harborTheme().copyWith(
            platform: size.width < 700
                ? TargetPlatform.android
                : TargetPlatform.windows,
          ),
          home: Scaffold(
            body: SettingsPage(
              controller: controller,
              desktop: true,
              standalone: true,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('settings-category-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        'frp 穿透',
      );
      await tester.tap(find.byKey(const ValueKey('identity-name-save')));
      await tester.pumpAndSettle();

      // Creating opens the identity's rule page instead of listing every host.
      final saved = model.networkIdentities.identities.single;
      expect(saved.name, 'frp 穿透');
      expect(find.text('还没有替换规则'), findsOneWidget);
      expect(find.text(_office.name), findsNothing);
      // The page header shows the identity, not the section.
      expect(find.text('frp 穿透'), findsOneWidget);
      // Wide layouts still list the section in the category rail.
      expect(find.text('身份'), size.width < 700 ? findsNothing : findsOneWidget);
      expect(find.text('当前身份'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('identity-rule-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-rule-save')));
      await tester.pump();
      expect(find.text('请选择连接'), findsOneWidget);
      final picker = find.descendant(
        of: find.byKey(const ValueKey('identity-rule-host')),
        matching: find.byType(TextField),
      );
      // Typed text alone is not a pick.
      await tester.enterText(picker, _office.name);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-rule-save')));
      await tester.pump();
      expect(find.text('请选择连接'), findsOneWidget);

      // Searching by address narrows the menu to the matching connection.
      await tester.tap(picker);
      await tester.enterText(picker, '192.168');
      await tester.pumpAndSettle();
      // DropdownMenu also lays out an offstage copy to measure its width.
      final entries = find.byType(MenuItemButton).hitTestable();
      expect(
        find.descendant(of: entries, matching: find.text(_office.name)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: entries, matching: find.text(testHost.name)),
        findsNothing,
      );
      await tester.tap(
        find.descendant(of: entries, matching: find.text(_office.name)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-rule-save')));
      await tester.pump();
      expect(find.text('地址和端口至少填写一项'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('identity-rule-address')),
        'frp.example.com',
      );
      final port = find.byKey(const ValueKey('identity-rule-port'));
      await tester.enterText(port, '70000');
      await tester.tap(find.byKey(const ValueKey('identity-rule-save')));
      await tester.pump();
      expect(find.text('1–65535'), findsOneWidget);
      await tester.enterText(port, '6022');
      await tester.tap(find.byKey(const ValueKey('identity-rule-save')));
      await tester.pumpAndSettle();

      expect(model.networkIdentities.identities.single.overrides.keys, [
        'office',
      ]);
      expect(
        find.byKey(const ValueKey('identity-rule-office')),
        findsOneWidget,
      );
      // Not active yet: the saved endpoint still applies.
      expect(model.networkIdentities.endpointOf(_office), (
        '192.168.10.105',
        22,
      ));

      await tester.tap(find.byKey(const ValueKey('settings-subpage-back')));
      await tester.pumpAndSettle();
      expect(find.text('1 条替换规则'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('identity-${saved.id}')));
      await tester.pumpAndSettle();
      expect(model.networkIdentities.endpointOf(_office), (
        'frp.example.com',
        6022,
      ));
      expect(model.networkIdentities.endpointOf(testHost), (
        testHost.address,
        testHost.port,
      ));

      final reloaded = WorkspaceModel(repository);
      await reloaded.initialize();
      expect(reloaded.networkIdentities.endpointOf(_office), (
        'frp.example.com',
        6022,
      ));
      reloaded.dispose();
      final snapshot = (await SyncStorage(repository).capture()).encode();
      expect(snapshot, isNot(contains('frp.example.com')));

      await tester.tap(find.byKey(ValueKey('identity-open-${saved.id}')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('identity-rule-delete-office')),
      );
      await tester.pumpAndSettle();
      expect(model.networkIdentities.endpointOf(_office), (
        '192.168.10.105',
        22,
      ));
      await tester.tap(find.byKey(const ValueKey('settings-subpage-back')));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('identity-open-${saved.id}'));
      Future<void> openMenu() async {
        if (size.width < 700) {
          await tester.longPress(row);
        } else {
          await tester.tap(row, buttons: kSecondaryMouseButton);
        }
        await tester.pumpAndSettle();
      }

      await openMenu();
      await tester.tap(find.byKey(const ValueKey('identity-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '家里 frp',
      );
      await tester.tap(find.byKey(const ValueKey('identity-name-save')));
      await tester.pumpAndSettle();
      expect(model.networkIdentities.identities.single.name, '家里 frp');
      expect(find.text('家里 frp'), findsOneWidget);
      // Renaming from the list must not open the identity.
      expect(find.byKey(const ValueKey('identity-add')), findsOneWidget);

      await openMenu();
      await tester.tap(find.byKey(const ValueKey('identity-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(model.networkIdentities.identities, isEmpty);
      expect(model.networkIdentities.activeId, isEmpty);
      expect(find.byKey(const ValueKey('identity-add')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      model.dispose();
    });
  }

  testWidgets('独立设置窗口切换身份后主窗口立即生效', (tester) async {
    await tester.runAsync(() async {
      final repository = memoryRepository();
      await repository.saveHosts([_office]);
      final model = WorkspaceModel(repository);
      await model.initialize();
      final host = SettingsWindowHost(LocalSyncSettingsController(model));
      final remote = RemoteSyncSettingsController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(settingsWindowChannel, host.handle);
      try {
        await remote.initialize();
        expect(remote.hosts.single.id, _office.id);
        final next = remote.networkIdentities.copyWith(
          identities: const [
            NetworkIdentity(
              id: 'proxy',
              name: '代理',
              overrides: {
                'office': EndpointOverride(address: '10.8.0.2', port: 2222),
              },
            ),
          ],
          activeId: 'proxy',
        );
        await remote.saveNetworkIdentities(next);
        expect(model.networkIdentities.endpointOf(_office), ('10.8.0.2', 2222));
        expect(remote.networkIdentities.activeId, 'proxy');
      } finally {
        remote.dispose();
        host.dispose();
        model.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(settingsWindowChannel, null);
      }
    });
  });
}
