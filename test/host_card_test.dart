import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  for (final mouse in [true, false]) {
    testWidgets('${mouse ? '右键' : '长按'}打开菜单且不连接，菜单操作可用', (tester) async {
      var connections = 0;
      var favorites = 0;
      String? action;
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 112,
                child: ExpressiveHostCard(
                  host: testHost.withFavorite(false),
                  onConnect: () => connections++,
                  onFavorite: () => favorites++,
                  onAction: (value) => action = value,
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(ExpressiveHostCard);
      expect(
        find.descendant(of: card, matching: find.byType(IconButton)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );

      Future<void> openMenu() async {
        if (mouse) {
          await tester.tap(
            card,
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
        } else {
          await tester.longPress(card);
        }
        await tester.pumpAndSettle();
        expect(connections, 0);
        expect(find.text('编辑连接'), findsOneWidget);
        expect(find.text('重置主机指纹'), findsOneWidget);
        expect(find.text('删除连接'), findsOneWidget);
      }

      await openMenu();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(favorites, 1);
      await openMenu();
      await tester.tap(find.text('编辑连接'));
      await tester.pumpAndSettle();
      expect(action, 'edit');
      await openMenu();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(connections, 0);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(connections, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('多个标签各自成为独立徽章且不拼接', (tester) async {
    const tags = ['持续集成-dev', '夜间构建', '生产备用'];
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: ExpressiveHostCard(
                host: const Host(
                  id: 'multi',
                  name: '构建机',
                  address: 'build.internal',
                  username: 'deploy',
                  tags: tags,
                ),
                onConnect: () {},
                onFavorite: () {},
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byType(ExpressiveHostCard);
    for (final tag in tags) {
      expect(
        find.descendant(of: card, matching: find.text(tag)),
        findsOneWidget,
      );
    }
    expect(find.textContaining('分组'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无标签主机不显示伪造的标签徽章', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: ExpressiveHostCard(
                host: const Host(
                  id: 'bare',
                  name: '裸机',
                  address: 'bare.internal',
                  username: 'deploy',
                ),
                onConnect: () {},
                onFavorite: () {},
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byType(ExpressiveHostCard);
    expect(
      find.descendant(of: card, matching: find.byType(Text)),
      findsNWidgets(2),
    );
    expect(find.textContaining('分组'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏两倍字缩放下长标签省略而不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: ExpressiveHostCard(
                host: const Host(
                  id: 'long',
                  name: '生产环境数据库跳板机',
                  address: 'database-jump.internal.example.com',
                  username: 'deploy',
                  tags: ['生产环境数据库跳板机与夜间备份节点'],
                ),
                onConnect: () {},
                onFavorite: () {},
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.text('生产环境数据库跳板机与夜间备份节点');
    expect(label, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面网格按标签数量增高卡片且不溢出', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = memoryRepository();
    await repository.saveHosts([
      testHost,
      const Host(
        id: 'host-grid',
        name: '构建机',
        address: 'build.internal',
        username: 'deploy',
        tags: ['持续集成构建流水线作业', '夜间定时构建任务队列', '生产备用接入节点名称'],
      ),
      const Host(
        id: 'host-bare',
        name: '裸机',
        address: 'bare.internal',
        username: 'deploy',
      ),
    ]);
    await tester.pumpWidget(HarborApp(model: WorkspaceModel(repository)));
    await tester.pumpAndSettle();
    final card = find.byType(ExpressiveHostCard);
    for (final tag in ['持续集成构建流水线作业', '夜间定时构建任务队列', '生产备用接入节点名称']) {
      expect(
        find.descendant(of: card, matching: find.text(tag)),
        findsOneWidget,
      );
    }
    final tagged = tester.getSize(
      find.ancestor(of: find.text('持续集成构建流水线作业'), matching: card),
    );
    final bare = tester.getSize(
      find.ancestor(of: find.text('裸机'), matching: card),
    );
    expect(tagged.height, greaterThan(bare.height));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
