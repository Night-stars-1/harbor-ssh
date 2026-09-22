import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/host_editor.dart';

void main() {
  const baseHost = Host(
    id: 'host-1',
    name: '开发服务器',
    address: 'dev.example.com',
    username: 'deploy',
  );

  final tagField = find.widgetWithText(TextFormField, '标签（可选）');
  final addButton = find.byTooltip('添加标签');
  final saveButton = find.text('保存连接');
  Finder deleteButton(String tag) => find.byTooltip('删除标签 $tag');
  final anyDeleteButton = find.byWidgetPredicate(
    (widget) => widget is Tooltip && (widget.message ?? '').startsWith('删除标签'),
  );

  Future<void> openEditor(
    WidgetTester tester, {
    required SaveHost onSave,
    Host? host,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => HostEditor(
                  host: host,
                  onSave: onSave,
                  onTest: (_, _) async {},
                ),
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
  }

  Future<void> addByEnter(WidgetTester tester, String text) async {
    await tester.enterText(tagField, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> addByButton(WidgetTester tester, String text) async {
    await tester.enterText(tagField, text);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
  }

  Future<void> removeTag(WidgetTester tester, String tag) async {
    await tester.tap(deleteButton(tag));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
  }

  testWidgets('回车与添加按钮都能加入标签，未确认的输入保存时不丢', (tester) async {
    Host? saved;
    await openEditor(
      tester,
      host: baseHost,
      onSave: (host, _) async => saved = host,
    );

    await addByEnter(tester, ' 生产环境 ');
    expect(find.text('生产环境'), findsOneWidget);

    await addByButton(tester, '  灰度发布  ');
    expect(find.text('灰度发布'), findsOneWidget);

    // 输入后没有按回车或添加按钮，保存时也必须带上这条标签。
    await tester.enterText(tagField, '未确认 ');
    await submit(tester);

    expect(saved?.tags, ['生产环境', '灰度发布', '未确认']);
    expect(find.byType(HostEditor), findsNothing);
  });

  testWidgets('重复与空白标签被忽略，标签内的空格不拆分', (tester) async {
    Host? saved;
    await openEditor(
      tester,
      host: baseHost,
      onSave: (host, _) async => saved = host,
    );

    await addByEnter(tester, '生产环境');
    await addByEnter(tester, '生产环境');
    expect(find.text('生产环境'), findsOneWidget);
    expect(anyDeleteButton, findsOneWidget);

    await addByEnter(tester, '   ');
    expect(anyDeleteButton, findsOneWidget);

    await addByButton(tester, '多 词 标签');
    expect(find.text('多 词 标签'), findsOneWidget);

    // 未确认的重复输入同样不会重复提交。
    await tester.enterText(tagField, '生产环境');
    await submit(tester);

    expect(saved?.tags, ['生产环境', '多 词 标签']);
  });

  testWidgets('编辑已有标签完整显示，可逐个删除直到清空', (tester) async {
    const host = Host(
      id: 'host-1',
      name: '开发服务器',
      address: 'dev.example.com',
      username: 'deploy',
      tags: ['生产', '测试', '个人'],
    );
    Host? saved;
    await openEditor(tester, host: host, onSave: (h, _) async => saved = h);

    for (final tag in host.tags) {
      expect(find.text(tag), findsOneWidget);
      expect(deleteButton(tag), findsOneWidget);
    }

    await removeTag(tester, '测试');
    expect(find.text('测试'), findsNothing);
    expect(find.text('生产'), findsOneWidget);

    await removeTag(tester, '生产');
    await removeTag(tester, '个人');
    expect(anyDeleteButton, findsNothing);

    await submit(tester);
    expect(saved?.tags, isEmpty);
  });

  testWidgets('窄屏长标签换行不溢出，保存期间禁用标签增删', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const longTag = '生产环境-华东-北京-可用区三-核心数据库-只读副本-凌晨批处理专用';
    final gate = Completer<void>();
    Host? saved;
    await openEditor(
      tester,
      host: const Host(
        id: 'host-1',
        name: '开发服务器',
        address: 'dev.example.com',
        username: 'deploy',
        tags: [longTag],
      ),
      onSave: (host, _) {
        saved = host;
        return gate.future;
      },
    );

    expect(find.text(longTag), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(tagField);
    await addByEnter(tester, '灰度');
    expect(tester.takeException(), isNull);

    // 保存进行中：输入框与标签增删都不可用。
    await tester.enterText(tagField, '忙碌中');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();

    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_rounded))
          .onPressed,
      isNull,
    );
    await tester.tap(addButton, warnIfMissed: false);
    await tester.tap(deleteButton(longTag), warnIfMissed: false);
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: deleteButton(longTag),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(deleteButton('忙碌中'), findsNothing);
    expect(deleteButton(longTag), findsOneWidget);
    expect(find.text(longTag), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(saved?.tags, [longTag, '灰度', '忙碌中']);
    expect(tester.takeException(), isNull);
  });
}
