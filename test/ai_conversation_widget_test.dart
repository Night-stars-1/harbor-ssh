import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ai_conversation_store.dart';
import 'package:harbor_ssh/data/terminal_ai.dart';
import 'package:harbor_ssh/ui/ai_task_controller.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

void main() {
  testWidgets('Enter 发送、Shift+Enter 换行，输入法候选与连按不误发', (tester) async {
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
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: 'server'),
        ),
      ),
    );
    final input = find.byKey(const ValueKey('ai-task-input'));
    await tester.tap(input);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(client.requests, isEmpty);
    await tester.enterText(input, '第一行第二行');
    final controller = tester.widget<TextField>(input).controller!;
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.text, '第一行\n第二行');
    expect(client.requests, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(client.requests, isEmpty);
    expect(controller.text, '中文');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(client.requests, hasLength(1));
    expect(client.requests.single.last['content'], '中文');
    expect(task.running, isTrue);
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': '收到'}, []),
    );
    await tester.pumpAndSettle();
    client.reply = Completer<AiReply>();
    await tester.enterText(input, '小键盘');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(client.requests, hasLength(2));
    expect(client.requests.last.last['content'], '小键盘');
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': '收到'}, []),
    );
    await tester.pumpAndSettle();
    client.reply = Completer<AiReply>();
    await tester.enterText(input, '手机发送');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(client.requests, hasLength(3));
    expect(client.requests.last.last['content'], '手机发送');
    task.stop();
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': ''}, []),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  for (final (width, scale) in [(390.0, 1.0), (240.0, 2.0)]) {
    testWidgets('工具默认折叠、回复背景与模型 $width', (tester) async {
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
      // Tool calls stay inside the assistant card and expose compact one-line
      // command/output previews before the disclosure is opened.
      expect(find.text('uname -a'), findsOneWidget);
      expect(find.text('Linux server 6.8.0'), findsOneWidget);
      expect(find.text('original-model'), findsOneWidget);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(
        find.text('current-model'),
        width < 360 ? findsNothing : findsOneWidget,
      );
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
      expect(find.text('uname -a'), findsOneWidget);
      expect(find.textContaining('new output'), findsOneWidget);
      command.exitCode = 2;
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.textContaining('new output'), findsOneWidget);
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

  testWidgets('历史双栏：左选只预览、打开按钮才切换、删除需确认，运行中禁用入口', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHistory();
    final client = _Client();
    final task = _historyTask(store, client: client);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: 'server'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(task.conversations, isEmpty);

    // 一轮对话后新建对话会保留历史
    await tester.enterText(find.byKey(const ValueKey('ai-task-input')), '检查磁盘');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pump();
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': '磁盘剩余 20G'}, []),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-new-conversation')));
    await tester.pumpAndSettle();
    expect(task.entries, isEmpty);
    await task.loadHistory();
    expect(task.conversations, hasLength(1));
    final saved = task.conversations.single;

    // 运行中的任务禁用历史入口
    client.reply = Completer<AiReply>();
    await tester.enterText(find.byKey(const ValueKey('ai-task-input')), '继续检查');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pump();
    expect(task.running, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('ai-history')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pumpAndSettle();
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': ''}, []),
    );
    await tester.pumpAndSettle();
    expect(task.running, isFalse);

    // 双栏同时可见：左侧列表 + 右侧预览；尚未切换，因此该条不是当前项
    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    await task.loadHistory();
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('ai-history-list'));
    final item = find.byKey(ValueKey('ai-history-item-${saved.id}'));
    final preview = find.byKey(const ValueKey('ai-history-preview'));
    expect(find.byType(Dialog), findsOneWidget);
    expect(list, findsOneWidget);
    expect(item, findsOneWidget);
    // 打开工作区即预览当前对话：右侧直接显示内容，不是元数据摘要
    expect(find.byKey(const ValueKey('ai-history-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-history-preview-idle')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ai-history-open')))
          .onPressed,
      isNotNull,
    );
    expect(
      find.descendant(of: item, matching: find.text(saved.title)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: item, matching: find.textContaining(saved.model)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: item, matching: find.textContaining('刚刚')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: item, matching: find.textContaining('当前')),
      findsNothing,
    );

    // 点左侧只加载右侧预览：不弹草稿确认，也不切换当前对话
    await tester.enterText(
      find.byKey(const ValueKey('ai-task-input')),
      '未发送的草稿',
    );
    await tester.pump();
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(find.text('切换对话？'), findsNothing);
    expect(task.activeConversationId, isNot(saved.id));
    expect(find.byKey(const ValueKey('ai-history-preview-idle')), findsNothing);
    expect(preview, findsOneWidget);
    expect(
      find.descendant(of: preview, matching: find.text('检查磁盘')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('磁盘剩余 20G')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: item, matching: find.textContaining('当前')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-task-input')))
          .controller!
          .text,
      '未发送的草稿',
    );

    // 只有「打开对话」会切换：草稿需确认，取消后仍停留在预览
    await tester.tap(find.byKey(const ValueKey('ai-history-open')));
    await tester.pumpAndSettle();
    expect(find.text('切换对话？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(list, findsOneWidget);
    expect(preview, findsOneWidget);
    expect(task.activeConversationId, isNot(saved.id));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-task-input')))
          .controller!
          .text,
      '未发送的草稿',
    );

    // 确认后切换，恢复 transcript、标记当前项并清空草稿
    await tester.tap(find.byKey(const ValueKey('ai-history-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '切换'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-list')), findsNothing);
    expect(task.activeConversationId, saved.id);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-task-input')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('检查磁盘'), findsOneWidget);
    expect(find.text('磁盘剩余 20G'), findsOneWidget);

    // 继续追问复用恢复后的上下文
    client.reply = Completer<AiReply>();
    await tester.enterText(find.byKey(const ValueKey('ai-task-input')), '现在呢');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pump();
    expect(
      client.requests.last.map((m) => m['content']),
      containsAllInOrder(['检查磁盘', '磁盘剩余 20G', '现在呢']),
    );
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pumpAndSettle();
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': ''}, []),
    );
    await tester.pumpAndSettle();

    // 当前项标记与删除确认
    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    await task.loadHistory();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: item, matching: find.textContaining('当前')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('ai-history-delete-${saved.id}')));
    await tester.pumpAndSettle();
    expect(find.text('删除历史对话？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(item, findsOneWidget);
    expect(
      (await store.list(_historyScope)).map((c) => c.id),
      contains(saved.id),
    );
    await tester.tap(find.byKey(ValueKey('ai-history-delete-${saved.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(item, findsNothing);
    expect(
      (await store.list(_historyScope)).map((c) => c.id),
      isNot(contains(saved.id)),
    );
    // 删除掉正在预览的那条后，预览清理并选中下一条
    expect(item, findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-history-preview')),
        matching: find.text('继续检查'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ai-history-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('窄屏 240 放大字体：历史底部弹层可切换与删除', (tester) async {
    tester.view.physicalSize = const Size(240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHistory()
      ..seed(
        _conversation(
          id: 'long-conversation-id',
          title: '整理开发服务器磁盘占用并给出清理建议',
          model: 'qwen-max-long-model-name',
          age: const Duration(minutes: 30),
        ),
      )
      ..seed(
        _conversation(
          id: 'second-conversation',
          title: '排查 Nginx 502',
          age: const Duration(days: 3),
          entries: [
            {'text': '502 是不是上游超时？', 'user': true},
            {
              'text': 'tail -n 50 /var/log/nginx/error.log',
              'command': true,
              'reason': '查看 Nginx 错误日志',
              'output': 'upstream timed out (110: Connection timed out)',
              'finished': true,
            },
            {'text': '上游超时，建议调大 proxy_read_timeout。', 'model': 'qwen-test'},
          ],
        ),
      );
    final task = _historyTask(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: '开发服务器'),
        ),
      ),
    );
    await task.loadHistory();
    await tester.pumpAndSettle();
    expect(task.conversations, hasLength(2));

    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    await task.loadHistory();
    await tester.pumpAndSettle();
    final item = find.byKey(
      const ValueKey('ai-history-item-long-conversation-id'),
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(item, findsOneWidget);
    expect(
      find.descendant(of: item, matching: find.textContaining('分钟前')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: item, matching: find.textContaining('qwen-max')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // 删除需确认，取消后保留
    await tester.tap(
      find.byKey(const ValueKey('ai-history-delete-long-conversation-id')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除历史对话？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(item, findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('ai-history-delete-long-conversation-id')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(item, findsNothing);
    expect((await store.list(_historyScope)).map((c) => c.id), [
      'second-conversation',
    ]);
    expect(tester.takeException(), isNull);

    // 点选先进预览（列表被替换），当前对话不变
    await tester.tap(
      find.byKey(const ValueKey('ai-history-item-second-conversation')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-list')), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-history-preview-back')),
      findsOneWidget,
    );
    expect(task.activeConversationId, isNull);
    // 240/2x 下预览渲染真实对话内容且无布局错误
    final phonePreview = find.byKey(const ValueKey('ai-history-preview'));
    expect(phonePreview, findsOneWidget);
    expect(
      find.descendant(of: phonePreview, matching: find.text('502 是不是上游超时？')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: phonePreview,
        matching: find.textContaining('上游超时，建议调大'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // 系统返回先回到列表（弹层仍开着），当前对话不变
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-list')), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(task.activeConversationId, isNull);

    // 返回按钮回到列表后仍是未切换状态
    await tester.tap(
      find.byKey(const ValueKey('ai-history-item-second-conversation')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-history-preview-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-list')), findsOneWidget);
    expect(task.activeConversationId, isNull);

    // 「打开对话」才切换，弹层关闭并把该条标为当前项
    await tester.tap(
      find.byKey(const ValueKey('ai-history-item-second-conversation')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-history-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-list')), findsNothing);
    expect(task.activeConversationId, 'second-conversation');

    // 删除当前对话后回到空状态
    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    final current = find.byKey(
      const ValueKey('ai-history-item-second-conversation'),
    );
    expect(
      find.descendant(of: current, matching: find.textContaining('当前')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('ai-history-delete-second-conversation')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-empty')), findsOneWidget);
    expect(await store.list(_historyScope), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('历史读取与写入失败时显式报错，不静默清空', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHistory(failWrites: true)
      ..seed(_conversation(id: 'kept', title: '保留的对话'));
    final task = _historyTask(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: 'server'),
        ),
      ),
    );
    await task.loadHistory();
    await tester.pumpAndSettle();
    expect(task.conversations, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('ai-history-item-kept'));
    expect(item, findsOneWidget);

    // 写入失败：报错，条目与存储保持原样
    await tester.tap(find.byKey(const ValueKey('ai-history-delete-kept')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('ai-history-error'))).data,
      '本地历史写入失败',
    );
    expect(item, findsOneWidget);
    expect(await store.list(_historyScope), hasLength(1));

    // 读取失败：同样报错，已加载的列表不被清空
    store.failWrites = false;
    store.failReads = true;
    await task.openConversation('kept');
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('ai-history-error'))).data,
      '本地历史文件内容已损坏，无法读取',
    );
    expect(item, findsOneWidget);
    expect(task.historyFailure, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('历史失败在主面板提示且不阻塞，窄屏放大字体不溢出', (tester) async {
    tester.view.physicalSize = const Size(240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHistory(failReads: true)
      ..seed(_conversation(id: 'kept', title: '保留的对话'));
    final task = _historyTask(store);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: '开发服务器'),
        ),
      ),
    );
    await task.loadHistory();
    await tester.pumpAndSettle();
    final notice = find.byKey(const ValueKey('ai-history-notice'));
    expect(notice, findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('ai-history-notice-text')))
          .data,
      '本地历史文件内容已损坏，无法读取',
    );
    // 不阻塞：输入框仍可用，历史列表可以正常打开
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-task-input')))
          .enabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(notice);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-history-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('保存失败时新对话与切换都不丢当前记录', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHistory(failWrites: true)
      ..seed(
        _conversation(
          id: 'older',
          title: '更早的对话',
          entries: [
            {'text': '旧对话内容', 'user': true},
          ],
        ),
      );
    final client = _Client();
    final task = _historyTask(store, client: client);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: 'server'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await task.loadHistory();
    await tester.pumpAndSettle();
    expect(task.conversations, hasLength(1));

    // 一轮对话：本地写入失败，必须显式提示
    await tester.enterText(find.byKey(const ValueKey('ai-task-input')), '检查磁盘');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pump();
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': '磁盘剩余 20G'}, []),
    );
    await tester.pumpAndSettle();
    expect(task.historyFailure, '本地历史写入失败');
    expect(find.byKey(const ValueKey('ai-history-notice')), findsOneWidget);

    // 新对话保存失败：不能清掉未保存的记录
    await tester.tap(find.byKey(const ValueKey('ai-new-conversation')));
    await tester.pumpAndSettle();
    expect(task.entries, isNotEmpty);
    expect(find.text('检查磁盘'), findsOneWidget);
    expect(find.text('磁盘剩余 20G'), findsOneWidget);

    // 只读预览不受保存失败影响，但不会替换当前 transcript
    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    await task.loadHistory();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-history-item-older')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-history-preview')),
        matching: find.text('旧对话内容'),
      ),
      findsOneWidget,
    );
    expect(find.text('磁盘剩余 20G'), findsOneWidget);

    // 保存失败时「打开对话」不能替换当前 transcript
    await tester.tap(find.byKey(const ValueKey('ai-history-open')));
    await tester.pumpAndSettle();
    expect(task.activeConversationId, isNot('older'));
    expect(find.text('磁盘剩余 20G'), findsOneWidget);
    expect(find.text('检查磁盘'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('ai-history-error'))).data,
      '本地历史写入失败',
    );
    expect(find.byKey(const ValueKey('ai-history-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('预览显示对话本体（气泡/工具卡/图片）并可滚动，删除后自动选中下一条', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryHistory()
      ..seed(
        _conversation(
          id: 'rich',
          title: '磁盘排查',
          entries: [
            {
              'text': '看看这张图并检查磁盘',
              'user': true,
              'images': [
                {'name': 'shot.png', 'mime': 'image/png', 'bytes': _png},
              ],
            },
            {'text': '磁盘输出如下', 'model': 'qwen-test'},
            {
              'text': 'df -h',
              'command': true,
              'reason': '查看磁盘占用',
              'output': '/dev/sda1  20G  19G  1.0G',
              'finished': true,
            },
            {'text': '建议清理：' * 80, 'model': 'qwen-test'},
          ],
        ),
      )
      ..seed(
        _conversation(
          id: 'next',
          title: '第二条对话',
          entries: [
            {'text': '第二条内容', 'user': true},
          ],
        ),
      );
    final task = _historyTask(store);
    // 图片解码需要真实事件循环，先把它读进当前对话：预览当前对话时走内存快照，
    // 预览本身就不再依赖 fake-async 里的解码。
    await tester.runAsync(() => task.openConversation('rich'));
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalAiPanel(task: task, hostName: 'server'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-history')));
    await tester.pumpAndSettle();
    await task.loadHistory();
    await tester.pumpAndSettle();

    // 打开工作区即预览当前对话，右侧是对话本体而不是元数据摘要
    final preview = find.byKey(const ValueKey('ai-history-preview'));
    expect(preview, findsOneWidget);
    expect(
      find.descendant(of: preview, matching: find.text('看看这张图并检查磁盘')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.byType(Image)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('磁盘输出如下')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.textContaining('查看磁盘占用')),
      findsOneWidget,
    );

    // 工具卡可展开，长文与输出一起在预览里滚动
    await tester.tap(
      find.descendant(of: preview, matching: find.byType(ExpansionTile)),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: preview, matching: find.textContaining('/dev/sda1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.textContaining('建议清理')),
      findsOneWidget,
    );
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: preview, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(position.maxScrollExtent, greaterThan(0));
    final pane = tester.getRect(preview);
    await tester.dragFrom(
      Offset(pane.right - 8, pane.top + 60),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));

    // 删除正在预览的那条后，预览切到下一条而不是留在已删除的内容上
    await tester.tap(find.byKey(const ValueKey('ai-history-delete-rich')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-history-item-rich')), findsNothing);
    expect(
      find.descendant(of: preview, matching: find.text('第二条内容')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('看看这张图并检查磁盘')),
      findsNothing,
    );
    expect(task.activeConversationId, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('标题栏独立窗口入口：嵌入弹窗/独立返回互斥，关闭面板不打断任务', (tester) async {
    tester.view.physicalSize = const Size(900, 800);
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
    var detaches = 0;
    var docks = 0;
    var closes = 0;
    Widget view({VoidCallback? onDetach, VoidCallback? onDock}) => MaterialApp(
      theme: harborTheme(),
      home: Scaffold(
        body: TerminalAiPanel(
          task: task,
          hostName: 'server',
          onDetach: onDetach,
          onDock: onDock,
          onClose: () => closes++,
        ),
      ),
    );

    // 嵌入态只提供独立窗口入口，且排在窗口级动作（关闭）左侧
    await tester.pumpWidget(view(onDetach: () => detaches++));
    expect(find.byKey(const ValueKey('ai-popout')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-dock')), findsNothing);
    expect(find.byKey(const ValueKey('ai-history')), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const ValueKey('ai-popout'))).dx,
      lessThan(tester.getCenter(find.byIcon(Icons.close_rounded)).dx),
    );
    // 桌面宽度下独立窗口入口与既有标题栏动作同尺寸，不挤压 history/new/close
    expect(
      tester.getSize(find.byKey(const ValueKey('ai-popout'))),
      tester.getSize(find.byKey(const ValueKey('ai-history'))),
    );

    // 任务运行中仍可弹出；弹出与关闭面板都不打断任务
    await tester.enterText(find.byKey(const ValueKey('ai-task-input')), '检查磁盘');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-send')));
    await tester.pump();
    expect(task.running, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('ai-popout')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('ai-popout')));
    await tester.pump();
    expect(detaches, 1);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(closes, 1);
    expect(task.running, isTrue);
    expect(client.requests, hasLength(1));
    client.reply.complete(
      const AiReply({'role': 'assistant', 'content': '磁盘正常'}, []),
    );
    await tester.pumpAndSettle();

    // 独立窗口形态只提供返回主窗口入口
    await tester.pumpWidget(view(onDock: () => docks++));
    expect(find.byKey(const ValueKey('ai-dock')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-popout')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-dock')));
    await tester.pump();
    expect(docks, 1);

    // 两个回调都缺省时入口不出现
    await tester.pumpWidget(view());
    expect(find.byKey(const ValueKey('ai-popout')), findsNothing);
    expect(find.byKey(const ValueKey('ai-dock')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });

  testWidgets('窄屏 240 放大字体：标题栏加入独立窗口入口仍不溢出', (tester) async {
    tester.view.physicalSize = const Size(240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = AiTaskController(
      settings: () =>
          const AiSettings(baseUrl: 'https://example.com/v1', model: 'test'),
      executorFactory: _Executor.new,
      connected: () => true,
    );
    task.entries.add(AiTaskEntry('服务器运行正常', model: 'test'));
    var detaches = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: TerminalAiPanel(
            task: task,
            hostName: '开发服务器',
            onDetach: () => detaches++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 历史/新对话/独立窗口/关闭四个动作与 2x 字体下仍无布局错误
    expect(find.byKey(const ValueKey('ai-history')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-new-conversation')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-popout')), findsOneWidget);
    expect(find.text('AI 助手'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-popout')));
    await tester.pump();
    expect(detaches, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    task.dispose();
  });
}

/// 1×1 PNG：图片预览测试用的最小合法图片。
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

const _historyScope = 'host-1|dev.example.com|deploy';

/// In-memory stand-in for the encrypted file store. Widget tests cannot await
/// real IO inside the fake-async zone, so the file-backed round trip stays in
/// ai_conversation_store_test.dart; this fake only feeds the panel.
class _MemoryHistory extends AiConversationStore {
  _MemoryHistory({this.failReads = false, this.failWrites = false})
    : super(
        secrets: MemoryStore(),
        directory: () async => Directory.systemTemp,
      );

  bool failReads;
  bool failWrites;
  final conversations = <String, AiConversation>{};

  static String _key(String scope, String id) => '$scope|$id';

  void seed(AiConversation conversation) =>
      conversations[_key(conversation.scope, conversation.id)] = conversation;

  @override
  Future<List<AiConversationSummary>> list(String scope) async {
    if (failReads) throw const AiConversationFailure('本地历史文件内容已损坏，无法读取');
    return [
      for (final conversation in conversations.values)
        if (conversation.scope == scope) conversation.summary,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<AiConversation?> load(String scope, String id) async {
    if (failReads) throw const AiConversationFailure('本地历史文件内容已损坏，无法读取');
    return conversations[_key(scope, id)];
  }

  @override
  Future<void> save(AiConversation conversation) async {
    if (failWrites) throw const AiConversationFailure('本地历史写入失败');
    seed(conversation);
  }

  @override
  Future<void> delete(String scope, String id) async {
    if (failWrites) throw const AiConversationFailure('本地历史写入失败');
    conversations.remove(_key(scope, id));
  }
}

AiConversation _conversation({
  required String id,
  required String title,
  String model = 'qwen-test',
  Duration age = const Duration(minutes: 5),
  List<Map<String, dynamic>> entries = const [],
}) {
  final updated = DateTime.now().subtract(age);
  return AiConversation(
    id: id,
    scope: _historyScope,
    title: title,
    model: model,
    createdAt: updated,
    updatedAt: updated,
    entries: entries,
    history: const [],
  );
}

AiTaskController _historyTask(AiConversationStore store, {_Client? client}) =>
    AiTaskController(
      settings: () =>
          const AiSettings(baseUrl: 'https://example.com/v1', model: 'test'),
      executorFactory: _Executor.new,
      connected: () => true,
      clientFactory: () => client ?? _Client(),
      historyStore: store,
      historyScope: _historyScope,
    );

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
