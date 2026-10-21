import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/window_frame.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  testWidgets('macOS 启动配置完成后显示被原生层隐藏的窗口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('window_manager');
    final ready = Completer<void>();
    var visible = false;
    var focused = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'waitUntilReadyToShow':
          await ready.future;
          return null;
        case 'show':
          visible = true;
          return null;
        case 'focus':
          focused = visible;
          return null;
        case 'isVisible':
          return visible;
        case 'isFocused':
          return focused;
        case 'isFullScreen':
        case 'isMaximized':
        case 'isMinimized':
          return false;
        default:
          return null;
      }
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final initialization = initializeWindowsWindow();
    await tester.pump();
    expect(await windowManager.isVisible(), isFalse);
    ready.complete();
    await initialization;
    expect(await windowManager.isVisible(), isTrue);
    expect(await windowManager.isFocused(), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in const [TargetPlatform.windows, TargetPlatform.linux]) {
    final name = platform == TargetPlatform.windows ? 'Windows' : 'Linux';
    final isLinux = platform == TargetPlatform.linux;
    testWidgets('$name 标题栏调用窗口操作、同步状态并保留页面', (tester) async {
      final semantics = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('window_manager');
      final calls = <MethodCall>[];
      var maximized = false;
      var fullScreen = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'isMaximized' => maximized,
          'isFullScreen' => fullScreen,
          'isFocused' => true,
          'isMinimized' => false,
          _ => null,
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await initializeWindowsWindow();
      expect(
        calls.firstWhere((c) => c.method == 'setTitleBarStyle').arguments,
        {'titleBarStyle': 'hidden', 'windowButtonVisibility': false},
      );
      int resizes() =>
          calls.where((call) => call.method == 'startResizing').length;
      int drags() =>
          calls.where((call) => call.method == 'startDragging').length;
      Future<void> dragEdge(Offset start, Offset offset) async {
        await tester.dragFrom(start, offset);
        await tester.pumpAndSettle();
      }

      final text = TextEditingController(text: 'page state');
      addTearDown(text.dispose);
      Widget app(Brightness brightness) => MaterialApp(
        theme: harborTheme(brightness: brightness),
        builder: (context, child) => WindowsWindowFrame(child: child!),
        home: Scaffold(body: TextField(controller: text)),
      );
      await tester.pumpWidget(app(Brightness.light));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'edited $name state');
      expect(find.text('Harbor SSH'), findsOneWidget);

      // The custom bar spans the whole window and the page starts right below
      // it, so Linux adds no visible border or padding around the shared frame.
      final windowRect = tester.getRect(find.byType(WindowsWindowFrame));
      expect(find.byKey(const ValueKey('windows-title-bar')), findsOneWidget);
      final barRect = tester.getRect(
        find.byKey(const ValueKey('windows-title-bar')),
      );
      expect(barRect.width, windowRect.width);
      expect(barRect.top, windowRect.top);
      expect(tester.getTopLeft(find.byType(TextField)).dy, barRect.bottom);
      final dragRect = tester.getRect(
        find.byKey(const ValueKey('window-drag-area')),
      );
      expect(dragRect.top, greaterThanOrEqualTo(barRect.top));
      expect(dragRect.bottom, lessThanOrEqualTo(barRect.bottom));
      final minimizeRect = tester.getRect(
        find.byKey(const ValueKey('window-minimize')),
      );
      expect(minimizeRect.top, greaterThanOrEqualTo(barRect.top));
      expect(minimizeRect.bottom, lessThanOrEqualTo(barRect.bottom));

      await tester.tap(find.byKey(const ValueKey('window-minimize')));
      expect(calls.last.method, 'minimize');

      if (isLinux) {
        final before = resizes();
        await dragEdge(
          Offset(windowRect.left + 4, windowRect.top + 4),
          const Offset(30, 30),
        );
        expect(resizes(), before + 1);
        expect(
          calls.lastWhere((call) => call.method == 'startResizing').arguments,
          containsPair('resizeEdge', 'topLeft'),
        );
      }

      await tester.tap(find.byKey(const ValueKey('window-maximize')));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'maximize');
      maximized = true;
      for (final listener in windowManager.listeners) {
        listener.onWindowMaximize();
      }
      await tester.pump();
      expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
      expect(find.bySemanticsLabel('还原窗口'), findsOneWidget);

      if (isLinux) {
        // Maximized windows cannot be resized from their edges.
        final before = resizes();
        final dragsBefore = drags();
        await dragEdge(
          Offset(windowRect.left + 4, windowRect.center.dy),
          const Offset(40, 0),
        );
        expect(resizes(), before);
        expect(drags(), dragsBefore);
      }

      await tester.tap(find.byKey(const ValueKey('window-maximize')));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'unmaximize');
      maximized = false;
      for (final listener in windowManager.listeners) {
        listener.onWindowUnmaximize();
      }
      await tester.pump();
      expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
      expect(find.bySemanticsLabel('最大化'), findsOneWidget);

      if (isLinux) {
        // Restoring the window makes the resize edges available again.
        final before = resizes();
        await dragEdge(
          Offset(windowRect.right - 4, windowRect.center.dy),
          const Offset(-30, 0),
        );
        expect(resizes(), before + 1);
        expect(
          calls.lastWhere((call) => call.method == 'startResizing').arguments,
          containsPair('resizeEdge', 'right'),
        );
      }

      await tester.drag(
        find.byKey(const ValueKey('window-drag-area')),
        const Offset(80, 0),
      );
      await tester.pumpAndSettle();
      expect(calls.any((call) => call.method == 'startDragging'), isTrue);
      await tester.tap(find.byKey(const ValueKey('window-drag-area')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.byKey(const ValueKey('window-drag-area')));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'maximize');

      await tester.pumpWidget(app(Brightness.dark));
      await tester.pumpAndSettle();
      expect(calls.lastWhere((c) => c.method == 'setBrightness').arguments, {
        'brightness': 'dark',
      });
      expect(find.text('edited $name state'), findsOneWidget);

      fullScreen = true;
      for (final listener in windowManager.listeners) {
        listener.onWindowEnterFullScreen();
      }
      await tester.pump();
      expect(find.byKey(const ValueKey('windows-title-bar')), findsNothing);
      expect(find.text('edited $name state'), findsOneWidget);

      if (isLinux) {
        // Full screen also disables the resize edges.
        final before = resizes();
        await tester.dragFrom(
          Offset(windowRect.right - 4, windowRect.bottom - 4),
          const Offset(-30, -30),
        );
        await tester.pump();
        expect(resizes(), before);
      }

      fullScreen = false;
      for (final listener in windowManager.listeners) {
        listener.onWindowLeaveFullScreen();
      }
      await tester.pump();
      expect(find.byKey(const ValueKey('windows-title-bar')), findsOneWidget);
      expect(find.text('edited $name state'), findsOneWidget);

      if (isLinux) {
        final before = resizes();
        await dragEdge(
          Offset(windowRect.left + 4, windowRect.bottom - 4),
          const Offset(30, -30),
        );
        expect(resizes(), before + 1);
        expect(
          calls.lastWhere((call) => call.method == 'startResizing').arguments,
          containsPair('resizeEdge', 'bottomLeft'),
        );
      }

      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('window-minimize')), findsOneWidget);
      expect(find.byKey(const ValueKey('window-maximize')), findsOneWidget);
      expect(find.byKey(const ValueKey('window-close')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('window-close')));
      expect(calls.last.method, 'close');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(windowManager.listeners, isEmpty);
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await initializeWindowsWindow();
      expect(calls, isEmpty);
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('macOS 标题栏保留系统按钮并留出交通灯空位', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('window_manager');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'isFocused' => true,
        'isMaximized' || 'isFullScreen' || 'isMinimized' => false,
        _ => null,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await initializeWindowsWindow();
    expect(calls.firstWhere((c) => c.method == 'setTitleBarStyle').arguments, {
      'titleBarStyle': 'hidden',
      'windowButtonVisibility': true,
    });
    final text = TextEditingController(text: 'page state');
    addTearDown(text.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => WindowsWindowFrame(child: child!),
        home: Scaffold(body: TextField(controller: text)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'edited macOS state');
    expect(find.text('Harbor SSH'), findsOneWidget);
    expect(find.byKey(const ValueKey('window-minimize')), findsNothing);
    expect(find.byKey(const ValueKey('window-maximize')), findsNothing);
    expect(find.byKey(const ValueKey('window-close')), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('macos-traffic-light-inset')))
          .width,
      78,
    );
    await tester.drag(
      find.byKey(const ValueKey('window-drag-area')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'startDragging'), isTrue);
    for (final listener in windowManager.listeners) {
      listener.onWindowEnterFullScreen();
    }
    await tester.pump();
    expect(find.byKey(const ValueKey('windows-title-bar')), findsNothing);
    expect(find.text('edited macOS state'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(windowManager.listeners, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });
}
