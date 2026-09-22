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
  for (final width in [390.0, 1280.0]) {
    testWidgets('主机地址隐藏与恢复不修改连接数据，布局宽度 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final repository = memoryRepository();
      const host = Host(
        id: 'privacy',
        name: '隐私测试主机',
        address: '192.0.2.42',
        username: 'deploy',
        port: 2222,
        tags: ['生产环境'],
      );
      await repository.saveHosts([host]);
      final model = WorkspaceModel(repository);
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('toggle-host-addresses'));
      expect(find.text('deploy@192.0.2.42:2222'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.textContaining(host.address), findsNothing);
      expect(find.text('deploy@••••••:2222'), findsOneWidget);
      expect(find.text(host.name), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ExpressiveHostCard),
          matching: find.text('生产环境'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('显示 IP 地址'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(ExpressiveHostCard)).toStringDeep(),
        isNot(contains(host.address)),
      );
      expect(model.hosts.single.address, host.address);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('deploy@192.0.2.42:2222'), findsOneWidget);
      expect(find.byTooltip('隐藏 IP 地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    });
  }

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

  testWidgets('无标签主机显示未分组徽章，添加标签后替换默认徽章', (tester) async {
    Future<void> showHost(List<String> tags) => tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: ExpressiveHostCard(
                host: Host(
                  id: 'bare',
                  name: '测试主机',
                  address: 'bare.internal',
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
    await showHost(const []);
    await tester.pumpAndSettle();
    expect(find.text('未分组'), findsOneWidget);
    await showHost(const ['生产环境']);
    await tester.pumpAndSettle();
    expect(find.text('未分组'), findsNothing);
    expect(find.text('生产环境'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏两倍字缩放下长标签省略而不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
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

  testWidgets('桌面网格卡片等高且完整容纳多标签', (tester) async {
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
    expect(tagged.height, bare.height);
    for (final element in card.evaluate()) {
      final item = find.byWidget(element.widget);
      final surface = find
          .descendant(of: item, matching: find.byType(Material))
          .first;
      expect(tester.getSize(surface).height, tester.getSize(item).height);
      final bounds = tester.getRect(item);
      for (final text
          in find
              .descendant(of: item, matching: find.byType(Text))
              .evaluate()) {
        final textBounds = tester.getRect(find.byWidget(text.widget));
        expect(textBounds.bottom, lessThanOrEqualTo(bounds.bottom));
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
