import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/sync_storage.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/settings_window_bridge.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:harbor_ssh/ui/window_frame.dart';

import 'support.dart';

void mockDesktopWindow(WidgetTester tester) {
  const channel = MethodChannel('window_manager');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => switch (call.method) {
      'isMaximized' || 'isFullScreen' || 'isMinimized' => false,
      'isFocused' => true,
      _ => null,
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}

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

  test('默认终端字号独立保存，非法值回退且不进入云同步', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    await model.saveAppearance(
      const AppearancePreferences(terminalFontSize: 18),
    );
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    expect(restored.appearance.value.terminalFontSize, 18);
    expect(
      AppearancePreferences.fromJson({'terminalFontSize': 4}).terminalFontSize,
      10,
    );
    expect(
      AppearancePreferences.fromJson({'terminalFontSize': '30'})
          .terminalFontSize,
      24,
    );
    expect(AppearancePreferences.fromJson({}).terminalFontSize, 14);
    final snapshot = await SyncStorage(repository).capture();
    expect(snapshot.encode(), isNot(contains('terminalFontSize')));
    model.dispose();
    restored.dispose();
  });

  test('终端换行默认开启并本地保存，只有显式 false 才关闭且不进云同步', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    expect(model.appearance.value.terminalWrap, isTrue);
    expect(AppearancePreferences.fromJson({}).terminalWrap, isTrue);
    expect(
      AppearancePreferences.fromJson({'terminalWrap': null}).terminalWrap,
      isTrue,
    );
    expect(
      AppearancePreferences.fromJson({'terminalWrap': 'false'}).terminalWrap,
      isTrue,
    );
    expect(
      AppearancePreferences.fromJson({'terminalWrap': false}).terminalWrap,
      isFalse,
    );
    await model.saveAppearance(
      const AppearancePreferences(terminalWrap: false),
    );
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    expect(restored.appearance.value.terminalWrap, isFalse);
    expect(restored.appearance.value.mode, AppThemeMode.system);
    expect(restored.appearance.value.terminalFontSize, 14);
    expect(
      const AppearancePreferences(terminalWrap: false).toJson()['terminalWrap'],
      isFalse,
    );
    final snapshot = await SyncStorage(repository).capture();
    expect(snapshot.encode(), isNot(contains('terminalWrap')));
    model.dispose();
    restored.dispose();
  });

  test('状态刷新间隔默认五秒并本地保存，非法值回退且不进云同步', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    expect(model.appearance.value.statusRefreshSeconds, 5);
    expect(AppearancePreferences.fromJson({}).statusRefreshSeconds, 5);
    expect(
      AppearancePreferences.fromJson({'statusRefreshSeconds': 10})
          .statusRefreshSeconds,
      10,
    );
    expect(
      AppearancePreferences.fromJson({'statusRefreshSeconds': 3})
          .statusRefreshSeconds,
      5,
    );
    await model.saveAppearance(
      const AppearancePreferences(statusRefreshSeconds: 30),
    );
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    expect(restored.appearance.value.statusRefreshSeconds, 30);
    final snapshot = await SyncStorage(repository).capture();
    expect(snapshot.encode(), isNot(contains('statusRefreshSeconds')));
    model.dispose();
    restored.dispose();
  });

  test('亚克力背景默认关闭并本地保存，只有显式 true 才开启且不进云同步', () async {
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await model.initialize();
    expect(model.appearance.value.windowAcrylic, isFalse);
    expect(
      AppearancePreferences.fromJson({'windowAcrylic': 'true'}).windowAcrylic,
      isFalse,
    );
    await model.saveAppearance(
      const AppearancePreferences(windowAcrylic: true),
    );
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    expect(restored.appearance.value.windowAcrylic, isTrue);
    final snapshot = await SyncStorage(repository).capture();
    expect(snapshot.encode(), isNot(contains('windowAcrylic')));
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
    expect(state['appearance'], {
      'mode': 'system',
      'color': 'green',
      'terminalFontSize': 14,
      'terminalWrap': true,
      'statusRefreshSeconds': 5,
      'titleBarNavigation': false,
      'titleBarSessions': false,
      'windowAcrylic': false,
      'frostedSurfaces': false,
    });
    await remote.saveAppearance(
      const AppearancePreferences(
        mode: AppThemeMode.system,
        color: AppThemeColor.green,
        terminalWrap: false,
      ),
    );
    expect(model.appearance.value.terminalWrap, isFalse);
    expect(remote.appearance.terminalWrap, isFalse);
    final closed = await host.handle(const MethodCall('state')) as Map;
    expect((closed['appearance'] as Map)['terminalWrap'], isFalse);
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

  for (final acrylicEnabled in [false, true]) {
    testWidgets('外观设置可修改自动换行、状态刷新和 KDE 原生模糊，模糊 $acrylicEnabled', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockDesktopWindow(tester);
      final supported = windowAcrylicSupported;
      windowAcrylicSupported = true;
      addTearDown(() => windowAcrylicSupported = supported);
      final model = WorkspaceModel(memoryRepository());
      await model.saveAppearance(
        AppearancePreferences(windowAcrylic: acrylicEnabled),
      );
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-category-2')));
      await tester.pumpAndSettle();
      final acrylic = find.byKey(const ValueKey('window-acrylic'));
      await tester.ensureVisible(acrylic);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(acrylic).value, acrylicEnabled);
      await tester.tap(acrylic);
      await tester.pumpAndSettle();
      expect(model.appearance.value.windowAcrylic, !acrylicEnabled);
      expect(tester.widget<Switch>(acrylic).value, !acrylicEnabled);
      ThemeData currentTheme() =>
          Theme.of(tester.element(find.byType(Workspace)));
      final frosted = find.byKey(const ValueKey('frosted-surfaces'));
      await tester.ensureVisible(frosted);
      for (final enabled in [true, false]) {
        await tester.tap(frosted);
        await tester.pumpAndSettle();
        expect(model.appearance.value.frostedSurfaces, enabled);
        expect(currentTheme().windowBackdrop.frosted, enabled);
        expect(currentTheme().windowBackdrop.acrylic, !acrylicEnabled);
        expect(
          currentTheme().menuTheme.style?.backgroundColor?.resolve({})?.a,
          enabled ? lessThan(1) : 1,
        );
        expect(
          currentTheme().dialogTheme.backgroundColor?.a,
          enabled ? lessThan(1) : 1,
        );
        if (!acrylicEnabled) {
          expect(
            currentTheme().bottomSheetTheme.modalBackgroundColor?.a,
            enabled ? lessThan(1) : 1,
          );
        }
      }
      final restored = WorkspaceModel(model.repository);
      await restored.initialize();
      expect(restored.appearance.value.windowAcrylic, !acrylicEnabled);
      expect(restored.appearance.value.frostedSurfaces, isFalse);
      restored.dispose();
      final wrap = find.byKey(const ValueKey('terminal-wrap'));
      await tester.ensureVisible(wrap);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(wrap).value, isTrue);
      await tester.tap(wrap);
      await tester.pumpAndSettle();
      expect(model.appearance.value.terminalWrap, isFalse);
      expect(tester.widget<Switch>(wrap).value, isFalse);
      final refresh = find.byKey(const ValueKey('status-refresh-interval'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 秒').last);
      await tester.pumpAndSettle();
      expect(model.appearance.value.statusRefreshSeconds, 10);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Linux 原生模糊不可用时隐藏开关并保持窗口不透明，浮层毛玻璃仍可单独开启', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    mockDesktopWindow(tester);
    final supported = windowAcrylicSupported;
    windowAcrylicSupported = false;
    addTearDown(() => windowAcrylicSupported = supported);
    final model = WorkspaceModel(memoryRepository());
    await model.saveAppearance(
      const AppearancePreferences(windowAcrylic: true),
    );
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    ThemeData currentTheme() =>
        Theme.of(tester.element(find.byType(Workspace)));
    expect(currentTheme().windowBackdrop.acrylic, isFalse);
    expect(currentTheme().windowBackdrop.frosted, isFalse);
    expect(currentTheme().menuTheme.style?.backgroundColor?.resolve({})?.a, 1);
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-category-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('window-acrylic')), findsNothing);
    final frosted = find.byKey(const ValueKey('frosted-surfaces'));
    await tester.ensureVisible(frosted);
    await tester.tap(frosted);
    await tester.pumpAndSettle();
    expect(model.appearance.value.frostedSurfaces, isTrue);
    expect(currentTheme().windowBackdrop.acrylic, isFalse);
    expect(currentTheme().windowBackdrop.frosted, isTrue);
    expect(
      currentTheme().menuTheme.style?.backgroundColor?.resolve({})?.a,
      lessThan(1),
    );
    expect(currentTheme().scaffoldBackgroundColor.a, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
