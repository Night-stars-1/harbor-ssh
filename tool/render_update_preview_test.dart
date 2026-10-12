import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/app_update.dart';
import 'package:harbor_ssh/ui/about_settings.dart';
import 'package:harbor_ssh/ui/app_update_dialog.dart';
import 'package:harbor_ssh/ui/sync_settings_controller.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import '../test/support.dart';

void main() {
  testWidgets('应用更新弹窗与关于页深浅色预览（真实 GitHub Release）', (tester) async {
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

    AppUpdater updater() => AppUpdater(
      platform: TargetPlatform.windows,
      installedVersion: () async => '1.0.24',
      installerManaged: true,
    );
    // The test binding fakes every HttpClient; this zone talks to GitHub.
    Future<T> live<T>(Future<T> Function() body) => tester
        .runAsync(() => HttpOverrides.runWithHttpOverrides(body, _RealHttp()))
        .then((value) => value as T);
    final check = await live(() => updater().check());
    final asset = check.release.asset!;
    // ignore: avoid_print
    print(
      'live: ${check.current} -> ${check.release.version}, '
      'available=${check.available}, asset=${asset.name} '
      '${asset.size} sha256=${asset.sha256}',
    );
    expect(check.available, isTrue);
    expect(asset.sha256, isNotNull);
    final directory = Directory.systemTemp.createTempSync('harbor-update');
    addTearDown(() => directory.deleteSync(recursive: true));
    final package = await live(
      () => AppUpdater(
        platform: TargetPlatform.windows,
        downloadDirectory: () async => directory,
      ).download(asset),
    );
    // ignore: avoid_print
    print('verified download: ${package.lengthSync()} bytes');
    expect(package.lengthSync(), asset.size);
    Future<void> capture(GlobalKey key, String name) =>
        tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File('artifacts/$name.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });

    for (final brightness in Brightness.values) {
      for (final size in [const Size(900, 760), const Size(390, 760)]) {
        tester.view.physicalSize = size;
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: harborTheme(brightness: brightness),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      onPressed: () => showAppUpdateDialog(
                        context,
                        check: check,
                        updaterFactory: () => _StalledUpdater(),
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
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(
          key,
          'update-dialog-${size.width.toInt()}-${brightness.name}',
        );
        if (size.width > 400) {
          await tester.tap(find.byKey(const ValueKey('update-install')));
          await tester.pumpAndSettle();
          _StalledUpdater.report!(asset.size * 37 ~/ 100, asset.size);
          await tester.pumpAndSettle();
          await capture(key, 'update-downloading-${brightness.name}');
          await tester.tap(find.byKey(const ValueKey('update-cancel')));
          await tester.pumpAndSettle();
        }
      }

      tester.view.physicalSize = const Size(760, 640);
      final model = WorkspaceModel(memoryRepository());
      await tester.runAsync(model.initialize);
      final controller = LocalSyncSettingsController(model);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: harborTheme(brightness: brightness),
            home: Scaffold(
              backgroundColor: harborTheme(brightness: brightness)
                  .colorScheme
                  .surface,
              body: AboutSettings(
                controller: controller,
                updaterFactory: updater,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(key, 'about-settings-${brightness.name}');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      model.dispose();
    }
  });
}

class _RealHttp extends HttpOverrides {}

/// Holds the download open so the progress state can be captured.
class _StalledUpdater extends AppUpdater {
  static void Function(int, int)? report;
  final _cancelled = Completer<File>();

  @override
  Future<File> download(
    ReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) {
    report = onProgress;
    return _cancelled.future;
  }

  @override
  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.completeError(const UpdateCancelled());
    }
  }
}
