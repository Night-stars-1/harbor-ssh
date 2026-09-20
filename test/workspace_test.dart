import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:xterm/xterm.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  testWidgets('桌面分屏与侧栏会话选择联动，返回首页再打开保留分屏和终端状态', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = SshConnection(id: 'split-first', host: testHost)
      ..status = ConnectionStatus.connected;
    final second = SshConnection(id: 'split-second', host: testHost)
      ..status = ConnectionStatus.connected;
    final third = SshConnection(id: 'split-third', host: testHost)
      ..status = ConnectionStatus.connected;
    final model = _SidebarWorkspaceModel([first, second, third]);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-split-menu-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左右分屏'));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('session-menu-split-third')));
    await tester.pumpAndSettle();
    Finder terminal(SshConnection session) => find.byWidgetPredicate(
      (widget) => widget is TerminalView && widget.terminal == session.terminal,
    );
    expect(terminal(first), findsOneWidget);
    expect(terminal(third), findsOneWidget);
    expect(terminal(second), findsNothing);
    final firstState = tester.state(terminal(first));
    final thirdState = tester.state(terminal(third));
    await tester.tap(find.byKey(const ValueKey('settings-button')));
    await tester.pumpAndSettle();
    expect(find.text('云同步'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(TerminalView), findsNothing);
    expect(model.activeSession, third);
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    expect(tester.state(terminal(first)), same(firstState));
    expect(tester.state(terminal(third)), same(thirdState));
    expect(first.status, ConnectionStatus.connected);

    model.filter();
    await tester.pumpAndSettle();
    expect(find.byType(TerminalView), findsNothing);
    model.selectSession(first.id);
    await tester.pumpAndSettle();
    expect(tester.state(terminal(first)), same(firstState));
    expect(tester.state(terminal(third)), same(thirdState));
    expect(model.activeSession, first);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('侧栏可折叠和拖动，恢复宽度并保留终端状态', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'resize', host: testHost)
      ..status = ConnectionStatus.connected;
    session.terminal.write('retained output');
    final model = _SidebarWorkspaceModel([session]);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('workspace-sidebar'));
    final handle = find.byKey(const ValueKey('sidebar-resize-handle'));
    final toggle = find.byKey(const ValueKey('sidebar-toggle'));
    final terminalState = tester.state(find.byType(TerminalView));
    expect(tester.getSize(sidebar).width, 264);
    await tester.drag(handle, const Offset(100, 0));
    await tester.pumpAndSettle();
    final resizedWidth = tester.getSize(sidebar).width;
    expect(resizedWidth, greaterThan(264));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 80);
    expect(handle, findsNothing);
    expect(tester.state(find.byType(TerminalView)), same(terminalState));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, resizedWidth);
    expect(tester.state(find.byType(TerminalView)), same(terminalState));
    expect(session.status, ConnectionStatus.connected);
    expect(session.terminal.buffer.lines[0].getText(), 'retained output');
    await tester.drag(handle, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 400);
    tester.view.physicalSize = const Size(900, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 360);
    await tester.drag(handle, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 220);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: sidebar, matching: find.byIcon(Icons.star_rounded)),
    );
    await tester.pumpAndSettle();
    expect(model.favoritesOnly, isTrue);
    await tester.tap(
      find.descendant(
        of: sidebar,
        matching: find.byIcon(Icons.vpn_key_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(model.showingUsers, isTrue);
    await tester.tap(
      find.descendant(of: sidebar, matching: find.byIcon(Icons.dns_rounded)),
    );
    await tester.pumpAndSettle();
    expect(model.showingUsers, isFalse);
    expect(model.favoritesOnly, isFalse);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(sidebar, findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 80);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 220);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('侧边栏右键仅操作目标会话，断开保留记录，关闭沿用确认', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = SshConnection(id: 'first', host: testHost)
      ..status = ConnectionStatus.connected;
    final second = SshConnection(id: 'second', host: testHost)
      ..status = ConnectionStatus.connected;
    second.terminal.write('retained output');
    final model = _SidebarWorkspaceModel([first, second]);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    Future<void> openMenu(String id) async {
      await tester.tap(
        find.byKey(ValueKey('session-menu-$id')),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }

    await openMenu('second');
    expect(model.activeSessionId, 'first');
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    expect(second.status, ConnectionStatus.closed);
    expect(first.status, ConnectionStatus.connected);
    expect(model.sessions.length, 2);
    expect(second.terminal.buffer.lines[0].getText(), 'retained output');
    await openMenu('second');
    expect(
      tester
          .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, '断开连接'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('关闭会话'));
    await tester.pumpAndSettle();
    expect(model.sessions, [first]);
    expect(model.activeSessionId, 'first');
    await openMenu('first');
    await tester.tap(find.text('关闭会话'));
    await tester.pumpAndSettle();
    expect(find.text('关闭终端？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(model.sessions, [first]);
    await openMenu('first');
    await tester.tap(find.text('关闭会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开并关闭'));
    await tester.pumpAndSettle();
    expect(model.sessions, isEmpty);
    expect(find.byKey(const ValueKey('session-menu-first')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('移动端终端信息与菜单放在 Header，缩放后操作仍有效', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SshConnection(id: 'header-test', host: testHost)
      ..status = ConnectionStatus.connected;
    addTearDown(session.dispose);
    await tester.pumpWidget(HarborApp(model: _TerminalWorkspaceModel(session)));
    await tester.pumpAndSettle();
    final header = find.byType(AppBar);
    expect(find.text(testHost.name), findsOneWidget);
    expect(
      find.descendant(of: header, matching: find.text(testHost.name)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byIcon(Icons.circle)),
      findsOneWidget,
    );
    expect(find.byTooltip('终端选项'), findsOneWidget);
    expect(
      find.descendant(of: header, matching: find.byTooltip('终端选项')),
      findsOneWidget,
    );
    final originalFontSize = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .textStyle
        .fontSize;
    await tester.tap(find.byTooltip('终端选项'));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    await tester.tap(find.text('增大字体'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize,
      originalFontSize + 1,
    );
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('终端选项'), findsOneWidget);
    await tester.tap(find.byTooltip('终端选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缩小字体'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize,
      originalFontSize,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final size in [
    const Size(1280, 800),
    const Size(800, 900),
    const Size(390, 844),
    const Size(320, 640),
  ]) {
    testWidgets('主机列表与表单适配 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = memoryRepository();
      await repository.saveUsers([
        const SshUser(id: 'deploy', name: 'Deploy', username: 'deploy'),
      ]);
      final model = WorkspaceModel(repository);
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      if (size.width < 900) {
        expect(find.text('连接工作空间'), findsNothing);
        expect(find.textContaining('台主机 ·'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('收藏'),
          ),
          findsNothing,
        );
        await tester.tap(find.byTooltip('收藏'));
        await tester.pumpAndSettle();
        expect(model.favoritesOnly, isTrue);
        expect(
          find.descendant(of: find.byType(AppBar), matching: find.text('收藏')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('显示全部连接'));
        await tester.pumpAndSettle();
        expect(model.favoritesOnly, isFalse);
        for (final tab in ['凭证', '连接']) {
          await tester.tap(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.text(tab),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: find.byType(AppBar), matching: find.text(tab)),
            findsOneWidget,
          );
        }
      } else {
        expect(find.text('连接工作空间'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tap(
        size.width < 900
            ? find.byType(FloatingActionButton)
            : find.text('新建连接'),
      );
      await tester.pumpAndSettle();
      expect(find.text('主机地址'), findsOneWidget);
      final save = find.text('保存连接');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('请填写此项'), findsWidgets);
      await tester.enterText(
        find.widgetWithText(TextFormField, '连接名称'),
        'My server',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '主机地址'),
        'localhost',
      );
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(model.hosts.single.name, 'My server');
      expect(await repository.credentials(model.hosts.single.id), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('已保存主机卡片可搜索，窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    await tester.pumpWidget(HarborApp(model: WorkspaceModel(repository)));
    await tester.pumpAndSettle();
    expect(find.text(testHost.name), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'no-match');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('收藏为空与搜索无结果区分，清除筛选仍留在收藏', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final model = WorkspaceModel(repository);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    model.filter(favorites: true);
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏连接'), findsOneWidget);
    expect(find.text('没有匹配的连接'), findsNothing);
    expect(find.text('清除筛选'), findsNothing);
    await model.toggleFavorite(model.hosts.single);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'no-match');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的收藏连接'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(model.favoritesOnly, isTrue);
    expect(model.query, isEmpty);
    expect(find.text(testHost.name), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('凭证页可保存，新建连接时能选用', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = WorkspaceModel(memoryRepository());
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('凭证'));
    await tester.pumpAndSettle();
    expect(find.text('先保存一份凭证'), findsOneWidget);
    await tester.tap(find.text('新建凭证'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '显示名称'), '生产部署');
    await tester.ensureVisible(find.text('生成密钥'));
    await tester.tap(find.text('生成密钥'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存凭证'));
    await tester.tap(find.text('保存凭证'));
    await tester.pumpAndSettle();
    expect(model.users.single.authMethod, AuthMethod.privateKey);
    expect(find.text('生产部署'), findsOneWidget);
    await tester.tap(find.text('所有连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建连接'));
    await tester.pumpAndSettle();
    expect(find.text('凭证'), findsWidgets);
    final credentialSelector = find.byType(DropdownMenuFormField<String>);
    await tester.ensureVisible(credentialSelector);
    await tester.tap(credentialSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生产部署').last);
    await tester.pumpAndSettle();
    expect(find.text('生产部署'), findsWidgets);
    expect(find.widgetWithText(TextFormField, '用户名'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '密码'), findsNothing);
    expect(find.text('使用已保存的私钥'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _TerminalWorkspaceModel extends WorkspaceModel {
  _TerminalWorkspaceModel(this.session) : super(memoryRepository());
  final SshConnection session;
  @override
  SshConnection? get activeSession => session;
}

class _SidebarWorkspaceModel extends WorkspaceModel {
  _SidebarWorkspaceModel(this.items) : super(memoryRepository()) {
    activeSessionId = items.first.id;
    for (final session in items) {
      session.addListener(notifyListeners);
    }
  }
  final List<SshConnection> items;
  @override
  List<SshConnection> get sessions => List.unmodifiable(items);
  @override
  SshConnection? get activeSession {
    for (final session in items) {
      if (session.id == activeSessionId) return session;
    }
    return null;
  }

  @override
  void closeSession(SshConnection session) {
    items.remove(session);
    session.removeListener(notifyListeners);
    session.dispose();
    if (activeSessionId == session.id) activeSessionId = items.lastOrNull?.id;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in items) {
      session.removeListener(notifyListeners);
      session.dispose();
    }
    super.dispose();
  }
}
