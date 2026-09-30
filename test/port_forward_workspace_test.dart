import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/port_forward_manager.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/port_forward.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/port_forward_dialog.dart';
import 'package:harbor_ssh/ui/port_forward_workspace.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

const _rule = PortForwardRule(
  id: 'db',
  name: '数据库隧道',
  type: PortForwardType.local,
  bindPort: 15432,
  targetPort: 5432,
);
const _second = Host(
  id: 'other',
  name: '另一台主机',
  address: 'other.example.com',
  username: 'root',
);

class _Handle implements PortForwardHandle {
  bool closed = false;
  @override
  int get port => 15432;
  @override
  Future<void> close() async {
    closed = true;
  }
}

class _Session extends SshConnection {
  _Session({required super.id, required super.host}) {
    status = ConnectionStatus.connected;
  }
  void updateStatus(ConnectionStatus value) {
    status = value;
    notifyListeners();
  }

  final handle = _Handle();
  late final _manager = PortForwardManager((_) async => handle);
  @override
  PortForwardManager get portForwards => _manager;
}

class _Model extends WorkspaceModel {
  _Model(super.repository, this.items);
  final List<SshConnection> items;
  @override
  List<SshConnection> get sessions => items;
  @override
  SshConnection? get activeSession =>
      items.where((s) => s.id == activeSessionId).firstOrNull;
  @override
  void dispose() {
    for (final session in items) {
      session.dispose();
    }
    super.dispose();
  }
}

class _MoveFailStore extends MemoryStore {
  bool failSource = false;
  @override
  Future<void> write(String key, String value) async {
    if (failSource && key == 'harbor.port-forwards.v1.host-1') {
      throw StateError('disk unavailable');
    }
    await super.write(key, value);
  }
}

void main() {
  Future<void> ruleAction(
    WidgetTester tester,
    String action, {
    Finder? card,
  }) async {
    final inlineActions = find.byTooltip(action);
    final inline = card == null
        ? inlineActions.first
        : find.descendant(of: card, matching: inlineActions);
    if (inline.evaluate().isNotEmpty) {
      await tester.ensureVisible(inline);
      await tester.tap(inline);
      await tester.pumpAndSettle();
      return;
    }
    final menus = find.byTooltip(RegExp('^管理转发规则：'));
    final menu = card == null
        ? menus.first
        : find.descendant(of: card, matching: menus);
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 1280.0]) {
    testWidgets('independent home forwarding destination at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = memoryRepository();
      await repository.saveHosts([testHost]);
      await PortForwardStore(repository.preferences, testHost.id).save([_rule]);
      final session = _Session(id: 'one', host: testHost);
      final model = _Model(repository, [session]);
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey(
            width < 900 ? 'mobile-port-forwards' : 'sidebar-port-forwards',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.showingPortForwards, isTrue);
      expect(find.byType(PortForwardWorkspace), findsOneWidget);
      expect(find.byType(PortForwardDialog), findsNothing);
      expect(find.text('数据库隧道'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      if (width < 900) {
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          3,
        );
      }
      await tester.tap(find.byTooltip('启动'));
      await tester.pumpAndSettle();
      model.filter(users: true);
      await tester.pumpAndSettle();
      expect(session.portForwards.activeCount, 1);
      model.showPortForwards();
      await tester.pumpAndSettle();
      expect(find.text('运行中'), findsOneWidget);
      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      expect(session.handle.closed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  Future<void> page(
    WidgetTester tester, {
    required MemoryStore preferences,
    List<Host> hosts = const [testHost, _second],
    List<SshConnection> sessions = const [],
    Future<SshConnection?> Function(Host)? onConnect,
    String? requestedSessionId,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: PortForwardWorkspace(
            hosts: hosts,
            sessions: sessions,
            preferences: preferences,
            onConnect: onConnect ?? (_) async => null,
            onHosts: () {},
            requestedSessionId: requestedSessionId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key, String label) async {
    final field = find.byKey(ValueKey(key));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).hitTestable().last);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String key, String value) async {
    final field = find.byKey(ValueKey(key));
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
    await tester.pumpAndSettle();
  }

  testWidgets('minimal empty page keeps only heading action and icon caption', (
    tester,
  ) async {
    final failed = SshConnection(id: 'failed', host: testHost)
      ..status = ConnectionStatus.failed
      ..error = 'SSHAuthAbortError(Connection closed before authentication)';
    addTearDown(failed.dispose);
    await page(tester, preferences: MemoryStore(), sessions: [failed]);
    expect(find.text('尚未添加转发规则'), findsOneWidget);
    expect(find.text('SSH 主机'), findsNothing);
    expect(find.text('转发规则'), findsNothing);
    expect(find.text('连接主机'), findsNothing);
    expect(find.textContaining('认证'), findsNothing);
    expect(find.text('本地转发'), findsNothing);
    expect(find.textContaining('保存在此设备'), findsNothing);
    final add = find.byKey(const ValueKey('add-forward'));
    expect(tester.getSize(add).width, lessThan(200));
    expect(tester.getTopLeft(add).dy, lessThan(80));
    expect(
      tester.getTopLeft(add).dy,
      lessThan(tester.getTopLeft(find.text('尚未添加转发规则')).dy),
    );
  });

  testWidgets('add chooses host and forwarding type without connecting', (
    tester,
  ) async {
    final preferences = MemoryStore();
    var connections = 0;
    await page(
      tester,
      preferences: preferences,
      onConnect: (_) async {
        connections++;
        return null;
      },
    );
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await choose(tester, 'forward-host', _second.name);
    await enter(tester, 'forward-name', '远程开发');
    await choose(tester, 'forward-type', '远程转发');
    await enter(tester, 'forward-target-port', '8080');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect(await PortForwardStore(preferences, testHost.id).load(), isEmpty);
    final saved = (await PortForwardStore(
      preferences,
      _second.id,
    ).load()).single;
    expect(saved.type, PortForwardType.remote);
    expect(saved.targetPort, 8080);
    expect(find.text(_second.name), findsOneWidget);
    expect(connections, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rules from all hosts remain visible and deletions are host scoped',
    (tester) async {
      final preferences = MemoryStore();
      await PortForwardStore(preferences, testHost.id).save([_rule]);
      await PortForwardStore(preferences, _second.id).save([_rule]);
      await page(tester, preferences: preferences);
      expect(find.text('数据库隧道'), findsNWidgets(2));
      final card = find.byKey(const ValueKey('forward-rule-other-db-null'));
      await ruleAction(tester, '删除规则', card: card);
      expect(
        await PortForwardStore(preferences, testHost.id).load(),
        hasLength(1),
      );
      expect(await PortForwardStore(preferences, _second.id).load(), isEmpty);
      expect(find.text('数据库隧道'), findsOneWidget);
    },
  );

  testWidgets(
    'editing moves a stopped rule between hosts and updates its type',
    (tester) async {
      final preferences = MemoryStore();
      await PortForwardStore(preferences, testHost.id).save([_rule]);
      await page(tester, preferences: preferences);
      await ruleAction(tester, '编辑规则');
      await tester.pumpAndSettle();
      await choose(tester, 'forward-host', _second.name);
      await choose(tester, 'forward-type', 'SOCKS5 代理');
      await tester.tap(find.text('保存规则'));
      await tester.pumpAndSettle();
      expect(await PortForwardStore(preferences, testHost.id).load(), isEmpty);
      final saved = (await PortForwardStore(
        preferences,
        _second.id,
      ).load()).single;
      expect(saved.type, PortForwardType.dynamic);
      expect(saved.bindPort, _rule.bindPort);
      expect(find.text(_second.name), findsOneWidget);
    },
  );

  testWidgets('failed host move rolls target back and retains original rule', (
    tester,
  ) async {
    final preferences = _MoveFailStore();
    await PortForwardStore(preferences, testHost.id).save([_rule]);
    await page(tester, preferences: preferences);
    await ruleAction(tester, '编辑规则');
    await tester.pumpAndSettle();
    await choose(tester, 'forward-host', _second.name);
    preferences.failSource = true;
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect(
      await PortForwardStore(preferences, testHost.id).load(),
      hasLength(1),
    );
    expect(await PortForwardStore(preferences, _second.id).load(), isEmpty);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('数据库隧道'), findsOneWidget);
  });

  testWidgets('start connects the rule host and waits for authentication', (
    tester,
  ) async {
    final preferences = MemoryStore();
    await PortForwardStore(preferences, _second.id).save([_rule]);
    final session = _Session(id: 'new', host: _second)
      ..status = ConnectionStatus.closed;
    addTearDown(session.dispose);
    Host? requested;
    await page(
      tester,
      preferences: preferences,
      sessions: [session],
      onConnect: (host) async {
        requested = host;
        session.updateStatus(ConnectionStatus.connecting);
        return session;
      },
    );
    await tester.tap(find.byTooltip('启动'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(requested, _second);
    expect(session.portForwards.activeCount, 0);
    expect(find.byTooltip('正在连接…'), findsOneWidget);
    expect(find.text('正在连接'), findsOneWidget);
    session.updateStatus(ConnectionStatus.connected);
    await tester.pumpAndSettle();
    expect(session.portForwards.activeCount, 1);
    expect(find.text('运行中'), findsOneWidget);
    await tester.tap(find.byTooltip('停止'));
    await tester.pumpAndSettle();
    expect(session.handle.closed, isTrue);
  });

  testWidgets(
    'changed host address never reuses an old connection with the same id',
    (tester) async {
      final preferences = MemoryStore();
      await PortForwardStore(preferences, testHost.id).save([_rule]);
      final stale = _Session(
        id: 'stale',
        host: const Host(
          id: 'host-1',
          name: '旧主机',
          address: 'old.example.com',
          username: 'deploy',
        ),
      );
      addTearDown(stale.dispose);
      Host? requested;
      await page(
        tester,
        preferences: preferences,
        sessions: [stale],
        onConnect: (host) async {
          requested = host;
          return null;
        },
      );
      await tester.tap(find.byTooltip('启动'));
      await tester.pumpAndSettle();
      expect(requested, testHost);
      expect(stale.portForwards.activeCount, 0);
    },
  );

  testWidgets('cancelled login leaves saved rule stopped and retryable', (
    tester,
  ) async {
    final preferences = MemoryStore();
    await PortForwardStore(preferences, testHost.id).save([_rule]);
    var calls = 0;
    await page(
      tester,
      preferences: preferences,
      onConnect: (_) async {
        calls++;
        return null;
      },
    );
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('已停止'), findsOneWidget);
    final toggle = tester.widget(
      find.byKey(const ValueKey('toggle-forward-db')),
    );
    expect(
      toggle is IconButton
          ? toggle.onPressed
          : (toggle as FilledButton).onPressed,
      isNotNull,
    );
    expect(
      await PortForwardStore(preferences, testHost.id).load(),
      hasLength(1),
    );
  });

  testWidgets('authentication failure stays on the rule and permits retry', (
    tester,
  ) async {
    final preferences = MemoryStore();
    await PortForwardStore(preferences, testHost.id).save([_rule]);
    final session = _Session(id: 'retry', host: testHost)
      ..status = ConnectionStatus.closed;
    addTearDown(session.dispose);
    var calls = 0;
    await page(
      tester,
      preferences: preferences,
      sessions: [session],
      onConnect: (_) async {
        calls++;
        session.error = calls == 1 ? '认证失败' : null;
        session.updateStatus(
          calls == 1 ? ConnectionStatus.failed : ConnectionStatus.connected,
        );
        return session;
      },
    );
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('认证失败'), findsOneWidget);
    expect(session.portForwards.activeCount, 0);
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('认证失败'), findsNothing);
    expect(session.portForwards.activeCount, 1);
  });

  testWidgets('disposing while authentication waits never starts a tunnel', (
    tester,
  ) async {
    final preferences = MemoryStore();
    await PortForwardStore(preferences, testHost.id).save([_rule]);
    final session = _Session(id: 'waiting', host: testHost)
      ..status = ConnectionStatus.connecting;
    addTearDown(session.dispose);
    await page(tester, preferences: preferences, sessions: [session]);
    await tester.tap(find.byTooltip('启动'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    session.updateStatus(ConnectionStatus.connected);
    await tester.pump();
    expect(session.portForwards.activeCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('active rules on multiple sessions remain separately stoppable', (
    tester,
  ) async {
    final preferences = MemoryStore();
    final a = _Session(id: 'a', host: testHost);
    final b = _Session(id: 'b', host: testHost);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await a.portForwards.start(_rule);
    await b.portForwards.start(_rule);
    await page(tester, preferences: preferences, sessions: [a, b]);
    expect(find.text('运行中'), findsNWidgets(2));
    final card = find.byKey(const ValueKey('forward-rule-host-1-db-b'));
    final stop = find.descendant(of: card, matching: find.byTooltip('停止'));
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    await tester.pumpAndSettle();
    expect(a.portForwards.activeCount, 1);
    expect(b.portForwards.activeCount, 0);
  });

  testWidgets(
    'session shortcut preselects the host in the add dialog and can repeat',
    (tester) async {
      final repository = memoryRepository();
      final a = _Session(id: 'a', host: testHost);
      final b = _Session(id: 'b', host: _second);
      final model = _Model(repository, [a, b]);
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      for (final session in [b, a, b]) {
        model.showPortForwards(sessionId: session.id);
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加规则'));
        await tester.pumpAndSettle();
        final field = tester.widget<DropdownMenuFormField<String>>(
          find.byKey(const ValueKey('forward-host')),
        );
        expect(field.initialValue, session.host.id);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      model.showSettings();
      model.closeSettings();
      await tester.pumpAndSettle();
      expect(model.showingPortForwards, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'minimal page and host/type editor fit 320px at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await page(tester, preferences: MemoryStore());
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('添加规则'));
      await tester.pumpAndSettle();
      await choose(tester, 'forward-host', _second.name);
      await choose(tester, 'forward-type', 'SOCKS5 代理');
      await enter(tester, 'forward-name', '开发代理');
      await tester.tap(find.text('保存规则'));
      await tester.pumpAndSettle();
      expect(find.text('开发代理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing a selection menu with Escape preserves the rule draft', (
    tester,
  ) async {
    final preferences = MemoryStore();
    await page(tester, preferences: preferences);
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await choose(tester, 'forward-host', _second.name);
    await choose(tester, 'forward-type', 'SOCKS5 代理');
    await enter(tester, 'forward-name', '保留草稿');
    final field = find.byKey(const ValueKey('forward-type'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('添加转发规则'), findsOneWidget);
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    final rule = (await PortForwardStore(
      preferences,
      _second.id,
    ).load()).single;
    expect(rule.name, '保留草稿');
    expect(rule.type, PortForwardType.dynamic);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty forwarding tab links to host management', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PortForwardWorkspace(
            hosts: const [],
            sessions: const [],
            preferences: MemoryStore(),
            onConnect: (_) async => null,
            onHosts: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理连接'));
    expect(opened, isTrue);
    expect(find.text('连接主机'), findsNothing);
  });
  testWidgets(
    'mobile session shortcut closes the session sheet and opens the tab',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = memoryRepository();
      await repository.saveHosts([testHost]);
      final model = _Model(repository, [_Session(id: 'a', host: testHost)]);
      await tester.pumpWidget(HarborApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('host-sessions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('管理会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '端口转发'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-session-list')), findsNothing);
      expect(find.byType(PortForwardWorkspace), findsOneWidget);
      expect(model.portForwardSessionId, 'a');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('multiple sessions fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repository = memoryRepository();
    await repository.saveHosts([testHost]);
    final model = _Model(repository, [
      _Session(id: 'a', host: testHost),
      _Session(id: 'b', host: testHost),
    ])..showPortForwards();
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'home destinations are mutually exclusive and preserve terminal session',
    () {
      final model = WorkspaceModel(memoryRepository());
      addTearDown(model.dispose);
      model.activeSessionId = 'terminal';
      model.showFiles();
      model.showPortForwards(sessionId: 'terminal');
      expect(model.activeSessionId, 'terminal');
      expect(model.showingFiles, isFalse);
      model.showSettings();
      model.closeSettings();
      expect(model.showingPortForwards, isTrue);
      model.selectSession('terminal');
      expect(model.showingPortForwards, isFalse);
      model.showPortForwards();
      model.filter(users: true);
      expect(model.showingPortForwards, isFalse);
      model.showPortForwards();
      model.showFiles();
      expect(model.showingPortForwards, isFalse);
    },
  );
}
