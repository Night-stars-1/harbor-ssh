import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/path_completion.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/host_identity_dialog.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';

import '../test/support.dart';

void main() {
  testWidgets('render desktop and mobile previews', (tester) async {
    final previousShadowSetting = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousShadowSetting);
    final fontPath = Platform.environment['HARBOR_PREVIEW_FONT'];
    if (fontPath != null) {
      final font = FontLoader('Segoe UI')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await font.load();
      final roboto = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await roboto.load();
      final mono = FontLoader('monospace')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/consola.ttf').readAsBytesSync(),
            ),
          ),
        );
      await mono.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    Future<void> capture(GlobalKey key, String name) async {
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

    for (final variant in [
      'desktop',
      'mobile',
      'desktop-dark',
      'mobile-dark',
      'desktop-large',
      'mobile-large',
      'desktop-dense',
      'mobile-dense',
      'desktop-empty',
      'mobile-empty',
    ]) {
      final mobile = variant.startsWith('mobile');
      final large = variant.endsWith('large');
      tester.platformDispatcher.textScaleFactorTestValue = large ? 2 : 1;
      tester.view.physicalSize = mobile
          ? const Size(390, 844)
          : const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      final repository = memoryRepository();
      await repository.saveHosts([
        const Host(
          id: '1',
          name: 'Production API',
          address: 'api.example.com',
          username: 'deploy',
          group: '生产环境',
          favorite: true,
          authMethod: AuthMethod.privateKey,
        ),
        const Host(
          id: '2',
          name: '开发服务器',
          address: 'dev.example.com',
          username: 'developer',
          group: '开发环境',
        ),
        const Host(
          id: '3',
          name: 'Home Lab',
          address: '192.0.2.10',
          username: 'admin',
          group: '个人',
          authMethod: AuthMethod.privateKey,
        ),
        if (variant.endsWith('dense'))
          for (var index = 4; index <= 20; index++)
            Host(
              id: '$index',
              name: 'Node ${index.toString().padLeft(2, '0')}',
              address: 'node$index.example.com',
              username: 'deploy',
              group: index.isEven ? '生产环境' : '开发环境',
            ),
      ]);
      if (variant.endsWith('empty')) await repository.saveHosts([]);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: HarborApp(model: WorkspaceModel(repository)),
        ),
      );
      await tester.pumpAndSettle();
      if (variant.endsWith('dark')) {
        await tester.tap(find.byTooltip('切换浅色/深色主题').first);
        await tester.pumpAndSettle();
      }
      if (large) {
        await tester.scrollUntilVisible(
          find.byWidgetPredicate(
            (widget) => widget is ExpressiveHostCard && widget.host.id == '1',
          ),
          200,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await capture(key, variant);
      if (variant == 'desktop' || variant == 'mobile') {
        await tester.tap(
          mobile ? find.byType(FloatingActionButton) : find.text('新建连接'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(key, '$variant-editor');
        final credentialMenu = find.byType(DropdownMenuFormField<String>);
        await tester.ensureVisible(credentialMenu);
        await tester.tap(credentialMenu);
        await tester.pumpAndSettle();
        await capture(key, '$variant-credential-menu');
        await tester.tap(find.text('不使用凭证').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('取消'));
        await tester.tap(find.byTooltip('取消'));
        await tester.pumpAndSettle();
        await tester.tap(
          mobile
              ? find.descendant(
                  of: find.byType(NavigationBar),
                  matching: find.text('凭证'),
                )
              : find.text('凭证'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          mobile ? find.byType(FloatingActionButton) : find.text('新建凭证'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(key, '$variant-credential-editor');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    for (final brightness in Brightness.values) {
      for (final mobile in [false, true]) {
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(600, 640);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: harborTheme(brightness: brightness),
              home: const Scaffold(
                body: HostIdentityDialog(
                  host: testHost,
                  keyType: 'ssh-ed25519',
                  fingerprint:
                      'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture(
          key,
          'host-identity-${mobile ? 'mobile' : 'desktop'}-${brightness.name}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    for (final brightness in Brightness.values) {
      tester.view.physicalSize = const Size(1280, 800);
      final session = _CompletionPreviewSession(
        id: 'preview-terminal',
        host: const Host(
          id: 'preview',
          name: '开发服务器',
          address: 'dev.example.com',
          username: 'deploy',
        ),
      )..status = ConnectionStatus.connected;
      session.terminal.write(
        'deploy@server:~\$ ls\r\nREADME.md  app.dart  config/\r\n\r\n'
        '\x1b[32mConnected securely.\x1b[0m\r\n'
        '\x1b[34mWorkspace ready.\x1b[0m\r\n'
        'Documentation: https://help.ubuntu.com\r\n'
        'Support: https://ubuntu.com/pro\r\n\r\ndeploy@server:~\$ ',
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: harborTheme(brightness: brightness),
            home: Scaffold(
              body: TerminalPane(session: session, onReconnect: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(key, 'terminal-${brightness.name}');
      session.terminal.write('cd ');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('Documents/'), findsOneWidget);
      await capture(key, 'terminal-completion-${brightness.name}');
      session.commandHistory.mergeOlder([
        'docker compose logs --tail=100 api',
        'docker compose up -d',
        'docker ps',
      ]);
      session.terminal.write('\r\ndeploy@server:~\$ do');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('docker ps'), findsOneWidget);
      await capture(key, 'terminal-history-${brightness.name}');
      session.terminal.write('\r\ndeploy@server:~\$ docker ');
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.text('attach'), findsWidgets);
      await capture(key, 'terminal-subcommands-${brightness.name}');
      tester.view.physicalSize = const Size(390, 700);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await capture(key, 'terminal-subcommands-mobile-${brightness.name}');

      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDisableShadows = previousShadowSetting;
  });
}

class _CompletionPreviewSession extends SshConnection {
  _CompletionPreviewSession({required super.id, required super.host});
  @override
  Future<List<String>> listAvailableCommands() async => [
    'docker',
    'docker-compose',
  ];
  @override
  Future<List<RemotePathEntry>> listDirectory(String path) async => const [
    RemotePathEntry('Documents', isDirectory: true),
    RemotePathEntry('Downloads', isDirectory: true),
    RemotePathEntry('projects', isDirectory: true),
    RemotePathEntry('shared files', isDirectory: true),
    RemotePathEntry('README.md', isDirectory: false),
  ];
}
