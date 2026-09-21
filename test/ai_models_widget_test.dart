import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_settings.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('获取并选择模型，失败保留手填内容 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkspaceModel(memoryRepository());
      await model.initialize();
      final controller = LocalSyncSettingsController(model);
      var fail = false;
      final configs = <AiSettings>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: AiSettingsPage(
              controller: controller,
              modelClientFactory: () => _ModelsClient((settings) async {
                configs.add(settings);
                if (fail) throw const AiFailure('服务不支持获取模型，请手动填写模型名称');
                return ['model-a', 'model-b'];
              }),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-url')),
        'https://example.com/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-setting-key')),
        'test-key',
      );
      final button = find.byTooltip('获取').hitTestable().first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(configs.single.model, isEmpty);
      expect(configs.single.apiKey, 'test-key');
      await tester.tap(
        find.widgetWithText(MenuItemButton, 'model-b').hitTestable(),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('ai-setting-model'));
      expect(
        tester.widget<DropdownMenu<String>>(field).controller!.text,
        'model-b',
      );
      final save = find.widgetWithText(FilledButton, '保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(model.aiSettings.model, 'model-b');
      await tester.enterText(field, 'custom-model');
      fail = true;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownMenu<String>>(field).controller!.text,
        'custom-model',
      );
      expect(find.textContaining('服务不支持获取模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      model.dispose();
    });
  }

  testWidgets('地址更改取消旧请求，迟到列表不会进入新配置', (tester) async {
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    final pending = Completer<List<String>>();
    final client = _ModelsClient((_) => pending.future);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AiSettingsPage(
            controller: controller,
            modelClientFactory: () => client,
          ),
        ),
      ),
    );
    final button = find.byTooltip('获取').hitTestable().first;
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('ai-setting-url')));
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-url')),
      'https://new.example/v1',
    );
    pending.complete(['old-model']);
    await tester.pumpAndSettle();
    expect(client.cancelled, isTrue);
    expect(
      tester
          .widget<DropdownMenu<String>>(
            find.byKey(const ValueKey('ai-setting-model')),
          )
          .dropdownMenuEntries,
      isEmpty,
    );
    expect(find.textContaining('已获取'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

  testWidgets('获取模型使用默认模型所选服务商的凭证', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await model.initialize();
    final controller = LocalSyncSettingsController(model);
    final configs = <AiSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: AiSettingsPage(
            controller: controller,
            modelClientFactory: () => _ModelsClient((settings) async {
              configs.add(settings);
              return ['other-model'];
            }),
          ),
        ),
      ),
    );
    Future<void> select(String field, String option) async {
      final menu = find.byKey(ValueKey('ai-setting-$field'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, option).hitTestable(),
      );
      await tester.pumpAndSettle();
    }

    await select('provider', 'Anthropic');
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-key')),
      'anthropic-key',
    );
    await select('provider', 'OpenAI');
    await tester.enterText(
      find.byKey(const ValueKey('ai-setting-key')),
      'openai-key',
    );
    await select('model-provider', 'Anthropic');
    await tester.ensureVisible(find.byTooltip('获取').hitTestable().first);
    await tester.tap(find.byTooltip('获取').hitTestable().first);
    await tester.pumpAndSettle();
    expect(configs, isNotEmpty);
    expect(configs.last.baseUrl, 'https://api.anthropic.com/v1');
    expect(configs.last.apiKey, 'anthropic-key');
    expect(configs.last.protocol, AiProtocol.anthropic);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    model.dispose();
  });

}

class _ModelsClient extends TerminalAiClient {
  _ModelsClient(this.fetch);
  final Future<List<String>> Function(AiSettings) fetch;
  bool cancelled = false;
  @override
  Future<List<String>> listModels(AiSettings settings) => fetch(settings);
  @override
  void cancel() {
    cancelled = true;
  }
}
