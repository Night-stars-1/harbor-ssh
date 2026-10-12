import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import '../test/support.dart';

/// Contact sheets of page transitions: `artifacts/page-motion-<name>.png`.
void main() {
  Future<void> setUpFonts(WidgetTester tester) async {
    final font = ByteData.sublistView(
      File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
    );
    for (final name in ['Segoe UI', 'Roboto']) {
      await (FontLoader(name)..addFont(Future.value(font))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> sheet(
    WidgetTester tester,
    String name,
    Future<void> Function() start,
  ) async {
    Future<ui.Image> frame() async => (await tester.runAsync(
      () => (tester.renderObject(find.byKey(_shot)) as RenderRepaintBoundary)
          .toImage(pixelRatio: .4),
    ))!;
    await start();
    final frames = <ui.Image>[];
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      frames.add(await frame());
    }
    await tester.pumpAndSettle();
    frames.add(await frame());
    await tester.runAsync(() async {
      final w = frames.first.width, h = frames.first.height;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (final (i, image) in frames.indexed) {
        canvas.drawImage(image, Offset(i * w.toDouble(), 0), Paint());
      }
      final out = await recorder.endRecording().toImage(w * frames.length, h);
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      File('artifacts/page-motion-$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull);
  }

  testWidgets('桌面页面切换', (tester) async {
    await setUpFonts(tester);
    tester.view.physicalSize = const Size(1200, 760);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    await tester.pumpWidget(
      _shoot(HarborApp(model: WorkspaceModel(repository))),
    );
    await tester.pumpAndSettle();
    await sheet(tester, 'desktop-settings', () async {
      await tester.tap(find.byKey(const ValueKey('settings-button')));
    });
    await sheet(tester, 'desktop-section', () async {
      await tester.tap(find.byKey(const ValueKey('settings-category-4')));
    });
    await sheet(tester, 'dialog', () async {
      await tester.tap(find.byKey(const ValueKey('settings-category-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建服务商'));
    });
  });

  testWidgets('手机设置分类进入与返回', (tester) async {
    await setUpFonts(tester);
    tester.view.physicalSize = const Size(400, 760);
    await tester.pumpWidget(
      _shoot(HarborApp(model: WorkspaceModel(memoryRepository()))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    await sheet(tester, 'mobile-forward', () async {
      await tester.tap(find.byKey(const ValueKey('settings-category-2')));
    });
    await sheet(tester, 'mobile-back', () async {
      await tester.tap(find.byKey(const ValueKey('settings-category-back')));
    });
  });

  testWidgets('手机主导航与收藏只滑动淡入', (tester) async {
    await setUpFonts(tester);
    tester.view.physicalSize = const Size(390, 800);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    await tester.pumpWidget(
      _shoot(HarborApp(model: WorkspaceModel(repository))),
    );
    await tester.pumpAndSettle();
    await sheet(tester, 'mobile-favorites', () async {
      await tester.tap(find.byTooltip('收藏'));
    });
    await sheet(tester, 'mobile-connections', () async {
      await tester.tap(find.byTooltip('显示全部连接'));
    });
    await sheet(tester, 'mobile-sftp', () async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('SFTP'),
        ),
      );
    });
    await sheet(tester, 'mobile-forwards', () async {
      await tester.tap(find.byKey(const ValueKey('mobile-port-forwards')));
    });
    await sheet(tester, 'mobile-settings', () async {
      await tester.tap(find.byKey(const ValueKey('settings-button')));
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

const _shot = ValueKey('shot');
Widget _shoot(Widget app) => RepaintBoundary(key: _shot, child: app);
