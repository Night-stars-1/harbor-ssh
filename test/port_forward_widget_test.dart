import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/port_forward_manager.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/port_forward.dart';
import 'package:harbor_ssh/ui/port_forward_dialog.dart';
import 'package:harbor_ssh/ui/port_forward_panel.dart';
import 'package:harbor_ssh/ui/port_forward_preview.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'support.dart';

class _Handle implements PortForwardHandle {
  bool closed = false;
  @override
  int get port => 43210;
  @override
  Future<void> close() async {
    closed = true;
  }
}

class _Session extends SshConnection {
  _Session() : super(id: 'session', host: testHost) {
    status = ConnectionStatus.connected;
  }
  bool failStart = false;
  final handles = <_Handle>[];
  @override
  PortForwardManager get portForwards => _forwards;
  late final _forwards = PortForwardManager((_) async {
    if (failStart) throw StateError('端口已被占用');
    final handle = _Handle();
    handles.add(handle);
    return handle;
  });
}

const _rule = PortForwardRule(
  id: 'one',
  name: '数据库',
  type: PortForwardType.local,
  bindPort: 0,
  targetPort: 5432,
);

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

  Future<({_Session session, PortForwardStore store, MemoryStore memory})>
  setup(WidgetTester tester, {bool withRule = true}) async {
    final session = _Session();
    addTearDown(session.dispose);
    final memory = MemoryStore();
    final store = PortForwardStore(memory, testHost.id);
    if (withRule) await store.save([_rule]);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    PortForwardDialog(session: session, store: store),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return (session: session, store: store, memory: memory);
  }

  Future<void> enter(WidgetTester tester, String key, String value) async {
    final field = find.byKey(ValueKey(key));
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
  }

  testWidgets('start, actual port, disabled edits, close keeps running, stop', (
    tester,
  ) async {
    final context = await setup(tester);
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(find.text('运行中'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:43210'), findsOneWidget);
    expect(find.textContaining('127.0.0.1:5432'), findsOneWidget);
    if (find.byTooltip('编辑规则').evaluate().isNotEmpty) {
      for (final action in ['edit', 'delete']) {
        expect(
          tester
              .widget<IconButton>(find.byKey(ValueKey('$action-forward-one')))
              .onPressed,
          isNull,
        );
      }
    } else {
      await tester.tap(find.byTooltip('管理转发规则：数据库'));
      await tester.pumpAndSettle();
      for (final action in ['edit', 'delete']) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.byKey(ValueKey('$action-forward-one')),
              )
              .enabled,
          isFalse,
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(context.session.portForwards.activeCount, 1);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止'));
    await tester.pumpAndSettle();
    expect(context.session.handles.single.closed, isTrue);
    expect(find.text('已停止'), findsOneWidget);
  });
  testWidgets('browser action uses the desktop button and compact menu', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final opened = <Uri>[];

    Future<void> show(PortForwardRule rule, PortForwardState state) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: PortForwardRuleCard(
              rule: rule,
              state: state,
              connected: true,
              onEdit: (_) {},
              onDelete: (_) {},
              onStart: (_) {},
              onStop: (_) {},
              openBrowser: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(_rule, const PortForwardState());
    const button = ValueKey('browser-forward-one');
    expect(tester.widget<IconButton>(find.byKey(button)).onPressed, isNull);

    const running = PortForwardState(
      status: PortForwardStatus.running,
      port: 43210,
    );
    await show(_rule, running);
    await tester.tap(find.byKey(button));
    await tester.pump();
    expect(opened.single.toString(), 'http://127.0.0.1:43210/');

    tester.view.physicalSize = const Size(390, 900);
    await show(_rule, running);
    expect(find.byTooltip('浏览器打开'), findsNothing);
    expect(find.byKey(button), findsNothing);
    await tester.tap(find.byTooltip('管理转发规则：数据库'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PopupMenuItem<String>>(find.byKey(button)).enabled,
      isTrue,
    );
    await tester.tap(find.text('浏览器打开'));
    await tester.pumpAndSettle();
    expect(opened.length, 2);

    await show(_rule, const PortForwardState());
    await tester.tap(find.byTooltip('管理转发规则：数据库'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PopupMenuItem<String>>(find.byKey(button)).enabled,
      isFalse,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await show(
      const PortForwardRule(
        id: 'remote',
        name: '远程',
        type: PortForwardType.remote,
        bindPort: 8080,
        targetPort: 80,
      ),
      running,
    );
    await tester.tap(find.byTooltip('管理转发规则：远程'));
    await tester.pumpAndSettle();
    expect(find.text('浏览器打开'), findsNothing);
  });
  testWidgets('add local, edit remote, delete saved rule', (tester) async {
    final context = await setup(tester, withRule: false);
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await enter(tester, 'forward-name', '测试转发');
    await enter(tester, 'forward-target-port', '8080');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect((await context.store.load()).single.targetPort, 8080);
    await ruleAction(tester, '编辑规则');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('forward-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('远程转发').last);
    await tester.pumpAndSettle();
    expect(find.text('服务器监听地址'), findsOneWidget);
    expect(find.text('本机侧目标地址'), findsOneWidget);
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect((await context.store.load()).single.type, PortForwardType.remote);
    await ruleAction(tester, '删除规则');
    await tester.pumpAndSettle();
    expect(await context.store.load(), isEmpty);
  });
  testWidgets('validation rejects invalid port and unsafe SOCKS listener', (
    tester,
  ) async {
    await setup(tester, withRule: false);
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await enter(tester, 'forward-name', '代理');
    await enter(tester, 'forward-bind-port', '65536');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect(find.text('输入 0–65535'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('forward-type')));
    await tester.tap(find.byKey(const ValueKey('forward-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SOCKS5 代理').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('forward-target-port')), findsNothing);
    await enter(tester, 'forward-bind-port', '1080');
    await enter(tester, 'forward-bind-host', '0.0.0.0');
    await tester.tap(find.text('保存规则'));
    await tester.pumpAndSettle();
    expect(find.text('无认证代理只允许本机回环地址'), findsOneWidget);
  });
  testWidgets('failed start shows an inline alert and remains retryable', (
    tester,
  ) async {
    final context = await setup(tester);
    context.session.failStart = true;
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('端口已被占用'), findsOneWidget);
    final alert = tester.widget<Material>(
      find.byKey(const ValueKey('forward-inline-alert')),
    );
    expect(alert.shape, isA<RoundedRectangleBorder>());
    expect(alert.clipBehavior, Clip.antiAlias);
    expect(alert.color, const Color(0xFF585B86).withValues(alpha: 0.11));
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byKey(const ValueKey('forward-inline-alert')),
              matching: find.byType(ColoredBox),
            ),
          )
          .color,
      const Color(0xFF585B86),
    );
    context.session.failStart = false;
    await tester.tap(find.byTooltip('启动'));
    await tester.pumpAndSettle();
    expect(find.text('端口已被占用'), findsNothing);
    context.session.close();
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
    final toggle = tester.widget(
      find.byKey(const ValueKey('toggle-forward-one')),
    );
    expect(
      toggle is IconButton
          ? toggle.onPressed
          : (toggle as FilledButton).onPressed,
      isNull,
    );
  });
  testWidgets(
    'target connection error stays inline while the rule is running',
    (tester) async {
      final context = await setup(tester);
      await tester.tap(find.byTooltip('启动'));
      await tester.pumpAndSettle();

      context.session.portForwards.reportConnectionError(
        _rule.id,
        StateError('Connection refused'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('目标连接失败'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);

      context.session.portForwards.reportConnectionError(
        _rule.id,
        StateError('Connection refused'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('目标连接失败'), findsOneWidget);
    },
  );
  testWidgets('failed save retains existing rule', (tester) async {
    final context = await setup(tester);
    context.memory.failWrites = true;
    await ruleAction(tester, '删除规则');
    await tester.pumpAndSettle();
    expect(find.text('数据库'), findsOneWidget);
    expect(find.textContaining('保存失败'), findsOneWidget);
    context.memory.failWrites = false;
    await ruleAction(tester, '删除规则');
    await tester.pumpAndSettle();
    expect(find.text('数据库'), findsNothing);
  });
  testWidgets(
    'a running rule remains stoppable after another session deletes its saved rule',
    (tester) async {
      final context = await setup(tester);
      await tester.tap(find.byTooltip('启动'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await context.store.save([]);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('数据库'), findsOneWidget);
      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      expect(context.session.handles.single.closed, isTrue);
      expect(find.text('数据库'), findsNothing);
    },
  );
  testWidgets('terminal menu exposes port forwards only when wired', (
    tester,
  ) async {
    final session = _Session();
    addTearDown(session.dispose);
    String? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalOptionsButton(
            session: session,
            canForward: true,
            onSelected: (value) => action = value,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('终端选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('端口转发'));
    await tester.pumpAndSettle();
    expect(action, 'forward');
  });
  for (final preview in [
    portForwardPreview,
    portForwardDarkPreview,
    portForwardNarrowPreview,
  ]) {
    testWidgets('preview ${preview.toString()} fits 320px and large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(preview());
      await tester.pumpAndSettle();
      expect(find.byType(PortForwardPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'desktop retains two detailed cards while narrow windows use grouped rows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: PortForwardPanel(
              hostName: '开发服务器',
              rules: const [
                _rule,
                PortForwardRule(
                  id: 'two',
                  name: '开发代理',
                  type: PortForwardType.dynamic,
                  bindPort: 1080,
                ),
              ],
              stateFor: (_) => const PortForwardState(),
              connected: true,
              onAdd: () {},
              onEdit: (_) {},
              onDelete: (_) {},
              onStart: (_) {},
              onStop: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cards = find.byType(PortForwardRuleCard);
      final first = tester.getRect(cards.at(0));
      final second = tester.getRect(cards.at(1));
      expect(first.width, 480);
      expect(second.width, first.width);
      expect(second.height, first.height);
      expect(second.top, first.top);
      expect(second.left - first.right, 16);
      expect(find.byTooltip('编辑规则'), findsNWidgets(2));
      expect(find.byTooltip(RegExp('^管理转发规则：')), findsNothing);
      expect(
        tester.widget(find.byKey(const ValueKey('toggle-forward-one'))),
        isA<FilledButton>(),
      );
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(cards.at(1)).top,
        greaterThan(tester.getRect(cards.at(0)).bottom),
      );
      expect(tester.getRect(cards.at(0)).width, equals(350));
      expect(find.byTooltip('编辑规则'), findsNothing);
      expect(find.byTooltip(RegExp('^管理转发规则：')), findsNWidgets(2));
      expect(
        tester.widget(find.byKey(const ValueKey('toggle-forward-one'))),
        isA<IconButton>(),
      );
      expect(
        tester.getRect(cards.at(1)).top - tester.getRect(cards.at(0)).bottom,
        HarborShapes.listGap,
      );
      for (var index = 0; index < 2; index++) {
        final surface = tester.widget<Material>(
          find
              .descendant(of: cards.at(index), matching: find.byType(Material))
              .first,
        );
        expect(
          (surface.shape! as RoundedRectangleBorder).borderRadius,
          HarborShapes.listItem(HarborShapes.listSlot(index, 2)),
        );
        expect(tester.getRect(cards.at(index)).height, lessThan(140));
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('editor fits narrow window and keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: const Scaffold(body: PortForwardEditor()),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('forward-target-port')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
