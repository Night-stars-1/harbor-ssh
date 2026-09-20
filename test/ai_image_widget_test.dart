import 'dart:async';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_image.dart';
import 'package:harbor_ssh/data/ai_image_input.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
const _config = AiSettings(baseUrl: 'https://ai.example/v1', model: 'vision');

void main() {
  for (final (width, height, scale) in [
    (390.0, 650.0, 1.0),
    (240.0, 240.0, 2.0),
  ]) {
    testWidgets('选择、预览、移除和仅发送图片 $width × $scale', (tester) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final input = _Input();
      final client = _Client();
      final task = _task(client);
      await _pump(tester, task, input, scale: scale);
      await _pick(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(client.messages, isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('ai-remove-image-0')),
      );
      await tester.tap(find.byKey(const ValueKey('ai-remove-image-0')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('ai-send')))
            .onPressed,
        isNull,
      );
      await _pick(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('ai-send')));
      await tester.tap(find.byKey(const ValueKey('ai-send')));
      await tester.pumpAndSettle();
      expect(
        (client.messages!.last['content'] as List).single['type'],
        'image_url',
      );
      expect(task.entries.first.images, hasLength(1));
      expect(find.byKey(const ValueKey('ai-remove-image-0')), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('ai-add-image')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('ai-send')));
      await tester.pumpAndSettle();
      expect(task.running, isFalse);
      client.reply.complete(
        const AiReply({'role': 'assistant', 'content': '迟到的响应'}, []),
      );
      await tester.pumpAndSettle();
      expect(task.entries.where((entry) => entry.text == '迟到的响应'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      task.dispose();
    });
  }

  testWidgets('Ctrl+V 添加截图，无图片时保留文字粘贴与选择替换', (tester) async {
    final input = _Input();
    input.image = await tester.runAsync(
      () => AiImage.fromBytes('clipboard', base64Decode(_png)),
    );
    final task = _task(_Client());
    await _pump(tester, task, input);
    final field = find.byKey(const ValueKey('ai-task-input'));
    await tester.tap(field);
    await tester.pump();
    Future<void> paste() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await paste();
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);
    input.image = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': '截图'};
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.enterText(field, '检查这里');
    final controller = tester.widget<TextField>(field).controller!;
    controller.selection = const TextSelection(baseOffset: 2, extentOffset: 4);
    await paste();
    expect(controller.text, '检查截图');
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('拖放只添加附件，超量时保留原图，验证失败时不清空草稿', (tester) async {
    final input = _Input();
    final client = _Client();
    final task = _task(
      client,
      config: const AiSettings(baseUrl: 'invalid', model: 'vision'),
    );
    await _pump(tester, task, input);
    Future<void> drop(int count) async {
      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      await tester.runAsync(() async {
        await (target.onDragDone as dynamic)(
          DropDoneDetails(
            files: [
              for (var i = 0; i < count; i++)
                DropItemFile.fromData(base64Decode(_png), name: '$i.png'),
            ],
            localPosition: Offset.zero,
            globalPosition: Offset.zero,
          ),
        );
      });
      await tester.pumpAndSettle();
    }

    await drop(1);
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);
    expect(client.messages, isNull);
    await drop(4);
    expect(find.text('每条消息最多添加 4 张图片'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-remove-image-1')), findsNothing);
    ScaffoldMessenger.of(tester.element(find.byType(TerminalAiPanel)))
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-task-input')), '分析截图');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的 API 地址'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-remove-image-0')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-task-input')))
          .controller!
          .text,
      '分析截图',
    );
    expect(client.messages, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });
}

Future<void> _pick(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('ai-add-image')));
  final button = tester.widget<IconButton>(
    find.byKey(const ValueKey('ai-add-image')),
  );
  await tester.runAsync(() async => await (button.onPressed as dynamic)());
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  AiTaskController task,
  AiImageInput input, {
  double scale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: harborTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: TerminalAiPanel(task: task, hostName: '测试服务器', imageInput: input),
    ),
  ),
);

AiTaskController _task(_Client client, {AiSettings config = _config}) =>
    AiTaskController(
      settings: () => config,
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client,
    );

class _Input implements AiImageInput {
  AiImage? image;
  @override
  Future<AiImage?> clipboard() async => image;
  @override
  Future<List<AiImageSource>> pick() async => [
    AiImageSource('screenshot.png', () => Stream.value(base64Decode(_png))),
  ];
}

class _Client extends TerminalAiClient {
  List<Map<String, dynamic>>? messages;
  final reply = Completer<AiReply>();
  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) {
    this.messages = List.of(messages);
    return reply.future;
  }
}

class _Executor implements AiCommandExecutor {
  @override
  void cancel() {}
  @override
  Future<AiCommandResult> execute(
    String command,
    void Function(String) onOutput,
  ) async => const AiCommandResult('', 0);
}
