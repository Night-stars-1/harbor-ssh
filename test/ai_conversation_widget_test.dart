import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';

void main() {
  for (final (width, scale) in [(390.0, 1.0), (240.0, 2.0)]) {
    testWidgets('工具默认折叠、标题退出码 tag、回复背景与模型 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final task = AiTaskController(
        settings: () => const AiSettings(
          baseUrl: 'https://example.com/v1',
          model: 'current-model',
        ),
        executorFactory: _Executor.new,
        connected: () => true,
      );
      final command = AiTaskEntry('uname -a', command: true)
        ..reason = '检查操作系统与当前用户'
        ..output = 'Linux server 6.8.0'
        ..exitCode = 0
        ..finished = true;
      task.entries.addAll([
        command,
        AiTaskEntry('服务器运行正常', model: 'original-model'),
      ]);
      Widget view() => MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: 'server'),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.text('uname -a'), findsNothing);
      expect(find.text('Linux server 6.8.0'), findsNothing);
      expect(find.text('退出码 0'), findsOneWidget);
      expect(find.text('original-model'), findsOneWidget);
      expect(find.text('current-model'), findsNothing);
      final replyMaterial = find
          .ancestor(of: find.text('服务器运行正常'), matching: find.byType(Material))
          .first;
      expect(
        tester.widget<Material>(replyMaterial).color,
        harborTheme().colorScheme.surfaceContainerHigh,
      );
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.text('uname -a'), findsOneWidget);
      expect(find.text('Linux server 6.8.0'), findsOneWidget);
      // Incoming output keeps the user's chosen expansion state.
      command.output = 'Linux server 6.8.0\nnew output';
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.textContaining('new output'), findsOneWidget);
      await tester.tap(find.text('退出码 0'));
      await tester.pumpAndSettle();
      expect(find.text('uname -a'), findsNothing);
      expect(find.textContaining('new output'), findsNothing);
      command.exitCode = 2;
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.text('退出码 2'), findsOneWidget);
      expect(find.textContaining('new output'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      task.dispose();
    });
  }
  for (final (width, scale, reducedMotion) in [
    (390.0, 1.0, false),
    (240.0, 2.0, true),
  ]) {
    testWidgets('连续追问、思考状态和新对话 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _Client();
      final task = AiTaskController(
        settings: () =>
            const AiSettings(baseUrl: 'https://example.com/v1', model: 'test'),
        executorFactory: _Executor.new,
        connected: () => true,
        clientFactory: () => client,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reducedMotion,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: TerminalAiPanel(task: task, hostName: '开发服务器'),
          ),
        ),
      );
      Future<void> send(String text) async {
        await tester.enterText(
          find.byKey(const ValueKey('ai-task-input')),
          text,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ai-send')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await send('检查目录');
      expect(find.text('AI 正在分析'), findsNothing);
      expect(find.text('思考中'), findsOneWidget);
      final fade = find.descendant(
        of: find.byKey(const ValueKey('ai-activity')),
        matching: find.byType(FadeTransition),
      );
      final opacity = tester.widget<FadeTransition>(fade).opacity.value;
      await tester.pump(const Duration(milliseconds: 350));
      final later = tester.widget<FadeTransition>(fade).opacity.value;
      expect(later, reducedMotion ? opacity : isNot(opacity));
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('ai-new-conversation')),
            )
            .onPressed,
        isNull,
      );
      client.reply.complete(
        const AiReply({'role': 'assistant', 'content': '当前目录是 /home/dev'}, []),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-activity')), findsNothing);
      expect(find.text('当前目录是 /home/dev'), findsOneWidget);

      client.reply = Completer<AiReply>();
      await send('这个目录在哪');
      expect(
        client.requests.last.map((m) => m['content']),
        containsAllInOrder(['检查目录', '当前目录是 /home/dev', '这个目录在哪']),
      );
      expect(task.entries.where((e) => e.user == true), hasLength(2));
      await tester.tap(find.byKey(const ValueKey('ai-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-activity')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ai-new-conversation')));
      await tester.pumpAndSettle();
      expect(task.entries, isEmpty);
      expect(find.text('当前目录是 /home/dev'), findsNothing);
      client.reply.complete(
        const AiReply({'role': 'assistant', 'content': '迟到的回复'}, []),
      );
      await tester.pumpAndSettle();
      expect(task.entries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      task.dispose();
    });
  }
}

class _Client extends TerminalAiClient {
  Completer<AiReply> reply = Completer<AiReply>();
  final requests = <List<Map<String, dynamic>>>[];
  @override
  Future<AiReply> complete(
    AiSettings settings,
    List<Map<String, dynamic>> messages,
  ) {
    requests.add(List.of(messages));
    return reply.future;
  }

  @override
  void cancel() {}
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
