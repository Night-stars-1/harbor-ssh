import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/local_files.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/remote_file.dart';
import 'package:harbor_ssh/ui/file_workspace.dart';
import 'package:harbor_ssh/ui/file_workspace_model.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'file_workspace_test.dart' show MemoryFiles;
import 'support.dart' show testHost;

/// 原生拖放插件在桌面端只用标准编解码器，测试按插件真实协议投递消息。
const _dropChannel = 'desktop_drop';
const _dropCodec = StandardMethodCodec();

void main() {
  testWidgets('原生拖入文件和文件夹写入指针所在面板，内容与空目录都落盘', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-drop-');
    final fileBytes = Uint8List.fromList(List.generate(4096, (i) => i % 251));
    final nestedBytes = Uint8List.fromList(utf8.encode('嵌套内容\n'));
    await _write(tester, '${root.path}/report.bin', fileBytes);
    await _makeDirectory(tester, '${root.path}/bundle');
    await _makeDirectory(tester, '${root.path}/bundle/empty');
    await _write(tester, '${root.path}/bundle/nested.txt', nestedBytes);

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final other = MemoryFiles()..data['/other.txt'] = Uint8List(1);
    final target = MemoryFiles();
    model.add(0, name: 'other', files: other);
    final targetTab = model.add(1, name: 'target', files: target);
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));
    expect(_dropTargetEnabled(tester, 1), isTrue);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/report.bin',
      '${root.path}/bundle',
    ]);
    await _settle(
      tester,
      until: () =>
          !model.busy &&
          target.data.containsKey('/bundle/nested.txt') &&
          target.directories.contains('/bundle/empty') &&
          targetTab.entries.any((entry) => entry.path == '/bundle'),
    );

    expect(target.data['/report.bin'], fileBytes);
    expect(target.data['/bundle/nested.txt'], nestedBytes);
    expect(
      target.directories,
      containsAll(<String>['/bundle', '/bundle/empty']),
    );
    expect(other.data.keys.toList(), ['/other.txt']);
    expect(model.failed, isFalse);
    // 消费端可见：目标面板列出新项目，另一个面板保持原样。
    expect(
      find.byKey(ValueKey('entry-${targetTab.id}-/report.bin')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('entry-${targetTab.id}-/bundle')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('entry-${model.panes[0].tabs.single.id}-/other.txt')),
      findsOneWidget,
    );
    // 隐藏的本地源只服务这一次拖入，不会变成可见标签。
    expect(model.tabs, hasLength(2));
    expect(model.panes[0].tabs, hasLength(1));
    expect(model.panes[1].tabs, hasLength(1));
    expect(find.text('外部拖入'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同名冲突取消保留原字节，确认后替换且不新增可见标签', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-conflict-');
    final newBytes = Uint8List.fromList(
      List.generate(2048, (i) => (i * 7) % 256),
    );
    final oldBytes = Uint8List.fromList([9, 9, 9]);
    await _write(tester, '${root.path}/report.bin', newBytes);

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final target = MemoryFiles()..data['/report.bin'] = oldBytes;
    final targetTab = model.add(1, name: 'target', files: target);
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/report.bin',
    ]);
    await _settle(
      tester,
      until: () => find.text('覆盖 1 个同名项目？').evaluate().isNotEmpty,
    );
    expect(find.text('覆盖 1 个同名项目？'), findsOneWidget);
    // 等待确认期间隐藏源也不进入面板。
    expect(model.tabs, hasLength(1));
    expect(find.text('外部拖入'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('cancel-overwrite-files')));
    // 对话框退场后首页才重新成为当前路由，否则下一次拖入会被拒绝。
    await _settle(
      tester,
      until: () => find.text('覆盖 1 个同名项目？').evaluate().isEmpty,
    );
    expect(target.data['/report.bin'], oldBytes);
    expect(model.failed, isFalse);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/report.bin',
    ]);
    await _settle(
      tester,
      until: () => find.text('覆盖 1 个同名项目？').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-overwrite-files')));
    await _settle(
      tester,
      until: () =>
          !model.busy && target.data['/report.bin']?.length == newBytes.length,
    );

    expect(target.data['/report.bin'], newBytes);
    expect(model.failed, isFalse);
    expect(targetTab.entries.map((entry) => entry.name).toList(), [
      'report.bin',
    ]);
    expect(model.tabs, hasLength(1));
    expect(find.text('外部拖入'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同名批次被拒绝并提示，目标目录与面板都不变', (tester) async {
    _useDesktopViewport(tester);
    final first = await _tempRoot(tester, 'harbor-external-duplicate-a-');
    final second = await _tempRoot(tester, 'harbor-external-duplicate-b-');
    await _write(tester, '${first.path}/same.txt', Uint8List.fromList([1]));
    await _write(tester, '${second.path}/same.txt', Uint8List.fromList([2]));

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final target = MemoryFiles();
    model.add(1, name: 'target', files: target);
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${first.path}/same.txt',
      '${second.path}/same.txt',
    ]);
    await _settle(
      tester,
      until: () => find.textContaining('存在同名目标').evaluate().isNotEmpty,
    );

    expect(find.textContaining('存在同名目标'), findsOneWidget);
    expect(target.data, isEmpty);
    expect(model.tabs, hasLength(1));
    expect(find.text('外部拖入'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖入悬停中关闭外部拖入不抛异常，清除悬停且不再接收原生拖放', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-disable-');
    final bytes = Uint8List.fromList([5, 6, 7]);
    await _write(tester, '${root.path}/late.txt', bytes);

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final target = MemoryFiles();
    model.add(1, name: 'target', files: target);
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));
    final idle = _panelColor(tester, 1);

    final center = _panelCenter(tester, 1);
    await tester.runAsync(() => _enterNativeDrag(tester, center));
    await tester.pump();
    // 原生 entered 确实到达面板：面板进入外部悬停态。
    expect(_panelColor(tester, 1), isNot(idle));

    // 悬停中关闭开关：同一个 State 更新，DropTarget 在 didUpdateWidget 里退出
    // 拖入状态，而祖先元素只能等到下一帧再重建。
    final workspace = tester.state(find.byType(FileWorkspace));
    await tester.pumpWidget(_workspace(model, acceptExternalDrops: false));
    expect(tester.state(find.byType(FileWorkspace)), same(workspace));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_dropTargetEnabled(tester, 1), isFalse);
    expect(_panelColor(tester, 1), idle);

    // 关闭状态下的放下事件被完全忽略。
    await tester.runAsync(
      () => _platformCall(
        tester,
        MethodCall('performOperation', ['${root.path}/late.txt']),
      ),
    );
    await _settle(tester, rounds: 30);
    expect(target.data, isEmpty);
    expect(model.tabs, hasLength(1));
    expect(find.text('覆盖 1 个同名项目？'), findsNothing);

    // 重新打开开关：被推迟的悬停复位已经生效，不会留下没有拖动的高亮。
    await tester.pumpWidget(_workspace(model));
    await tester.pump();
    expect(_dropTargetEnabled(tester, 1), isTrue);
    expect(_panelColor(tester, 1), idle);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件页被 IndexedStack 或 Offstage 隐藏时，关闭开关不接收原生拖放', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-hidden-');
    final bytes = Uint8List.fromList([8, 8, 8]);
    await _write(tester, '${root.path}/hidden.txt', bytes);

    // 关闭开关的隐藏页：原生拖放被完全忽略，目录和标签都不变。
    final closedModel = FileWorkspaceModel();
    addTearDown(closedModel.dispose);
    final closedTarget = MemoryFiles();
    closedModel.add(1, name: 'target', files: closedTarget);
    await tester.pumpWidget(_hiddenWorkspace(closedModel));
    await _settle(tester, until: () => _idle(closedModel));
    expect(_dropTargetEnabled(tester, 1), isFalse);
    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/hidden.txt',
    ]);
    await _settle(tester, rounds: 30);
    expect(closedTarget.data, isEmpty);
    expect(closedModel.tabs, hasLength(1));
    expect(find.text('外部拖入'), findsNothing);

    // Offstage 隐藏的文件页同样按开关忽略原生拖放。
    final offstageModel = FileWorkspaceModel();
    addTearDown(offstageModel.dispose);
    final offstageTarget = MemoryFiles();
    offstageModel.add(1, name: 'target', files: offstageTarget);
    await tester.pumpWidget(_offstageWorkspace(offstageModel));
    await _settle(tester, until: () => _idle(offstageModel));
    expect(_dropTargetEnabled(tester, 1), isFalse);
    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/hidden.txt',
    ]);
    await _settle(tester, rounds: 30);
    expect(offstageTarget.data, isEmpty);
    expect(offstageModel.tabs, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地面板不接收外部拖入，远端面板仍然接收', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-local-');
    await _makeDirectory(tester, '${root.path}/local');
    await _makeDirectory(tester, '${root.path}/incoming');
    await _write(
      tester,
      '${root.path}/local/local.txt',
      Uint8List.fromList([7]),
    );
    final bytes = Uint8List.fromList([8, 9]);
    await _write(tester, '${root.path}/incoming/incoming.txt', bytes);

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final localTab = model.add(
      0,
      name: '本地',
      files: LocalFiles('${root.path}/local'),
      isLocal: true,
      initialPath: '${root.path}/local',
    );
    final remote = MemoryFiles();
    model.add(1, name: 'server', files: remote);
    await tester.runAsync(() => localTab.browse());
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));
    expect(localTab.entries.map((entry) => entry.name).toList(), ['local.txt']);
    expect(_dropTargetEnabled(tester, 0), isFalse);
    expect(_dropTargetEnabled(tester, 1), isTrue);

    await _nativeDrop(tester, _panelCenter(tester, 0), [
      '${root.path}/incoming/incoming.txt',
    ]);
    await _settle(tester, rounds: 30);
    expect(remote.data, isEmpty);
    late List<String> listed;
    await tester.runAsync(() async {
      final entries = await Directory('${root.path}/local').list().toList();
      listed = [
        for (final entry in entries)
          if (entry is File) entry.path.split(Platform.pathSeparator).last,
      ];
    });
    expect(listed, ['local.txt']);
    expect(localTab.entries.map((entry) => entry.name).toList(), ['local.txt']);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/incoming/incoming.txt',
    ]);
    await _settle(
      tester,
      until: () => !model.busy && remote.data.containsKey('/incoming.txt'),
    );
    expect(remote.data['/incoming.txt'], bytes);
    expect(tester.takeException(), isNull);
  });

  testWidgets('断线面板不能接收外部拖入，重连后恢复', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-offline-');
    final bytes = Uint8List.fromList([4, 5, 6]);
    await _write(tester, '${root.path}/offline.txt', bytes);

    final remote = MemoryFiles();
    final session = _OfflineSession(remote);
    addTearDown(session.dispose);
    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    model.add(0, name: 'other', files: MemoryFiles());
    final tab = model.add(
      1,
      name: 'server',
      files: session.files,
      session: session,
    );
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));
    expect(tab.connected, isFalse);
    expect(_dropTargetEnabled(tester, 1), isFalse);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/offline.txt',
    ]);
    await _settle(tester, rounds: 30);
    expect(remote.data, isEmpty);
    expect(model.tabs, hasLength(2));

    session.status = ConnectionStatus.connected;
    session.notifyListeners();
    await tester.pump();
    await _settle(tester, until: () => !tab.loading && tab.error == null);
    expect(_dropTargetEnabled(tester, 1), isTrue);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/offline.txt',
    ]);
    await _settle(
      tester,
      until: () => !model.busy && remote.data.containsKey('/offline.txt'),
    );
    expect(remote.data['/offline.txt'], bytes);
    expect(tester.takeException(), isNull);
  });

  testWidgets('传输进行中不能接收外部拖入，结束后恢复', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-busy-');
    final bytes = Uint8List.fromList([11, 12]);
    await _write(tester, '${root.path}/busy.txt', bytes);

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final source = MemoryFiles()..data['/source.bin'] = Uint8List(4096);
    final target = MemoryFiles()..writeGate = Completer<void>();
    final sourceTab = model.add(0, name: 'source', files: source);
    final targetTab = model.add(1, name: 'target', files: target);
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));

    final copying = model.drop(
      model.dragData(sourceTab, sourceTab.entries.single),
      targetTab,
    );
    await tester.pump();
    expect(model.busy, isTrue);
    expect(_dropTargetEnabled(tester, 1), isFalse);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/busy.txt',
    ]);
    await _settle(tester, rounds: 30);
    expect(target.data.containsKey('/busy.txt'), isFalse);
    expect(find.text('覆盖 1 个同名项目？'), findsNothing);

    target.writeGate!.complete();
    await copying;
    await tester.pump();
    expect(model.busy, isFalse);
    expect(_dropTargetEnabled(tester, 1), isTrue);

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/busy.txt',
    ]);
    await _settle(
      tester,
      until: () => !model.busy && target.data.containsKey('/busy.txt'),
    );
    expect(target.data['/busy.txt'], bytes);
    expect(tester.takeException(), isNull);
  });

  testWidgets('存在待续传断点时不能接收外部拖入', (tester) async {
    _useDesktopViewport(tester);
    final root = await _tempRoot(tester, 'harbor-external-resume-');
    final payload = Uint8List.fromList(
      List.generate(1024 * 1024 + 7, (i) => i % 251),
    );
    final bytes = Uint8List.fromList([21, 22]);
    await _makeDirectory(tester, '${root.path}/source');
    await _makeDirectory(tester, '${root.path}/target');
    await _write(tester, '${root.path}/source/data.bin', payload);
    await _write(tester, '${root.path}/pending.txt', bytes);

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final localSource = model.add(
      0,
      name: 'source',
      files: LocalFiles('${root.path}/source'),
      isLocal: true,
      initialPath: '${root.path}/source',
    );
    final localTarget = model.add(
      1,
      name: 'target',
      files: LocalFiles('${root.path}/target'),
      isLocal: true,
      initialPath: '${root.path}/target',
    );
    final remote = MemoryFiles();
    final remoteTab = model.add(0, name: 'server', files: remote);
    await tester.runAsync(() async {
      await localSource.browse();
      await localTarget.browse();
      await remoteTab.browse();
    });
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));

    var interrupted = false;
    void interrupt() {
      if (!interrupted && model.transfer != null && model.transferred > 0) {
        interrupted = true;
        model.cancel();
      }
    }

    model.addListener(interrupt);
    await tester.runAsync(() async {
      await model.drop(
        model.dragData(localSource, localSource.entries.single),
        localTarget,
      );
    });
    model.removeListener(interrupt);
    await tester.pump();
    expect(interrupted, isTrue);
    expect(model.canResume, isTrue);

    // 断点期间即使指针落在完全可用的远端面板上也不接收。
    model.activate(0, remoteTab.id);
    await tester.pump();
    expect(_dropTargetEnabled(tester, 0), isFalse);
    await _nativeDrop(tester, _panelCenter(tester, 0), [
      '${root.path}/pending.txt',
    ]);
    await _settle(tester, rounds: 30);
    expect(remote.data, isEmpty);
    expect(model.canResume, isTrue);
    expect(model.tabs, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('macOS 安全作用域随取消释放，未授权时不释放', (tester) async {
    _useDesktopViewport(tester);
    final channel = const MethodChannel('desktop_drop');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final root = await _tempRoot(tester, 'harbor-external-macos-');
    final bookmark = Uint8List.fromList([1, 2, 3, 4, 5]);
    final newBytes = Uint8List.fromList([31, 32, 33]);
    final oldBytes = Uint8List.fromList([1, 1, 1]);
    await _write(tester, '${root.path}/report.bin', newBytes);
    await _write(tester, '${root.path}/photo.bin', Uint8List.fromList([41]));

    final model = FileWorkspaceModel();
    addTearDown(model.dispose);
    final target = MemoryFiles()..data['/report.bin'] = oldBytes;
    model.add(1, name: 'target', files: target);
    await tester.pumpWidget(_workspace(model));
    await _settle(tester, until: () => _idle(model));

    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/report.bin',
    ], bookmark: bookmark);
    await _settle(
      tester,
      until: () => find.text('覆盖 1 个同名项目？').evaluate().isNotEmpty,
    );
    expect(calls.map((call) => call.method).toList(), [
      'startAccessingSecurityScopedResource',
    ]);

    await tester.tap(find.byKey(const ValueKey('cancel-overwrite-files')));
    // 取消后释放安全作用域，同时等对话框退场，下一次拖入才不会被拒绝。
    await _settle(
      tester,
      until: () =>
          calls.length >= 2 && find.text('覆盖 1 个同名项目？').evaluate().isEmpty,
    );
    expect(calls.map((call) => call.method).toList(), [
      'startAccessingSecurityScopedResource',
      'stopAccessingSecurityScopedResource',
    ]);
    expect((calls.first.arguments as Map)['apple-bookmark'], bookmark);
    expect((calls.last.arguments as Map)['apple-bookmark'], bookmark);
    expect(target.data['/report.bin'], oldBytes);

    // 未授权时直接提示，不会释放从未拿到的权限。
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method != 'startAccessingSecurityScopedResource';
    });
    calls.clear();
    await _nativeDrop(tester, _panelCenter(tester, 1), [
      '${root.path}/photo.bin',
    ], bookmark: bookmark);
    await _settle(
      tester,
      until: () => find.textContaining('无法读取拖入的本地项目').evaluate().isNotEmpty,
    );
    expect(calls.map((call) => call.method).toList(), [
      'startAccessingSecurityScopedResource',
    ]);
    expect(target.data.containsKey('/photo.bin'), isFalse);
    expect(tester.takeException(), isNull);
  });
}

/// 桌面视口：物理尺寸即逻辑尺寸，原生坐标和面板坐标一一对应。
void _useDesktopViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _workspace(
  FileWorkspaceModel model, {
  bool acceptExternalDrops = true,
}) => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: FileWorkspace(
      model: model,
      hosts: const [],
      sessions: const [],
      onConnect: (_) async => null,
      acceptExternalDrops: acceptExternalDrops,
      // 空面板不自动补本地标签：默认路径会落到真实用户目录，面板在真实目录
      // 读完之前一直显示不确定进度条，测试等不到稳定帧。
      initializeLocal: false,
    ),
  ),
);

/// 另一页在前、文件页在后的常见结构：文件页仍在布局里，但不可见。
Widget _hiddenWorkspace(FileWorkspaceModel model) => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: IndexedStack(
      index: 0,
      sizing: StackFit.expand,
      children: [
        const SizedBox.expand(key: ValueKey('other-page')),
        FileWorkspace(
          model: model,
          hosts: const [],
          sessions: const [],
          onConnect: (_) async => null,
          acceptExternalDrops: false,
          initializeLocal: false,
        ),
      ],
    ),
  ),
);

/// Offstage 隐藏的文件页：子树照样完成布局，但不在台上。
Widget _offstageWorkspace(FileWorkspaceModel model) => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: Offstage(
      offstage: true,
      child: FileWorkspace(
        model: model,
        hosts: const [],
        sessions: const [],
        onConnect: (_) async => null,
        acceptExternalDrops: false,
        initializeLocal: false,
      ),
    ),
  ),
);

/// 面板可能被 IndexedStack 或 Offstage 藏起来，所以查找要跨过「不在台上」的子树。
Finder _panel(int side) =>
    find.byKey(ValueKey('file-panel-$side'), skipOffstage: false);

Finder _dropPanel(int side) =>
    find.byKey(ValueKey('file-external-drop-panel-$side'), skipOffstage: false);

Offset _panelCenter(WidgetTester tester, int side) =>
    tester.getCenter(_panel(side));

bool _dropTargetEnabled(WidgetTester tester, int side) =>
    tester.widget<DropTarget>(_dropPanel(side)).enable;

Color _panelColor(WidgetTester tester, int side) =>
    tester.widget<Material>(_panel(side)).color!;

Future<void> _platformCall(WidgetTester tester, MethodCall call) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _dropChannel,
      _dropCodec.encodeMethodCall(call),
      (_) {},
    );

/// 原生拖入进入事件：插件只在收到它之后才承认随后的放下。
Future<void> _enterNativeDrag(WidgetTester tester, Offset at) =>
    _platformCall(tester, MethodCall('entered', <double>[at.dx, at.dy]));

/// 按插件真实协议投递一次完整的原生拖放，位置是全局逻辑坐标。
Future<void> _nativeDrop(
  WidgetTester tester,
  Offset at,
  List<String> paths, {
  Uint8List? bookmark,
}) async {
  await tester.runAsync(() async {
    await _enterNativeDrag(tester, at);
    await _platformCall(
      tester,
      MethodCall(
        bookmark == null ? 'performOperation' : 'performOperation_macos',
        bookmark == null
            ? paths
            : [
                for (final path in paths)
                  <String, Object?>{
                    'path': path,
                    'isDirectory': false,
                    'fromPromise': false,
                    'apple-bookmark': bookmark,
                  },
              ],
      ),
    );
  });
  await tester.pump();
}

/// 所有标签都读完且没有传输在跑：挂载和确认之后等的就是它。
bool _idle(FileWorkspaceModel model) =>
    !model.busy && model.tabs.every((tab) => !tab.loading);

/// 交替推进真实时间和一帧：真实文件系统在 runAsync 里完成，动画和路由在
/// pump 的假时间里推进。轮数有上限，不做无限等待。
Future<void> _settle(
  WidgetTester tester, {
  bool Function()? until,
  int rounds = 60,
}) async {
  for (var round = 0; round < rounds; round++) {
    if (until != null && until()) {
      // 真实事件循环里的微任务可能在上一帧之后才推进模型，断言前再建一帧，
      // 让界面和模型停在同一个状态。
      await tester.pump(_frame);
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(_frame);
  }
}

const _frame = Duration(milliseconds: 20);

Future<Directory> _tempRoot(WidgetTester tester, String prefix) async {
  final directory = await tester.runAsync(
    () => Directory.systemTemp.createTemp(prefix),
  );
  addTearDown(() => directory!.delete(recursive: true));
  return directory!;
}

Future<void> _write(WidgetTester tester, String path, Uint8List bytes) async {
  await tester.runAsync(() async {
    await File(path).writeAsBytes(bytes, flush: true);
  });
}

Future<void> _makeDirectory(WidgetTester tester, String path) async {
  await tester.runAsync(() async {
    await Directory(path).create();
  });
}

/// 只替换传输通道的会话：SFTP 文件系统由内存替身提供，连接状态可控。
class _OfflineSession extends SshConnection {
  _OfflineSession(this._files) : super(id: 'offline', host: testHost) {
    status = ConnectionStatus.closed;
  }

  final RemoteFileSystem _files;

  @override
  RemoteFileSystem get files => _files;
}
