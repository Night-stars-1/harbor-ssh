import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/port_forward_panel.dart';
import 'package:harbor_ssh/ui/port_forward_preview.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:harbor_ssh/data/port_forward_manager.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/domain/port_forward.dart';

import '../test/support.dart';

class _PreviewModel extends WorkspaceModel {
  _PreviewModel(super.repository, this.items);
  final List<SshConnection> items;
  @override
  List<SshConnection> get sessions => items;
  @override
  void dispose() {
    for (final session in items) {
      session.dispose();
    }
    super.dispose();
  }
}

void main() {
  testWidgets('render forwarding panels and editor', (tester) async {
    final fontPath = Platform.environment['HARBOR_PREVIEW_FONT'];
    if (fontPath != null) {
      for (final family in ['Segoe UI', 'Roboto']) {
        await (FontLoader(family)..addFont(
              Future.value(
                ByteData.sublistView(File(fontPath).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    tester.view.devicePixelRatio = 1;
    final monoPath = Platform.environment['HARBOR_PREVIEW_MONO_FONT'];
    if (monoPath != null) {
      await (FontLoader('monospace')..addFont(
            Future.value(
              ByteData.sublistView(File(monoPath).readAsBytesSync()),
            ),
          ))
          .load();
    }
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    Future<Widget> homePreview({
      AppThemeMode mode = AppThemeMode.light,
      bool empty = false,
      bool failed = false,
      bool multiple = false,
    }) async {
      final repository = memoryRepository();
      await repository.saveHosts([testHost]);
      if (!empty) {
        await PortForwardStore(repository.preferences, testHost.id).save([
          const PortForwardRule(
            id: 'db',
            name: '数据库',
            type: PortForwardType.local,
            bindPort: 15432,
            targetPort: 5432,
          ),
          if (multiple) ...[
            const PortForwardRule(
              id: 'proxy',
              name: '开发代理',
              type: PortForwardType.dynamic,
              bindPort: 1080,
            ),
            const PortForwardRule(
              id: 'remote',
              name: '远程调试',
              type: PortForwardType.remote,
              bindPort: 8080,
              targetPort: 3000,
            ),
          ],
        ]);
      }
      final model = _PreviewModel(repository, [
        if (failed)
          SshConnection(id: 'preview-failed', host: testHost)
            ..status = ConnectionStatus.failed
            ..error =
                'SSHAuthAbortError(Connection closed before authentication)',
      ])..showPortForwards();
      await model.saveAppearance(AppearancePreferences(mode: mode));
      return HarborApp(model: model);
    }

    for (final (name, size, widget) in [
      (
        'forward-card-comparison-dark',
        const Size(900, 480),
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: harborTheme(brightness: Brightness.dark),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('主机卡片'),
                  const SizedBox(height: 12),
                  ExpressiveHostCard(
                    host: testHost,
                    onConnect: () {},
                    onFavorite: () {},
                    onAction: (_) {},
                  ),
                  const SizedBox(height: 28),
                  const Text('转发规则'),
                  const SizedBox(height: 12),
                  PortForwardRuleCard(
                    rule: const PortForwardRule(
                      id: 'preview-auto',
                      name: '开发服务',
                      type: PortForwardType.local,
                      bindPort: 0,
                      targetPort: 8080,
                    ),
                    hostLabel: testHost.name,
                    state: const PortForwardState(),
                    connected: true,
                    onStart: (_) {},
                    onStop: (_) {},
                    onEdit: (_) {},
                    onDelete: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ('forward-home-desktop', const Size(1280, 900), await homePreview()),
      (
        'forward-home-desktop-grid',
        const Size(1280, 900),
        await homePreview(multiple: true),
      ),
      ('forward-home-mobile', const Size(390, 844), await homePreview()),
      (
        'forward-home-compact-dark',
        const Size(590, 1100),
        await homePreview(mode: AppThemeMode.dark, multiple: true),
      ),
      (
        'forward-home-dark-empty',
        const Size(1440, 960),
        await homePreview(mode: AppThemeMode.dark, empty: true, failed: true),
      ),
      (
        'forward-home-dark-rules',
        const Size(1440, 960),
        await homePreview(mode: AppThemeMode.dark, multiple: true),
      ),
      (
        'forward-home-mobile-empty',
        const Size(390, 844),
        await homePreview(mode: AppThemeMode.dark, empty: true, failed: true),
      ),
      ('forward-desktop', const Size(760, 720), portForwardPreview()),
      ('forward-dark', const Size(760, 720), portForwardDarkPreview()),
      ('forward-mobile', const Size(320, 720), portForwardNarrowPreview()),
      (
        'forward-editor-mobile',
        const Size(320, 720),
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: harborTheme(),
          home: const Scaffold(body: PortForwardEditor(hosts: [testHost])),
        ),
      ),
      for (final menu in ['host', 'type'])
        (
          'forward-editor-$menu-menu-dark',
          const Size(760, 900),
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: harborTheme(brightness: Brightness.dark),
            home: const Scaffold(body: PortForwardEditor(hosts: [testHost])),
          ),
        ),
    ]) {
      tester.view.physicalSize = size;
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: key, child: widget));
      await tester.pumpAndSettle();
      if (name.endsWith('menu-dark')) {
        final field = find.byKey(
          ValueKey(
            name.contains('host-menu') ? 'forward-host' : 'forward-type',
          ),
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory('artifacts').createSync(recursive: true);
        File('artifacts/$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
