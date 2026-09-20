import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/ai_image_input.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
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
    final sample = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xff16131a), BlendMode.src);
      final text = TextPainter(
        text: const TextSpan(
          text: 'dev@server:~\$ df -h\n\nFilesystem  Size  Used  Avail  Use%\n/dev/vda1    40G   18G    20G   48%',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 16,
            color: Color(0xff9ee8d2),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 448);
      text.paint(canvas, const Offset(16, 16));
      text.dispose();
      final picture = recorder.endRecording();
      final image = await picture.toImage(480, 160);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return AiImage.fromBytes('终端截图.png', data!.buffer.asUint8List());
    });
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
          clientFactory: _WaitingClient.new,
        );
        task.entries.addAll([
          AiTaskEntry('检查磁盘空间，找出占用最大的目录', images: [sample!], user: true),
          AiTaskEntry('df -h', command: true)
            ..reason = '查看文件系统使用情况'
            ..output = 'Filesystem   Size  Used  Avail  Use%\n/dev/vda1     40G   18G    20G   48%'
            ..exitCode = 0
            ..finished = true,
          AiTaskEntry('磁盘已使用 48%，当前空间充足。', model: 'claude-sonnet-4-5'),
        ]);
        task.status = '任务已结束';
        final session = SshConnection(id: 'preview', host: testHost)
          ..status = ConnectionStatus.connected;
        session.terminal.write(
          'Welcome to Ubuntu 24.04 LTS\r\n\r\n'
          'Last login: Mon Sep 21 09:30:12 2026\r\n'
          '\x1b[32mdev@server\x1b[0m:\x1b[34m~\x1b[0m\$ ',
        );
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
                      : TerminalAiLayout(
                          terminal: TerminalPane(
                            session: session,
                            onReconnect: () {},
                          ),
                          panel: TerminalAiPanel(
                            task: task,
                            hostName: '开发服务器',
                            onClose: () {},
                            imageInput: _Images(sample),
                          ),
                        ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (!settings) {
            final add = tester.widget<IconButton>(
              find.byKey(const ValueKey('ai-add-image')),
            );
            await tester.runAsync(
              () async => await (add.onPressed as dynamic)(),
            );
            await tester.enterText(
              find.byKey(const ValueKey('ai-task-input')),
              '帮我看看这张截图',
            );
            await tester.pumpAndSettle();
            await tester.runAsync(() async {
              for (final element in find.byType(Image).evaluate()) {
                await precacheImage((element.widget as Image).image, element);
              }
            });
            await tester.pumpAndSettle();
          }
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
          if (!settings) {
            await tester.tap(find.byKey(const ValueKey('ai-remove-image-0')));
            await tester.enterText(
              find.byKey(const ValueKey('ai-task-input')),
              '再看看哪些目录占用最多',
            );
            await tester.pump();
            await tester.tap(find.byKey(const ValueKey('ai-send')));
            await tester.pump();
            final list = tester.widget<ListView>(
              find.byKey(const ValueKey('ai-transcript')),
            );
            list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
            await tester.pump(const Duration(milliseconds: 650));
            await tester.runAsync(() async {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                'artifacts/ai-thinking-${width.toInt()}-${brightness.name}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
            task.stop();
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
        task.dispose();
        session.dispose();
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

class _Images implements AiImageInput {
  _Images(this.image);
  final AiImage image;
  @override
  Future<AiImage?> clipboard() async => image;
  @override
  Future<List<AiImageSource>> pick() async => [
    AiImageSource(image.name, () => Stream.value(image.bytes)),
  ];
}

class _WaitingClient extends TerminalAiClient {
  final _reply = Completer<AiReply>();
  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) => _reply.future;
  @override
  void cancel() {
    if (!_reply.isCompleted) {
      _reply.complete(const AiReply({'role': 'assistant', 'content': ''}, []));
    }
  }
}
