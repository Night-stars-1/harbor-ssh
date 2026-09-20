import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/settings_window_bridge.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  test('主题偏好持久化，重新加载保留模式和颜色', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveAppearance(
      const AppearancePreferences(
        mode: AppThemeMode.dark,
        color: AppThemeColor.blue,
      ),
    );
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    expect(restored.appearance.value.mode, AppThemeMode.dark);
    expect(restored.appearance.value.color, AppThemeColor.blue);
    model.dispose();
    restored.dispose();
  });

  testWidgets('设置窗口修改主题同步到主窗口，主窗口设置可回读', (tester) async {
    final model = WorkspaceModel(memoryRepository());
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
    await remote.saveAppearance(
      const AppearancePreferences(
        mode: AppThemeMode.dark,
        color: AppThemeColor.pink,
      ),
    );
    expect(model.appearance.value.mode, AppThemeMode.dark);
    expect(model.appearance.value.color, AppThemeColor.pink);
    expect(remote.appearance.mode, AppThemeMode.dark);
    await model.saveAppearance(
      const AppearancePreferences(
        mode: AppThemeMode.system,
        color: AppThemeColor.green,
      ),
    );
    final state = await host.handle(const MethodCall('state')) as Map;
    expect(state['appearance'], {'mode': 'system', 'color': 'green'});
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('外观设置适配 $width，实时变色、系统主题与手动切换', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
      );
      final model = WorkspaceModel(memoryRepository());
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      ThemeData currentTheme() =>
          Theme.of(tester.element(find.byType(Workspace)));
      expect(currentTheme().brightness, Brightness.light);
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      await tester.pumpAndSettle();
      expect(currentTheme().brightness, Brightness.dark);
      await tester.tap(find.byKey(const ValueKey('settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-category-2')));
      await tester.pumpAndSettle();
      for (final mode in [
        AppThemeMode.light,
        AppThemeMode.dark,
        AppThemeMode.system,
      ]) {
        final option = find.byKey(ValueKey('theme-mode-${mode.name}'));
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(model.appearance.value.mode, mode);
        expect(
          currentTheme().brightness,
          mode == AppThemeMode.light ? Brightness.light : Brightness.dark,
        );
      }
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      await tester.pumpAndSettle();
      expect(currentTheme().brightness, Brightness.light);
      final blue = find.byKey(const ValueKey('theme-color-blue'));
      await tester.ensureVisible(blue);
      await tester.tap(blue);
      await tester.pumpAndSettle();
      expect(model.appearance.value.color, AppThemeColor.blue);
      expect(
        currentTheme().colorScheme.primary,
        harborColorScheme(color: AppThemeColor.blue).primary,
      );
      await tester.tap(find.byTooltip('切换浅色/深色主题'));
      await tester.pumpAndSettle();
      expect(model.appearance.value.mode, AppThemeMode.dark);
      expect(model.appearance.value.color, AppThemeColor.blue);
      expect(currentTheme().brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
