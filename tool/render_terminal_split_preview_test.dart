import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import '../test/support.dart';

void main() {
  testWidgets('桌面终端分屏浅色和深色预览', (tester) async {
    final font = ByteData.sublistView(
      File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
    );
    for (final name in ['Segoe UI', 'Roboto']) {
      await (FontLoader(name)..addFont(Future.value(font))).load();
    }
    final mono = ByteData.sublistView(
      File('C:/Windows/Fonts/consola.ttf').readAsBytesSync(),
    );
    for (final name in ['monospace', 'Consolas']) {
      await (FontLoader(name)..addFont(Future.value(mono))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      final sessions = [
        SshConnection(
          id: 'dev',
          host: const Host(
            id: 'dev',
            name: '开发服务器',
            address: '192.168.1.21',
            username: 'deploy',
          ),
        )..status = ConnectionStatus.connected,
        SshConnection(
          id: 'prod',
          host: const Host(
            id: 'prod',
            name: '生产服务器',
            address: '192.168.1.22',
            username: 'deploy',
          ),
        )..status = ConnectionStatus.connected,
      ];
      for (final name in ['数据库服务器', '测试服务器']) {
        sessions.add(
          SshConnection(
            id: name,
            host: Host(
              id: name,
              name: name,
              address: '192.168.1.23',
              username: 'deploy',
            ),
          )..status = ConnectionStatus.connected,
        );
        sessions.last.terminal.write(
          'deploy@server:~\$ uptime\r\n 12:08:31 up 24 days, 3:12, 1 user\r\n load average: 0.12, 0.08, 0.03\r\n\r\ndeploy@server:~\$ ',
        );
      }
      sessions[0].terminal.write(
        '\x1b[32mdeploy@development\x1b[0m:~\$ git status\r\nOn branch main\r\nYour branch is up to date with origin/main.\r\n\r\nnothing to commit, working tree clean\r\n\r\n\x1b[32mdeploy@development\x1b[0m:~\$ ',
      );
      sessions[1].terminal.write(
        '\x1b[36mdeploy@production\x1b[0m:~\$ systemctl status nginx\r\n\x1b[32m●\x1b[0m nginx.service - A high performance web server\r\n     Loaded: loaded (/lib/systemd/system/nginx.service)\r\n     Active: \x1b[32mactive (running)\x1b[0m\r\n   Main PID: 1284 (nginx)\r\n      Tasks: 5\r\n     Memory: 12.4M\r\n\r\n\x1b[36mdeploy@production\x1b[0m:~\$ ',
      );
      final model = _PreviewModel(sessions);
      await model.initialize();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: harborTheme(brightness: brightness)
                .copyWith(platform: TargetPlatform.windows),
            home: Workspace(model: model, onToggleTheme: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final axis in ['horizontal', 'vertical']) {
        await tester.tap(find.byKey(const ValueKey('terminal-split-menu-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(axis == 'horizontal' ? '左右分屏' : '上下分屏'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final picture = await boundary.toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          File('artifacts/terminal-split-$axis-${brightness.name}.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.tap(find.byKey(const ValueKey('terminal-split-menu-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消分屏'));
        await tester.pumpAndSettle();
      }
      for (final entry in [(0, '左右分屏'), (3, '上下分屏'), (0, '上下分屏')]) {
        await tester.tap(
          find.byKey(ValueKey('terminal-split-menu-${entry.$1}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.$2));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final picture = await boundary.toImage();
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        File('artifacts/terminal-split-multi-${brightness.name}.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        picture.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    }
  });
}

class _PreviewModel extends WorkspaceModel {
  _PreviewModel(this.items) : super(memoryRepository()) {
    activeSessionId = items.first.id;
  }
  final List<SshConnection> items;
  @override
  List<SshConnection> get sessions => items;
  @override
  SshConnection? get activeSession =>
      items.where((session) => session.id == activeSessionId).firstOrNull;
  @override
  void dispose() {
    for (final session in items) {
      session.dispose();
    }
    super.dispose();
  }
}
