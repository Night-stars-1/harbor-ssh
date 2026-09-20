import 'dart:async';
import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/system_color_scope.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

Future<void> notifySystemColors(WidgetTester tester) async {
  final done = Completer<void>();
  tester.binding.channelBuffers.push(
    systemColorChannel.name,
    const StandardMethodCodec().encodeMethodCall(const MethodCall('changed')),
    (_) => done.complete(),
  );
  await done.future;
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('动态强调色实时更新，预设色不受系统变化影响', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var accent = 0xFF1565C0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DynamicColorPlugin.channel,
      (call) async => call.method == 'getAccentColor' ? accent : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        null,
      ),
    );
    final repository = memoryRepository();
    final model = WorkspaceModel(repository);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    ThemeData currentTheme() =>
        Theme.of(tester.element(find.byType(Workspace)));
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-category-2')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('dynamic-color-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(model.appearance.value.color, AppThemeColor.dynamic);
    expect(
      currentTheme().colorScheme.primary,
      ColorScheme.fromSeed(seedColor: Color(accent)).primary,
    );
    accent = 0xFFB53678;
    await notifySystemColors(tester);
    expect(
      currentTheme().colorScheme.primary,
      ColorScheme.fromSeed(seedColor: Color(accent)).primary,
    );
    await model.saveAppearance(
      model.appearance.value.copyWith(mode: AppThemeMode.dark),
    );
    await tester.pumpAndSettle();
    expect(
      currentTheme().colorScheme.primary,
      ColorScheme.fromSeed(
        seedColor: Color(accent),
        brightness: Brightness.dark,
      ).primary,
    );
    final restored = WorkspaceModel(repository);
    await restored.initialize();
    expect(restored.appearance.value.color, AppThemeColor.dynamic);
    restored.dispose();
    await model.saveAppearance(
      model.appearance.value.copyWith(color: AppThemeColor.blue),
    );
    await tester.pumpAndSettle();
    accent = 0xFF008577;
    await notifySystemColors(tester);
    expect(
      currentTheme().colorScheme.primary,
      harborColorScheme(
        color: AppThemeColor.blue,
        brightness: Brightness.dark,
      ).primary,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android 使用完整系统调色板，重新激活后刷新', (tester) async {
    var primary = 0xFF006A60;
    var calls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DynamicColorPlugin.channel,
      (call) async {
        calls++;
        if (call.method != 'getCorePalette') throw StateError('不应读取桌面强调色');
        return Int32List.fromList([
          for (final color in [
            primary,
            0xFF4A635F,
            0xFF426277,
            0xFF5E5E5E,
            0xFF59615F,
          ])
            ...List<int>.filled(13, color),
        ]);
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        null,
      ),
    );
    SystemColorPalette? palette;
    await tester.pumpWidget(
      SystemColorScope(
        child: Builder(
          builder: (context) {
            palette = SystemColorScope.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(palette!.light!.primary, Color(primary));
    expect(palette!.light!.secondary, const Color(0xFF4A635F));
    expect(palette!.dark!.tertiary, const Color(0xFF426277));
    expect(calls, 1);
    primary = 0xFF356ABC;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(palette!.light!.primary, Color(primary));
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('系统未提供颜色或读取失败时使用默认配色', (tester) async {
    var fail = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DynamicColorPlugin.channel,
      (call) async {
        if (fail) throw PlatformException(code: 'unavailable');
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        null,
      ),
    );
    ColorScheme? scheme;
    await tester.pumpWidget(
      SystemColorScope(
        child: Builder(
          builder: (context) {
            scheme = harborTheme(
              color: AppThemeColor.dynamic,
              dynamicScheme: SystemColorScope.of(context)?.light,
            ).colorScheme;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(scheme, harborColorScheme());
    fail = true;
    await notifySystemColors(tester);
    expect(scheme, harborColorScheme());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
