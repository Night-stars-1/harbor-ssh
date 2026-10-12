import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/file_workspace.dart';
import 'package:harbor_ssh/ui/port_forward_workspace.dart';
import 'package:harbor_ssh/ui/settings_page.dart';
import 'package:harbor_ssh/ui/sidebar_navigation_item.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets('手机导航只平移淡入，收藏不重建搜索状态，减少动画=$reducedMotion', (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reducedMotion);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final model = WorkspaceModel(memoryRepository());
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      final search = find.byType(TextField).first;
      final controller = tester.widget<TextField>(search).controller;
      await tester.enterText(search, 'saved-query');
      await tester.pumpAndSettle();

      Finder tab(String title) => find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(title),
      );

      Future<void> switchPage(
        Finder button,
        Finder content, {
        required bool fromEnd,
      }) async {
        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        final midway = tester.getRect(content);
        // Nested page entrances multiply their opacity on the same content.
        final fades = find.ancestor(
          of: content,
          matching: find.byType(FadeTransition),
        );
        double opacity() => tester
            .widgetList<FadeTransition>(fades)
            .fold(1.0, (value, fade) => value * fade.opacity.value);
        final midwayOpacity = opacity();
        await tester.pumpAndSettle();
        final settled = tester.getRect(content);
        // No scaling in either dimension, and no vertical motion.
        expect(midway.width, closeTo(settled.width, .001));
        expect(midway.height, closeTo(settled.height, .001));
        expect(midway.top, closeTo(settled.top, .001));
        if (reducedMotion) {
          expect(midway.left, closeTo(settled.left, .001));
          expect(midwayOpacity, 1);
        } else {
          expect(midwayOpacity, greaterThan(0));
          expect(midwayOpacity, lessThan(1));
          expect(
            midway.left,
            fromEnd ? greaterThan(settled.left) : lessThan(settled.left),
          );
        }
        expect(opacity(), 1);
        expect(tester.takeException(), isNull);
      }

      await switchPage(find.byTooltip('收藏'), search, fromEnd: true);
      expect(model.favoritesOnly, isTrue);
      expect(tester.widget<TextField>(search).controller, same(controller));
      expect(controller!.text, 'saved-query');
      await switchPage(find.byTooltip('显示全部连接'), search, fromEnd: false);
      expect(model.favoritesOnly, isFalse);
      await switchPage(tab('SFTP'), find.byType(FileWorkspace), fromEnd: true);
      final files = tester.state(find.byType(FileWorkspace));
      await switchPage(
        tab('端口转发'),
        find.byType(PortForwardWorkspace),
        fromEnd: true,
      );
      await switchPage(
        find.byKey(const ValueKey('settings-button')),
        find.byType(SettingsPage),
        fromEnd: true,
      );
      await switchPage(
        find.byKey(const ValueKey('settings-back')),
        find.byType(PortForwardWorkspace),
        fromEnd: false,
      );
      await switchPage(tab('连接'), search, fromEnd: false);
      expect(tester.widget<TextField>(search).controller, same(controller));
      expect(controller.text, 'saved-query');
      await switchPage(tab('SFTP'), find.byType(FileWorkspace), fromEnd: true);
      expect(tester.state(find.byType(FileWorkspace)), same(files));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('桌面导航仍保留轻微缩放淡入', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HarborApp(model: WorkspaceModel(memoryRepository())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final midway = tester.getRect(find.byType(SettingsPage));
    await tester.pumpAndSettle();
    final settled = tester.getRect(find.byType(SettingsPage));
    expect(midway.width, lessThan(settled.width));
    expect(midway.height, lessThan(settled.height));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面侧栏切换所有连接、收藏、凭证同样缩放淡入', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    // The nested stack is the home child shared by all three destinations.
    final home = find.byType(ExpressiveIndexedStack).at(1);

    Future<void> switchTo(String title) async {
      await tester.tap(
        find.descendant(
          of: find.byType(SidebarNavigationItem),
          matching: find.text(title),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final midway = tester.getRect(home);
      await tester.pumpAndSettle();
      final settled = tester.getRect(home);
      expect(midway.width, lessThan(settled.width));
      expect(midway.height, lessThan(settled.height));
    }

    await switchTo('收藏');
    expect(model.favoritesOnly, isTrue);
    await switchTo('凭证');
    expect(model.showingUsers, isTrue);
    await switchTo('所有连接');
    expect(model.showingUsers || model.favoritesOnly, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
