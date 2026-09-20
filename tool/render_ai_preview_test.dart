import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/settings_page.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:harbor_ssh/ui/theme.dart';

import '../test/support.dart';

void main() {
  testWidgets('AI 任务与设置深浅色预览', (tester) async {
    final font = ByteData.sublistView(
      File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
    );
    for (final name in ['Segoe UI', 'Roboto']) {
      await (FontLoader(name)..addFont(Future.value(font))).load();
    }
    final mono = ByteData.sublistView(
      File('C:/Windows/Fonts/consola.ttf').readAsBytesSync(),
    );
    await (FontLoader('monospace')..addFont(Future.value(mono))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final brightness in Brightness.values) {
      for (final width in [840.0, 390.0]) {
        tester.view.physicalSize = Size(width, 844);
        final model = WorkspaceModel(memoryRepository());
        await model.initialize();
        await model.saveAiSettings(
          const AiSettings(
            baseUrl: 'https://api.example.com/v1',
            apiKey: 'preview-key',
            model: 'model-name',
          ),
        );
        final navigation = SettingsNavigation()..value = 3;
        final task = AiTaskController(
          settings: () => model.aiSettings,
          executorFactory: _Executor.new,
          connected: () => true,
        );
        task.entries.addAll([
          AiTaskEntry('检查磁盘空间，找出占用最大的目录'),
          AiTaskEntry('df -h', command: true)
            ..reason = '查看文件系统使用情况'
            ..output = 'Filesystem   Size  Used  Avail  Use%\n/dev/vda1     40G   18G    20G   48%'
            ..exitCode = 0
            ..finished = true,
          AiTaskEntry('磁盘已使用 48%，当前空间充足。'),
        ]);
        task.status = '任务已结束';
        for (final settings in [true, false]) {
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: harborTheme(brightness: brightness),
                home: Scaffold(
                  body: settings
                      ? SettingsPage(
                          model: model,
                          navigation: navigation,
                          desktop: true,
                          standalone: true,
                        )
                      : TerminalAiPanel(task: task, hostName: '开发服务器'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File(
              'artifacts/ai-${settings ? 'settings' : 'task'}-${width.toInt()}-${brightness.name}.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.pumpWidget(const SizedBox.shrink());
        }
        task.dispose();
        navigation.dispose();
        model.dispose();
      }
    }
  });
}

class _Executor implements AiCommandExecutor {
  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async => const AiCommandResult('', 0);
  @override
  void cancel() {}
}
