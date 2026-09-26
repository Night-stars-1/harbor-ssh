import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/remote_file.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import '../test/file_browser_test.dart' show FakeRemoteFiles;
import '../test/support.dart';

void main() {
  testWidgets('独立 SFTP 多标签双面板预览', (tester) async {
    final fontData = ByteData.sublistView(
      File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
    );
    for (final name in ['Segoe UI', 'Roboto']) {
      await (FontLoader(name)..addFont(Future.value(fontData))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final brightness in Brightness.values) {
      for (final mobile in [false, true]) {
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1440, 900);
        final model = WorkspaceModel(memoryRepository());
        await model.initialize();
        model.showFiles();
        final files = model.fileWorkspace;
        final local = files.add(
          0,
          name: '本地 · Downloads',
          isLocal: true,
          files: _PreviewFiles(true),
        );
        files.add(0, name: '开发服务器', files: _PreviewFiles(false));
        files.activate(0, local.id);
        final remote = files.add(1, name: '生产服务器', files: _PreviewFiles(false));
        files.add(1, name: '备份服务器', files: _PreviewFiles(false));
        files.activate(1, remote.id);
        await Future.wait([local.browse(), remote.browse()]);
        local.toggle(
          local.entries.firstWhere((file) => file.name == 'release.tar.gz'),
        );
        if (mobile) files.copySelection(local);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: harborTheme(brightness: brightness).copyWith(
                platform: mobile
                    ? TargetPlatform.android
                    : TargetPlatform.windows,
              ),
              home: Workspace(model: model, onToggleTheme: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Future<void> capture(String name) => tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          File('artifacts/$name.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          picture.dispose();
        });
        await capture(
          'sftp-workspace-${mobile ? 'mobile' : 'desktop'}-${brightness.name}',
        );
        if (mobile) {
          files.activate(0, local.id);
          local.select(
            local.entries.firstWhere((file) => file.name == 'release.tar.gz'),
          );
          await tester.pumpAndSettle();
          await capture('sftp-workspace-mobile-copy-${brightness.name}');
          final row = find.byKey(
            ValueKey('entry-${local.id}-${local.path}/deploy.sh'),
          );
          final swipe = await tester.startGesture(tester.getCenter(row));
          await swipe.moveBy(const Offset(64, 0));
          await tester.pump();
          await capture('sftp-workspace-mobile-swipe-${brightness.name}');
          await swipe.cancel();
          await tester.pumpAndSettle();
        }
        if (!mobile) {
          final row = find.byKey(
            ValueKey('entry-${remote.id}-${remote.path}/README.md'),
          );
          await tester.tapAt(
            tester.getCenter(row),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await capture('sftp-workspace-menu-${brightness.name}');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          files.message = '已删除 1 个文件';
          files.resize(files.split);
          await tester.pumpAndSettle();
          await capture('sftp-workspace-result-${brightness.name}');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        model.dispose();
      }
    }
  });
}

class _PreviewFiles extends FakeRemoteFiles {
  _PreviewFiles(this.local);
  final bool local;
  @override
  Future<RemoteDirectory> browse(String path) async {
    final root = local ? 'C:/Users/Admin/Downloads' : '/home/deploy';
    return RemoteDirectory(root, [
      for (final name
          in local ? ['Documents', 'projects'] : ['backups', 'logs', 'www'])
        RemoteFile(name: name, path: '$root/$name', isDirectory: true),
      for (final item
          in local
              ? {
                  'deploy.sh': 2400,
                  'nginx.conf': 3800,
                  'release.tar.gz': 48000000,
                  '部署说明.md': 1600,
                }.entries
              : {
                  'app.log': 240000,
                  'docker-compose.yml': 3800,
                  'README.md': 1600,
                }.entries)
        RemoteFile(name: item.key, path: '$root/${item.key}', size: item.value),
    ]);
  }
}
