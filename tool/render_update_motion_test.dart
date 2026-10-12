import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/app_update.dart';
import 'package:harbor_ssh/ui/app_update_dialog.dart';
import 'package:harbor_ssh/ui/theme.dart';

/// Captures mid-transition frames of the update dialog into one contact
/// sheet per phase change: `artifacts/update-motion-<name>.png`.
void main() {
  testWidgets('更新弹窗切换动画帧', (tester) async {
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
    tester.view.physicalSize = const Size(560, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final size = 13 * 1024 * 1024;
    final check = UpdateCheck(
      current: '1.0.25',
      release: AppRelease(
        version: '1.0.26',
        notes: '本次更新加入应用内更新。\n\n## 新功能\n\n- **应用内更新**：直接下载并安装。',
        page: Uri.https('github.com', '/x'),
        publishedAt: DateTime(2026, 10, 12),
        asset: ReleaseAsset(
          name: 'harbor-ssh-windows-setup.exe',
          url: Uri.https('github.com', '/x.exe'),
          size: size,
        ),
      ),
    );
    final updater = _ScriptedUpdater();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: harborTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showAppUpdateDialog(
                    context,
                    check: check,
                    updaterFactory: () => updater,
                    onSkip: (_) {},
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    Future<ui.Image> frame() async => (await tester.runAsync(
      () => (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
          .toImage(pixelRatio: .5),
    ))!;
    Future<void> sheet(String name, Future<void> Function() start) async {
      await start();
      final frames = <ui.Image>[];
      for (var i = 0; i < 6; i++) {
        frames.add(await frame());
        await tester.pump(const Duration(milliseconds: 90));
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
        File('artifacts/update-motion-$name.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
      expect(tester.takeException(), isNull);
    }

    await sheet('open', () => tester.tap(find.text('open')));
    await sheet('download', () async {
      await tester.tap(find.byKey(const ValueKey('update-install')));
      await tester.pump();
      updater.report!(size * 2 ~/ 5, size);
    });
    await sheet('fail', () async {
      updater.fail();
      await tester.pump();
    });
  });
}

class _ScriptedUpdater extends AppUpdater {
  void Function(int, int)? report;
  final _done = Completer<File>();

  void fail() => _done.completeError(const UpdateFailure('下载超时，请检查网络后重试'));

  @override
  Future<File> download(
    ReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) {
    report = onProgress;
    return _done.future;
  }
}
