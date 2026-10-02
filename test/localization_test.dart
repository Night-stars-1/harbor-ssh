import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/ai_window_app.dart';
import 'package:harbor_ssh/ui/ai_window_bridge.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/settings_window_app.dart';
import 'package:harbor_ssh/ui/settings_window_bridge.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => switch (call.method) {
        'isFocused' => true,
        'isMaximized' || 'isFullScreen' => false,
        _ => null,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      aiWindowChannel,
      (_) async => <String, Object?>{'sessionId': null},
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      aiWindowChannel,
      null,
    );
  });
  for (final systemLocale in [
    const Locale('en', 'US'),
    const Locale('zh', 'TW'),
  ]) {
    testWidgets('输入框右键菜单与中文界面一致，系统语言为 $systemLocale', (tester) async {
      tester.platformDispatcher.localesTestValue = [systemLocale];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => switch (call.method) {
          'Clipboard.getData' => {'text': 'clipboard'},
          'Clipboard.hasStrings' => {'value': true},
          _ => null,
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        HarborApp(model: WorkspaceModel(memoryRepository())),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'example');
      await tester.pumpAndSettle();
      final editable = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      tester.widget<EditableText>(editable).controller.selection =
          const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.pump();
      await tester.tapAt(
        tester.getTopLeft(editable) + const Offset(20, 10),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('粘贴'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Paste'), findsNothing);
      final context = tester.element(editable);
      expect(Localizations.localeOf(context), const Locale('zh', 'CN'));
      expect(CupertinoLocalizations.of(context).copyButtonLabel, '复制');
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('独立设置和 AI 窗口也使用中文组件本地化', (tester) async {
    tester.platformDispatcher.localesTestValue = [const Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      settingsWindowChannel,
      (_) async => <String, Object?>{},
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        settingsWindowChannel,
        null,
      ),
    );
    for (final app in [const SettingsWindowApp(), const AiWindowApp()]) {
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);
      expect(Localizations.localeOf(context), const Locale('zh', 'CN'));
      final material = MaterialLocalizations.of(context);
      expect(material.cutButtonLabel, '剪切');
      expect(material.copyButtonLabel, '复制');
      expect(material.pasteButtonLabel, '粘贴');
      expect(material.selectAllButtonLabel, '全选');
      expect(CupertinoLocalizations.of(context).pasteButtonLabel, '粘贴');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
