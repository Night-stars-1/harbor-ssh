import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/window_frame.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  testWidgets('Windows 标题栏调用窗口操作、同步状态并保留页面', (tester) async {
    final semantics = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('window_manager');
    final calls = <MethodCall>[];
    var maximized = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'isMaximized' => maximized,
        'isFocused' => true,
        'isFullScreen' || 'isMinimized' => false,
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
    expect(calls.first.method, 'ensureInitialized');
    expect(calls.firstWhere((c) => c.method == 'setTitleBarStyle').arguments, {
      'titleBarStyle': 'hidden',
      'windowButtonVisibility': false,
    });
    final text = TextEditingController(text: 'page state');
    addTearDown(text.dispose);
    Widget app(Brightness brightness) => MaterialApp(
      theme: harborTheme(brightness: brightness),
      builder: (context, child) => WindowsWindowFrame(child: child!),
      home: Scaffold(body: TextField(controller: text)),
    );
    await tester.pumpWidget(app(Brightness.light));
    await tester.pumpAndSettle();
    final fieldState = tester.state(find.byType(TextField));
    expect(find.text('Harbor SSH'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('windows-title-bar'))).height,
      40,
    );
    await tester.tap(find.byKey(const ValueKey('window-minimize')));
    expect(calls.last.method, 'minimize');
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
    await tester.tap(find.byKey(const ValueKey('window-maximize')));
    await tester.pumpAndSettle();
    expect(calls.last.method, 'unmaximize');
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
    expect(calls.last.method, 'unmaximize');
    await tester.pumpWidget(app(Brightness.dark));
    await tester.pumpAndSettle();
    expect(calls.lastWhere((c) => c.method == 'setBrightness').arguments, {
      'brightness': 'dark',
    });
    expect(tester.state(find.byType(TextField)), same(fieldState));
    for (final listener in windowManager.listeners) {
      listener.onWindowEnterFullScreen();
    }
    await tester.pump();
    expect(find.byKey(const ValueKey('windows-title-bar')), findsNothing);
    expect(tester.state(find.byType(TextField)), same(fieldState));
    for (final listener in windowManager.listeners) {
      listener.onWindowLeaveFullScreen();
    }
    await tester.pump();
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
