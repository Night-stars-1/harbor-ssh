import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/settings_page.dart';
import 'package:harbor_ssh/ui/settings_widgets.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import '../test/support.dart';

void main() {
  testWidgets('云同步桌面和手机深浅色预览', (tester) async {
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
    for (final brightness in Brightness.values) {
      for (final size in [const Size(840, 820), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        final model = WorkspaceModel(memoryRepository());
        await model.initialize();
        await model.configureSync(
          const WebDavSettings(
            url: 'https://dav.example.com/HarborSSH/',
            username: 'harbor',
            password: 'example-app-password',
            encryptionPassword: 'example-encryption-password',
          ),
        );
        model.showSettings();
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: harborTheme(brightness: brightness),
              home: size.width >= 600
                  ? Scaffold(
                      body: SettingsPage(
                        model: model,
                        desktop: true,
                        standalone: true,
                      ),
                    )
                  : Workspace(model: model, onToggleTheme: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-category-0')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'artifacts/local-file-settings-${size.width.toInt()}-${brightness.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        if (size.width < 700) {
          await tester.tap(
            find.byKey(const ValueKey('settings-category-back')),
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('settings-category-1')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'artifacts/cloud-sync-${size.width.toInt()}-${brightness.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        for (final error in [false, true]) {
          showSettingsNotice(
            tester.element(find.byType(SettingsPage)),
            error ? '请输入 HTTPS WebDAV 目录地址' : '同步设置已保存',
            error: error,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await boundary.toImage();
            final data = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File(
              'artifacts/settings-notice-${error ? 'error' : 'success'}-${size.width.toInt()}-${brightness.name}.png',
            ).writeAsBytesSync(data!.buffer.asUint8List());
            picture.dispose();
          });
        }
        ScaffoldMessenger.of(tester.element(find.byType(SettingsPage)))
            .removeCurrentSnackBar();
        final provider = find.byKey(const ValueKey('sync-provider'));
        await tester.ensureVisible(provider);
        await tester.tap(provider);
        await tester.pumpAndSettle();
        await tester.tap(find.text('GitHub Gist').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'artifacts/gist-sync-${size.width.toInt()}-${brightness.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.ensureVisible(provider);
        await tester.tap(provider);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'artifacts/gist-provider-menu-${size.width.toInt()}-${brightness.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        if (size.width < 700) {
          await tester.tap(
            find.byKey(const ValueKey('settings-category-back')),
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('settings-category-2')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'artifacts/appearance-settings-${size.width.toInt()}-${brightness.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
      }
    }
  });
}
