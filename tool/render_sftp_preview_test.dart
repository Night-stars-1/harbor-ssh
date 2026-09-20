import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/remote_file.dart';
import 'package:harbor_ssh/ui/file_browser.dart';
import 'package:harbor_ssh/ui/theme.dart';

import '../test/file_browser_test.dart'
    show FileTestSession, FakeLocalTransfer, FakeRemoteFiles;

void main() {
  testWidgets('SFTP 桌面和手机浅色深色预览', (tester) async {
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
            : const Size(1120, 740);
        final key = GlobalKey();
        final session = _PreviewSession();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: harborTheme(brightness: brightness),
              home: FileBrowser(session: session, local: FakeLocalTransfer()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File(
            'artifacts/sftp-${mobile ? 'mobile' : 'desktop'}-${brightness.name}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      }
    }
  });
}

class _PreviewSession extends FileTestSession {
  @override
  RemoteFileSystem get files => _PreviewFiles();
}

class _PreviewFiles extends FakeRemoteFiles {
  @override
  Future<RemoteDirectory> browse(String path) async =>
      RemoteDirectory('/home/deploy', [
        for (final name in ['backups', 'projects', 'www'])
          RemoteFile(
            name: name,
            path: '/home/deploy/$name',
            isDirectory: true,
            modified: DateTime(2026, 9, 19, 10, 30),
          ),
        RemoteFile(
          name: 'deploy.sh',
          path: '/home/deploy/deploy.sh',
          size: 2400,
          modified: DateTime(2026, 9, 19, 9, 15),
        ),
        RemoteFile(
          name: 'nginx.conf',
          path: '/home/deploy/nginx.conf',
          size: 3800,
          modified: DateTime(2026, 9, 18, 17, 42),
        ),
        RemoteFile(
          name: 'release.tar.gz',
          path: '/home/deploy/release.tar.gz',
          size: 48000000,
          modified: DateTime(2026, 9, 19, 8, 0),
        ),
        RemoteFile(
          name: '部署说明.md',
          path: '/home/deploy/部署说明.md',
          size: 1600,
          modified: DateTime(2026, 9, 17, 12, 30),
        ),
      ]);
}
