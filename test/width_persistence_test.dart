import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/appearance.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/terminal_ai_panel.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/terminal_workspace.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';
import 'package:xterm/xterm.dart';

import 'support.dart';

void main() {
  testWidgets('拖动侧栏宽度只在结束时落盘，缩窄窗口后恢复，重启还原', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = MemoryStore();
    final first = _session('sidebar');
    final model = _SessionWorkspaceModel([first], preferences);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();

    final sidebar = find.byKey(const ValueKey('workspace-sidebar'));
    final handle = find.byKey(const ValueKey('sidebar-resize-handle'));
    final terminalState = tester.state(find.byType(TerminalView));
    final initial = tester.getSize(sidebar).width;
    expect(initial, greaterThan(0));
    expect(await preferences.read('harbor.appearance.v1'), isNull);

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(1000, 0));
    await tester.pump();
    expect(await preferences.read('harbor.appearance.v1'), isNull);
    final widened = tester.getSize(sidebar).width;
    expect(widened, greaterThan(initial));
    await gesture.up();
    await tester.pumpAndSettle();
    final settled = tester.getSize(sidebar).width;
    expect(settled, closeTo(widened, .01));
    expect(
      (await WorkspaceModel.readAppearance(preferences))!.sidebarWidth,
      closeTo(settled, .01),
    );
    expect(tester.state(find.byType(TerminalView)), same(terminalState));

    // A constrained window clamps the rendered width but keeps the choice.
    tester.view.physicalSize = const Size(900, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, lessThan(settled));
    expect(
      (await WorkspaceModel.readAppearance(preferences))!.sidebarWidth,
      closeTo(settled, .01),
    );
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, closeTo(settled, .01));
    expect(tester.state(find.byType(TerminalView)), same(terminalState));

    // Accessibility nudges settle immediately instead of waiting for a drag.
    tester
        .widget<Semantics>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == '调整侧栏宽度',
          ),
        )
        .properties
        .onDecrease!
        .call();
    await tester.pumpAndSettle();
    final nudged = tester.getSize(sidebar).width;
    expect(nudged, lessThan(settled));
    expect(
      (await WorkspaceModel.readAppearance(preferences))!.sidebarWidth,
      closeTo(nudged, .01),
    );

    // Restart: a fresh model, window and session read the saved width.
    await tester.pumpWidget(const SizedBox.shrink());
    final restarted = _session('sidebar-restarted');
    final model2 = _SessionWorkspaceModel([restarted], preferences);
    await tester.pumpWidget(HarborApp(model: model2));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, closeTo(nudged, .01));
    expect(restarted.terminal.buffer.getText(), contains('sidebar-restarted'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('布局大小保存失败时保留本地宽度并提示，不静默', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = MemoryStore();
    final model = _SessionWorkspaceModel([_session('save-fail')], preferences);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();

    final sidebar = find.byKey(const ValueKey('workspace-sidebar'));
    final handle = find.byKey(const ValueKey('sidebar-resize-handle'));
    final before = tester.getSize(sidebar).width;
    preferences.failWrites = true;

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    final widened = tester.getSize(sidebar).width;
    expect(widened, greaterThan(before));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('布局大小保存失败，请重试'), findsOneWidget);
    // The chosen width stays on screen; only the stored preference failed.
    expect(tester.getSize(sidebar).width, closeTo(widened, .01));
    expect(await preferences.read('harbor.appearance.v1'), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖动 AI 面板宽度只在结束时保存，重启后恢复且不重建终端', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = MemoryStore();
    final first = _session('ai');
    final model = _SessionWorkspaceModel([first], preferences);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('terminal-ai')));
    await tester.pumpAndSettle();
    final panel = find.byType(TerminalAiPanel);
    expect(panel, findsOneWidget);
    final handle = find.byKey(const ValueKey('ai-panel-resize-handle'));
    final terminalState = tester.state(find.byType(TerminalView));
    final paneWidth = tester.getSize(find.byType(TerminalPane)).width;
    final automatic = (paneWidth * .4).clamp(320.0, 440.0);
    expect(tester.getSize(panel).width, closeTo(automatic, .01));
    expect(await preferences.read('harbor.appearance.v1'), isNull);

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(await preferences.read('harbor.appearance.v1'), isNull);
    final widened = tester.getSize(panel).width;
    expect(widened, greaterThan(automatic));
    await gesture.up();
    await tester.pumpAndSettle();
    final settled = tester.getSize(panel).width;
    expect(settled, closeTo(widened, .01));
    expect(
      (await WorkspaceModel.readAppearance(preferences))!.aiPanelWidth,
      closeTo(settled, .01),
    );
    expect(tester.state(find.byType(TerminalView)), same(terminalState));
    expect(first.terminal.buffer.getText(), contains('ai output'));

    await tester.pumpWidget(const SizedBox.shrink());
    final restarted = _session('ai-restarted');
    final model2 = _SessionWorkspaceModel([restarted], preferences);
    await tester.pumpWidget(HarborApp(model: model2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-ai')));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, closeTo(settled, .01));
    expect(restarted.terminal.buffer.getText(), contains('ai-restarted'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AI 面板记录一次异步恢复，不覆盖拖动或邻居宽度', (tester) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final resized = <double?>[];
    Future<void> layout({
      double width = 1200,
      double? preferred,
      int revision = 0,
    }) => tester.pumpWidget(
      _AiLayoutHarness(
        width: width,
        preferred: preferred,
        revision: revision,
        resized: resized,
      ),
    );
    double panelWidth() =>
        tester.getSize(find.byKey(const ValueKey('ai-layout-body'))).width;

    await layout(preferred: 600);
    expect(panelWidth(), 600);

    // Another pane settling the shared preference must not resize this one.
    await layout(preferred: 500);
    expect(panelWidth(), 600);
    // A restore from disk arrives with a new revision and applies once.
    await layout(preferred: 500, revision: 1);
    expect(panelWidth(), 500);
    await layout(preferred: 640, revision: 2);
    expect(panelWidth(), 640);
    await layout(preferred: 500, revision: 2);
    expect(panelWidth(), 640);
    expect(resized, isEmpty);

    // Shrinking clamps the drawing but keeps the preferred width.
    await layout(width: 800, preferred: 500, revision: 2);
    expect(panelWidth(), closeTo(800 - 8 - 280, .01));
    await layout(width: 1200, preferred: 500, revision: 2);
    expect(panelWidth(), 640);
    expect(resized, isEmpty);

    // A restore that lands mid-drag never yanks the handle.
    final handle = find.byKey(const ValueKey('ai-panel-resize-handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    final dragged = panelWidth();
    expect(dragged, greaterThan(640));
    await layout(width: 1200, preferred: 400, revision: 3);
    expect(panelWidth(), closeTo(dragged, .01));
    expect(resized, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(resized, hasLength(1));
    expect(resized.single, closeTo(dragged, .01));

    // Reset returns to the automatic share and clears the saved width.
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(resized, hasLength(2));
    expect(resized.last, isNull);
    final automaticAgain = panelWidth();
    expect(automaticAgain, lessThan(dragged));
    expect(automaticAgain, inInclusiveRange(320, 440));

    // Accessibility nudges settle immediately.
    tester.widget<Semantics>(find.byWidgetPredicate(
      (widget) =>
          widget is Semantics && widget.properties.label == '调整 AI 面板宽度',
    )).properties.onIncrease!.call();
    await tester.pump();
    expect(resized, hasLength(3));
    expect(resized.last, greaterThan(automaticAgain));
    expect(panelWidth(), resized.last);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分屏比例在拖动结束时保存，重启后新分屏沿用并保留终端', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = MemoryStore();
    preferences.values['harbor.appearance.v1'] = jsonEncode(
      const AppearancePreferences(terminalSplitRatio: .7).toJson(),
    );
    final first = _session('ratio-a');
    final second = _session('ratio-b');
    final model = _SessionWorkspaceModel([first, second], preferences);
    await tester.pumpWidget(HarborApp(model: model));
    await tester.pumpAndSettle();

    double share() {
      final available =
          tester.getSize(find.byType(TerminalWorkspace)).width - 16 - 12;
      return tester
              .getRect(find.byKey(const ValueKey('terminal-region-0')))
              .width /
          available;
    }

    final terminalState = tester.state(find.byType(TerminalView));
    await _split(tester, 0, '左右分屏');
    expect(share(), closeTo(.7, .02));

    final handle = find.byKey(const ValueKey('terminal-split-handle-0'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(share(), lessThan(.7));
    final dragged = share();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      (await WorkspaceModel.readAppearance(preferences))!.terminalSplitRatio,
      closeTo(dragged, .02),
    );
    expect(
      tester.state(
        find.byWidgetPredicate(
          (widget) => widget is TerminalView && widget.terminal == first.terminal,
        ),
      ),
      same(terminalState),
    );

    // Recreating the split uses the settled ratio as the remembered default.
    await _split(tester, 0, '取消分屏');
    await _split(tester, 0, '左右分屏');
    expect(share(), closeTo(dragged, .02));

    await tester.pumpWidget(const SizedBox.shrink());
    final restartedFirst = _session('ratio-a2');
    final restartedSecond = _session('ratio-b2');
    final restarted = _SessionWorkspaceModel(
      [restartedFirst, restartedSecond],
      preferences,
    );
    await tester.pumpWidget(HarborApp(model: restarted));
    await tester.pumpAndSettle();
    await _split(tester, 0, '左右分屏');
    expect(share(), closeTo(dragged, .02));
    expect(restartedFirst.terminal.buffer.getText(), contains('ratio-a2'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分屏比例拖动只提交一次，取消分屏后新分屏沿用新默认值', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sessions = [_session('split-a'), _session('split-b')];
    final saved = <double>[];
    await tester.pumpWidget(
      _SplitHarness(sessions: sessions, ratio: .7, onRatio: saved.add),
    );
    await tester.pumpAndSettle();
    await _split(tester, 0, '左右分屏');

    Rect region(int side) =>
        tester.getRect(find.byKey(ValueKey('terminal-region-$side')));
    // The split layout is the workspace surface after its desktop padding.
    double share() {
      final available =
          tester.getSize(find.byType(TerminalWorkspace)).width - 16 - 12;
      return region(0).width / available;
    }
    expect(share(), closeTo(.7, .01));
    final firstState = tester.state(
      find.byWidgetPredicate(
        (widget) =>
            widget is TerminalView && widget.terminal == sessions[0].terminal,
      ),
    );

    final handle = find.byKey(const ValueKey('terminal-split-handle-0'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(saved, isEmpty);
    expect(share(), lessThan(.7));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    final dragged = saved.single;
    expect(dragged, lessThan(.7));
    expect(share(), closeTo(dragged, .01));

    // Recreating the split uses the settled ratio as the new default.
    await _split(tester, 0, '取消分屏');
    await _split(tester, 0, '左右分屏');
    expect(share(), closeTo(dragged, .01));
    expect(
      tester.state(
        find.byWidgetPredicate(
          (widget) =>
              widget is TerminalView && widget.terminal == sessions[0].terminal,
        ),
      ),
      same(firstState),
    );

    // Double-clicking the divider resets to an even split and saves it.
    final resetHandle = find.byKey(const ValueKey('terminal-split-handle-0'));
    await tester.tap(resetHandle);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(resetHandle);
    await tester.pumpAndSettle();
    expect(saved.last, .5);
    expect(share(), closeTo(.5, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

SshConnection _session(String id) {
  final session = SshConnection(id: id, host: testHost)
    ..status = ConnectionStatus.connected;
  session.terminal.write('$id output');
  return session;
}

Future<void> _split(WidgetTester tester, int side, String action) async {
  await tester.tap(find.byKey(ValueKey('terminal-split-menu-$side')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

class _SessionWorkspaceModel extends WorkspaceModel {
  _SessionWorkspaceModel(this.items, MemoryStore preferences)
    : super(
        HostRepository(preferences: preferences, secrets: MemoryStore()),
      ) {
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
  void dispose() {
    for (final session in items) {
      session.removeListener(notifyListeners);
      session.dispose();
    }
    super.dispose();
  }
}

class _SplitHarness extends StatefulWidget {
  const _SplitHarness({
    required this.sessions,
    required this.ratio,
    required this.onRatio,
  });
  final List<SshConnection> sessions;
  final double ratio;
  final ValueChanged<double> onRatio;

  @override
  State<_SplitHarness> createState() => _SplitHarnessState();
}

class _SplitHarnessState extends State<_SplitHarness> {
  final _mobile = TerminalPaneController();
  late double _ratio = widget.ratio;
  int _active = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: TerminalWorkspace(
        sessions: widget.sessions,
        activeSession: widget.sessions[_active],
        hosts: const [testHost],
        desktop: true,
        visible: true,
        mobileController: _mobile,
        onSelect: (id) => setState(
          () => _active = widget.sessions.indexWhere((s) => s.id == id),
        ),
        onConnect: (_) async {},
        onReconnect: (_) async {},
        onClose: (_) {},
        onFiles: (_) {},
        splitRatio: _ratio,
        onSplitRatioChanged: (ratio) {
          setState(() => _ratio = ratio);
          widget.onRatio(ratio);
        },
      ),
    ),
  );
}

class _AiLayoutHarness extends StatefulWidget {
  const _AiLayoutHarness({
    required this.width,
    this.preferred,
    this.revision = 0,
    required this.resized,
  });
  final double width;
  final double? preferred;
  final int revision;
  final List<double?> resized;

  @override
  State<_AiLayoutHarness> createState() => _AiLayoutHarnessState();
}

class _AiLayoutHarnessState extends State<_AiLayoutHarness> {
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: widget.width,
          height: 600,
          child: TerminalAiLayout(
            preferredPanelWidth: widget.preferred,
            preferenceRevision: widget.revision,
            onPanelWidthChanged: widget.resized.add,
            terminal: const SizedBox.expand(key: ValueKey('ai-layout-fake')),
            panel: const SizedBox.expand(key: ValueKey('ai-layout-body')),
          ),
        ),
      ),
    ),
  );
}
