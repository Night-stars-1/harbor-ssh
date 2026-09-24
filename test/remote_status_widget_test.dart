import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/remote_metrics.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/ui/remote_status_bar.dart';
import 'package:harbor_ssh/ui/terminal_pane.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'package:xterm/xterm.dart';

import 'support.dart';

class _SampledConnection extends SshConnection {
  _SampledConnection(String id) : super(id: id, host: testHost) {
    status = ConnectionStatus.connected;
  }

  int calls = 0;
  Completer<RemoteMetricsSample?>? holdNext;

  @override
  Future<RemoteMetricsSample?> readRemoteMetrics() async {
    calls++;
    final hold = holdNext;
    holdNext = null;
    if (hold != null) return hold.future;
    return RemoteMetricsSample(
      uptimeSeconds: 100 + calls * 5,
      cpuTotal: 1000 + calls * 100,
      cpuIdle: 800 + calls * 20,
      memoryUsedBytes: 600,
      memoryTotalBytes: 1000,
      diskUsedBytes: 300,
      diskTotalBytes: 1000,
      networkInterface: 'eth0',
      networkRxBytes: 10000 + calls * 5000,
      networkTxBytes: 30000 + calls * 2500,
    );
  }

  void disconnect() {
    status = ConnectionStatus.closed;
    notifyListeners();
  }
}

/// Deterministic reading reused by the details-popover tests.
const _metrics = RemoteHostMetrics(
  cpuPercent: 47,
  memoryPercent: 62,
  memoryUsedBytes: 6400000000,
  memoryTotalBytes: 10300000000,
  swapUsedBytes: 268435456,
  swapTotalBytes: 1073741824,
  diskPercent: 72,
  diskUsedBytes: 72000000000,
  diskTotalBytes: 100000000000,
  downloadBytesPerSecond: 2300000,
  uploadBytesPerSecond: 120000,
  cpuCores: [
    RemoteCpuCore(id: 'cpu0', percent: 12),
    RemoteCpuCore(id: 'cpu1', percent: 82),
    // 第三个核心没有相邻计数，只能显示占位符。
    RemoteCpuCore(id: 'cpu2'),
  ],
  processes: [
    RemoteMemoryProcess(pid: 1001, name: 'postgres', residentBytes: 812582912),
    RemoteMemoryProcess(pid: 42, name: 'node', residentBytes: 431226880),
  ],
  processesAvailable: true,
  disks: [
    RemoteDiskUsage(
      device: '/dev/sda1',
      mountPoint: '/',
      totalBytes: 100000000000,
      usedBytes: 72000000000,
      availableBytes: 28000000000,
    ),
    RemoteDiskUsage(
      device: '/dev/sdb1',
      mountPoint: '/data',
      totalBytes: 500000000000,
      usedBytes: 125000000000,
      availableBytes: 375000000000,
    ),
  ],
  disksAvailable: true,
);

/// CPU, memory and transfer rates only: every list-style detail is absent.
const _bareMetrics = RemoteHostMetrics(cpuPercent: 30, memoryPercent: 40);

/// CPU and the transfer rates stay unavailable until a second sample exists.
/// Disk carries only the aggregate root reading: no per-mount `df` rows, so
/// the details panel must not invent one.
const _firstSampleMetrics = RemoteHostMetrics(
  memoryPercent: 62,
  memoryUsedBytes: 6400000000,
  memoryTotalBytes: 10300000000,
  diskPercent: 72,
  diskUsedBytes: 72000000000,
  diskTotalBytes: 100000000000,
);

final _details = find.byKey(const ValueKey('remote-status-details'));

Finder _trigger(String name) =>
    find.byKey(ValueKey<String>('remote-status-$name'));

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _statusBar({
  RemoteHostMetrics? metrics = _metrics,
  bool connected = true,
  double textScale = 1,
}) => MaterialApp(
  theme: harborTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: RemoteStatusBar(
        metrics: metrics,
        connected: connected,
        loading: false,
      ),
    ),
  ),
);

List<String> _detailsTexts(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: _details, matching: find.byType(Text)),
    )
    .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
    .toList();

/// Advances the clock in small steps so hover timers and the menu's
/// open/close animation both run to completion.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openDetails(WidgetTester tester, String name) async {
  await tester.tap(_trigger(name));
  await _pumpFrames(tester);
}

Future<void> _closeDetails(WidgetTester tester) =>
    _pumpFrames(tester, frames: 12);

void main() {
  testWidgets('存储详情仅保留实际卷，显示 df 的预留空间占用率', (tester) async {
    _setView(tester, const Size(420, 600));
    final sample = parseRemoteMetrics('''
__HARBOR_REMOTE_METRICS_BEGIN__
os Linux
uptime 200
disks-ok
df /dev/vda3 ext4 51200000 41300000 7600000 85% /
df tmpfs tmpfs 165172 2457 162715 2% /run
df efivarfs efivarfs 256 8 248 4% /sys/firmware/efi/efivars
df tmpfs tmpfs 825860 0 825860 0% /dev/shm
df /dev/vda2 vfat 201216 6247 194969 4% /boot/efi
df overlay overlay 51200000 41300000 7600000 85% /var/lib/docker/overlay2/one/merged
df overlay overlay 51200000 41300000 7600000 85% /var/lib/docker/overlay2/two/merged
__HARBOR_REMOTE_METRICS_END__
''')!;
    await tester.pumpWidget(
      _statusBar(metrics: RemoteHostMetrics.fromSamples(sample, null)),
    );
    await _openDetails(tester, 'disk');
    expect(find.byKey(const ValueKey('disk-mount-/')), findsOneWidget);
    expect(find.byKey(const ValueKey('disk-mount-/boot/efi')), findsOneWidget);
    expect(find.byKey(const ValueKey('disk-mount-/run')), findsNothing);
    expect(find.textContaining('overlay'), findsNothing);
    expect(find.text('tmpfs'), findsNothing);
    expect(find.text('85.0%'), findsOneWidget);
    expect(find.text('4%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('仅可见的已连接终端采样，离开、切换、断开后不复用旧读数', (tester) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = _SampledConnection('first');
    final second = _SampledConnection('second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Future<void> show(
      _SampledConnection session, {
      bool visible = true,
      int refreshSeconds = 5,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            body: TerminalPane(
              session: session,
              statusVisible: visible,
              statusRefreshSeconds: refreshSeconds,
              onReconnect: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(first);
    expect(first.calls, 1);
    expect(find.text('60%'), findsOneWidget);
    // CPU 与网速需要两次采样，首样本只显示占位符。
    expect(find.text('--'), findsNWidgets(3));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(first.calls, 2);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('1000 B/s'), findsOneWidget);

    await show(first, refreshSeconds: 2);
    await tester.pump(const Duration(seconds: 1));
    expect(first.calls, 2);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(first.calls, 3);

    await show(first, visible: false);
    expect(find.byType(RemoteStatusBar).hitTestable(), findsNothing);
    await tester.pump(const Duration(seconds: 15));
    expect(first.calls, 3);

    await show(second);
    expect(second.calls, 1);
    expect(find.text('--'), findsNWidgets(3));
    expect(first.calls, 3);
    second.disconnect();
    await tester.pump();
    expect(find.text('状态不可用'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    expect(second.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏期间完成的旧采样不会覆盖重新显示的终端', (tester) async {
    final session = _SampledConnection('stale');
    addTearDown(session.dispose);
    final pending = Completer<RemoteMetricsSample?>();
    session.holdNext = pending;
    Future<void> show(bool visible) => tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: TerminalPane(
            session: session,
            statusVisible: visible,
            onReconnect: () {},
          ),
        ),
      ),
    );
    await show(true);
    expect(session.calls, 1);
    await show(false);
    pending.complete(
      const RemoteMetricsSample(memoryUsedBytes: 999, memoryTotalBytes: 1000),
    );
    await tester.pump();
    await show(true);
    await tester.pump();
    expect(find.text('99%'), findsNothing);
    expect(find.text('60%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 1100.0]) {
    testWidgets('状态栏位于 $width 宽终端内容上方', (tester) async {
      tester.view.physicalSize = Size(width, 550);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _SampledConnection('position');
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: Scaffold(
            appBar: width < 900 ? AppBar(title: const Text('终端')) : null,
            body: TerminalPane(
              session: session,
              showHeader: width >= 900,
              onReconnect: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      final status = tester.getRect(find.byType(RemoteStatusBar));
      final terminal = tester.getRect(find.byType(TerminalView));
      expect(status.height, lessThan(32));
      expect(status.bottom, lessThanOrEqualTo(terminal.top));
      final cpuIcon = tester.getRect(
        find.byIcon(Icons.developer_board_outlined),
      );
      expect(cpuIcon.left, greaterThanOrEqualTo(status.left));
      expect(cpuIcon.left - status.left, lessThan(16));
      if (width >= 900) {
        expect(status.top, greaterThanOrEqualTo(56));
      } else {
        expect(
          status.top,
          greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [320.0, 900.0]) {
    testWidgets('状态栏在 $width 宽时完整保留数据且不溢出', (tester) async {
      tester.view.physicalSize = Size(width, 550);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: harborTheme(),
          home: const Scaffold(
            body: Center(
              child: RemoteStatusBar(
                connected: true,
                loading: false,
                metrics: RemoteHostMetrics(
                  cpuPercent: 47,
                  memoryPercent: 62,
                  memoryUsedBytes: 6400000000,
                  memoryTotalBytes: 10300000000,
                  diskPercent: 72,
                  diskUsedBytes: 72000000000,
                  diskTotalBytes: 100000000000,
                  downloadBytesPerSecond: 2300000,
                  uploadBytesPerSecond: 120000,
                ),
              ),
            ),
          ),
        ),
      );
      final bar = find.byType(RemoteStatusBar);
      expect(
        find.descendant(
          of: bar,
          matching: find.byIcon(Icons.developer_board_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.memory_rounded)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.storage_outlined)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bar,
          matching: find.byIcon(Icons.arrow_downward_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bar,
          matching: find.byIcon(Icons.arrow_upward_rounded),
        ),
        findsOneWidget,
      );
      expect(find.text('47%'), findsOneWidget);
      expect(find.text('62%'), findsOneWidget);
      expect(find.text('72%'), findsOneWidget);
      expect(find.text('2.2 MB/s'), findsOneWidget);
      expect(find.text('117.2 KB/s'), findsOneWidget);
      expect(find.textContaining('根分区'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('点击内存图标打开详情，容量与进程明细可达', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar());

    expect(_details, findsNothing);
    await _openDetails(tester, 'memory');
    expect(_details, findsOneWidget);
    final memorySummary = find.byKey(const ValueKey('memory-capacity-summary'));
    for (final label in ['已用', '可用', '总量']) {
      expect(
        find.descendant(of: memorySummary, matching: find.text(label)),
        findsOneWidget,
        reason: '内存详情缺少 $label',
      );
    }
    // 使用率保留一位小数，容量沿用 1024 进制单位。
    expect(_detailsTexts(tester), contains('62.0%'));
    expect(_detailsTexts(tester), containsAll(['6.0 GB', '3.6 GB', '9.6 GB']));
    final usedLabel = tester.getRect(
      find.descendant(of: memorySummary, matching: find.text('已用')),
    );
    final availableLabel = tester.getRect(
      find.descendant(of: memorySummary, matching: find.text('可用')),
    );
    final totalLabel = tester.getRect(
      find.descendant(of: memorySummary, matching: find.text('总量')),
    );
    expect(usedLabel.top, closeTo(availableLabel.top, 0.1));
    expect(availableLabel.top, closeTo(totalLabel.top, 0.1));
    expect(usedLabel.left, lessThan(availableLabel.left));
    expect(availableLabel.left, lessThan(totalLabel.left));

    // TOP 进程列表带 pid、进程名与常驻内存。
    expect(
      find.descendant(of: _details, matching: find.text('占用最高的 2 个进程')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _details, matching: find.text('常驻内存 · 占比')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('memory-process-1001')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-process-42')), findsOneWidget);
    for (final pid in [1001, 42]) {
      final process = find.byKey(ValueKey('memory-process-$pid'));
      final usage = find.byKey(ValueKey('memory-process-usage-$pid'));
      expect(usage, findsOneWidget);
      expect(
        find.descendant(
          of: process,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
      final pidLabel = tester.getRect(
        find.descendant(of: process, matching: find.text('PID $pid')),
      );
      expect(
        tester.getRect(usage).center.dy,
        closeTo(pidLabel.center.dy, 0.5),
        reason: '进度条应与 PID 位于同一行',
      );
      final semantics = tester.widget<Semantics>(
        find.byKey(ValueKey('memory-process-usage-semantics-$pid')),
      );
      expect(semantics.properties.label, startsWith('内存占比 '));
    }
    expect(
      find.descendant(of: _details, matching: find.text('postgres')),
      findsOneWidget,
    );
    final swapSummary = find.byKey(const ValueKey('swap-summary'));
    expect(swapSummary, findsOneWidget);
    expect(
      _detailsTexts(tester),
      containsAll(['Swap', '25.0%', '已用 256.0 MB · 可用 768.0 MB · 共 1.0 GB']),
    );
    final progressIndicators = tester.widgetList<LinearProgressIndicator>(
      find.descendant(
        of: _details,
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progressIndicators, isNotEmpty);
    expect(
      progressIndicators.every(
        (indicator) =>
            indicator.trackGap == 4 && indicator.stopIndicatorRadius == 2,
      ),
      isTrue,
      reason: '详情里的进度条应使用 M3E 间隙和末端指示点',
    );
    expect(_detailsTexts(tester), isNot(contains('7.9%')));
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('memory-process-usage-semantics-1001')),
          )
          .properties
          .label,
      '内存占比 7.9%',
    );
    expect(_detailsTexts(tester), contains('774.9 MB'));

    // 再次点击同一图标收起详情。
    await tester.tap(_trigger('memory'));
    await _closeDetails(tester);
    expect(_details, findsNothing);

    // 存储列出每个挂载分区，根分区使用自己的容量，不做总量相加。
    await _openDetails(tester, 'disk');
    expect(
      find.descendant(of: _details, matching: find.text('存储')),
      findsOneWidget,
    );
    for (final mount in ['/', '/data']) {
      expect(
        find.byKey(ValueKey('disk-mount-$mount')),
        findsOneWidget,
        reason: '存储详情缺少挂载点 $mount',
      );
    }
    expect(
      _detailsTexts(tester),
      contains('已用 67.1 GB · 可用 26.1 GB · 共 93.1 GB'),
    );
    expect(
      _detailsTexts(tester),
      contains('已用 116.4 GB · 可用 349.2 GB · 共 465.7 GB'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('读数更新时已打开的详情同步刷新，读数失效或断开后自动关闭', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar());
    await _openDetails(tester, 'memory');
    expect(_detailsTexts(tester), contains('6.0 GB'));

    await tester.pumpWidget(
      _statusBar(
        metrics: const RemoteHostMetrics(
          cpuPercent: 12,
          memoryPercent: 88,
          memoryUsedBytes: 9000000000,
          memoryTotalBytes: 10000000000,
          diskPercent: 72,
          diskUsedBytes: 72000000000,
          diskTotalBytes: 100000000000,
          downloadBytesPerSecond: 2300000,
          uploadBytesPerSecond: 120000,
        ),
      ),
    );
    await _pumpFrames(tester);
    expect(_details, findsOneWidget, reason: '新读数不应关闭已打开的详情');
    final refreshed = _detailsTexts(tester);
    expect(refreshed, containsAll(['8.4 GB', '9.3 GB']));
    expect(refreshed, isNot(contains('6.0 GB')));

    await tester.pumpWidget(_statusBar(metrics: null));
    await _pumpFrames(tester);
    expect(_details, findsNothing);
    expect(find.text('状态不可用'), findsOneWidget);

    await tester.pumpWidget(_statusBar());
    await _pumpFrames(tester);
    await _openDetails(tester, 'cpu');
    expect(_details, findsOneWidget);
    await tester.pumpWidget(_statusBar(connected: false));
    await _pumpFrames(tester);
    expect(_details, findsNothing);
    expect(find.text('状态不可用'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面悬停 180 毫秒打开详情，移入浮层保持、移出后关闭', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar());

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(tester.getCenter(_trigger('cpu')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_details, findsNothing, reason: '悬停不足 180 毫秒不应打开');
    await _pumpFrames(tester, frames: 6);
    expect(_details, findsOneWidget);
    expect(_detailsTexts(tester), contains('47.0%'));

    // 指针移入浮层内部后保持打开。
    await mouse.moveTo(tester.getRect(_details).center);
    await _pumpFrames(tester, frames: 8);
    expect(_details, findsOneWidget, reason: '指针位于浮层内不应关闭');

    // 离开触发区与浮层后自动关闭。
    await mouse.moveTo(const Offset(8, 560));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_details, findsOneWidget, reason: '离开不足 180 毫秒不应关闭');
    await _closeDetails(tester);
    expect(_details, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬停 CPU 后切换到网速只保留一个浮层，缺失读数显示占位符', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar(metrics: _firstSampleMetrics));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(tester.getCenter(_trigger('cpu')));
    await _pumpFrames(tester, frames: 6);
    expect(_details, findsOneWidget);
    expect(
      find.descendant(of: _details, matching: find.text('--')),
      findsWidgets,
      reason: '首样本 CPU 读数应显示占位符',
    );
    expect(_detailsTexts(tester).join(), contains('采样'));

    await mouse.moveTo(tester.getCenter(_trigger('download')));
    await _pumpFrames(tester);
    expect(_details, findsOneWidget, reason: '同一时刻只允许一个浮层');
    for (final label in ['网络速率', '下载', '上传']) {
      expect(
        find.descendant(of: _details, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: _details, matching: find.text('已用')),
      findsNothing,
      reason: '切换后应显示网速详情而不是内存详情',
    );
    expect(
      find.descendant(of: _details, matching: find.text('--')),
      findsWidgets,
      reason: '首样本网速应显示占位符',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
  testWidgets('十个进程均有 M3E 占比条，窄高窗口可滚动到末项', (tester) async {
    _setView(tester, const Size(420, 686));
    final processes = List.generate(
      10,
      (index) => RemoteMemoryProcess(
        pid: 7000 + index,
        name: 'service-$index',
        residentBytes: (110 - index * 8) * 1024 * 1024,
      ),
    );
    await tester.pumpWidget(
      _statusBar(
        metrics: RemoteHostMetrics(
          memoryPercent: 59.2,
          memoryUsedBytes: 1000000000,
          memoryTotalBytes: 1690000000,
          swapUsedBytes: 1700000000,
          swapTotalBytes: 4000000000,
          processes: processes,
          processesAvailable: true,
        ),
      ),
    );
    await _openDetails(tester, 'memory');
    for (final process in processes) {
      expect(
        find.byKey(ValueKey('memory-process-usage-${process.pid}')),
        findsOneWidget,
      );
    }
    final last = find.byKey(const ValueKey('memory-process-7009'));
    final scroller = find
        .descendant(of: _details, matching: find.byType(SingleChildScrollView))
        .first;
    await tester.drag(scroller, const Offset(0, -600));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(_details);
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(viewport.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击外部或按 Escape 关闭详情，且那次点击不穿透到下层', (tester) async {
    _setView(tester, const Size(900, 600));
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: RemoteStatusBar(
                  metrics: _metrics,
                  connected: true,
                  loading: false,
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: ElevatedButton(
                    key: const ValueKey('outside-target'),
                    onPressed: () => presses++,
                    child: const Text('外部按钮'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await _openDetails(tester, 'memory');
    expect(_details, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outside-target')));
    await _closeDetails(tester);
    expect(_details, findsNothing);
    expect(presses, 0, reason: '关闭浮层的那次点击不应传给下层组件');

    // 浮层收起后同一个按钮恢复响应。
    await tester.tap(find.byKey(const ValueKey('outside-target')));
    await _pumpFrames(tester, frames: 4);
    expect(presses, 1);

    await _openDetails(tester, 'memory');
    expect(_details, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _closeDetails(tester);
    expect(_details, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 宽且文本放大 200% 时详情不溢出并可滚动', (tester) async {
    _setView(tester, const Size(320, 550));
    await tester.pumpWidget(_statusBar(textScale: 2));
    await _openDetails(tester, 'memory');
    expect(_details, findsOneWidget);
    expect(
      find.descendant(of: _details, matching: find.byType(Scrollable)),
      findsWidgets,
      reason: '放大后的长单位应可滚动查看',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('memory-capacity-summary')),
        matching: find.text('已用'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('memory-process-1001')), findsOneWidget);

    // 存储里的多分区在放大后同样不溢出。
    await tester.tap(_trigger('disk'));
    await _pumpFrames(tester);
    expect(find.byKey(const ValueKey('disk-mount-/')), findsOneWidget);
    expect(find.byKey(const ValueKey('disk-mount-/data')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏横向滚动状态栏时关闭详情，滚动后仍可再次打开', (tester) async {
    _setView(tester, const Size(320, 550));
    await tester.pumpWidget(_statusBar());
    await _openDetails(tester, 'memory');
    expect(_details, findsOneWidget);

    // 图标随滚动移位，详情不能继续停在旧锚点。
    await tester.drag(_trigger('memory'), const Offset(-80, 0));
    await _closeDetails(tester);
    expect(_details, findsNothing);

    await tester.tap(_trigger('memory'));
    await _pumpFrames(tester);
    expect(_details, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情浮层没有关闭按钮，靠再次点击、外部点击或 Escape 收起', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar());
    for (final name in ['cpu', 'memory', 'disk', 'download', 'upload']) {
      await _openDetails(tester, name);
      expect(_details, findsOneWidget, reason: '$name 详情未打开');
      expect(
        find.descendant(of: _details, matching: find.byType(IconButton)),
        findsNothing,
        reason: '$name 详情不应再提供关闭按钮',
      );
      expect(
        find.descendant(
          of: _details,
          matching: find.byIcon(Icons.close_rounded),
        ),
        findsNothing,
      );
      await tester.tap(_trigger(name));
      await _closeDetails(tester);
      expect(_details, findsNothing, reason: '$name 详情未收起');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('CPU 详情列出每个核心，缺少相邻计数的核心显示占位符', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar());
    await _openDetails(tester, 'cpu');
    expect(_detailsTexts(tester), contains('47.0%'));
    expect(
      find.descendant(of: _details, matching: find.text('每核心')),
      findsOneWidget,
    );
    for (final core in ['cpu0', 'cpu1', 'cpu2']) {
      expect(find.byKey(ValueKey('cpu-core-$core')), findsOneWidget);
    }
    expect(_detailsTexts(tester), containsAll(['12%', '82%']));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cpu-core-cpu2')),
        matching: find.text('--'),
      ),
      findsOneWidget,
      reason: '没有相邻计数的核心不能冒充 0%',
    );
    expect(_detailsTexts(tester), isNot(contains('每 5 秒更新')));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('未启用 Swap 不显示虚构百分比，缺少内存总量时进程占比未知', (tester) async {
    _setView(tester, const Size(320, 550));
    await tester.pumpWidget(
      _statusBar(
        metrics: const RemoteHostMetrics(
          swapTotalBytes: 0,
          processesAvailable: true,
          processes: [
            RemoteMemoryProcess(pid: 7, name: 'worker', residentBytes: 1024),
          ],
        ),
      ),
    );
    await _openDetails(tester, 'memory');
    final swap = find.byKey(const ValueKey('swap-summary'));
    expect(
      find.descendant(of: swap, matching: find.text('未启用')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: swap, matching: find.text('0.0%')),
      findsNothing,
    );
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('memory-process-usage-semantics-7')),
          )
          .properties
          .label,
      '内存占比 --',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少每核心、进程或分区数据时给出不可用提示而不是伪造 0', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar(metrics: _bareMetrics));
    await _openDetails(tester, 'cpu');
    expect(
      find.descendant(of: _details, matching: find.text('30.0%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _details, matching: find.text('每核心数据不可用')),
      findsOneWidget,
    );

    await tester.tap(_trigger('memory'));
    await _pumpFrames(tester);
    expect(
      find.descendant(of: _details, matching: find.text('40.0%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _details, matching: find.text('进程列表不可用')),
      findsOneWidget,
    );
    // 已用、可用、总量三个空读数都用占位符，而不是 0。
    expect(
      find.descendant(of: _details, matching: find.text('--')),
      findsNWidgets(3),
    );

    await tester.tap(_trigger('disk'));
    await _pumpFrames(tester);
    expect(
      find.descendant(of: _details, matching: find.text('分区信息不可用')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _details, matching: find.text('--')),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有聚合根分区读数时详情不伪造分区列表', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar(metrics: _firstSampleMetrics));
    await _openDetails(tester, 'disk');
    // 聚合百分比来自真实采样，可以留在标题上。
    expect(
      find.descendant(of: _details, matching: find.text('72.0%')),
      findsOneWidget,
    );
    // 没有 df 分区行时不生成任何分区，也不由聚合值推导“可用”空间。
    expect(
      find.descendant(of: _details, matching: find.text('分区信息不可用')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('disk-mount-/')), findsNothing);
    expect(
      find.descendant(of: _details, matching: find.text('可用')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('网络详情用两列展示下载与上传速率', (tester) async {
    _setView(tester, const Size(900, 600));
    await tester.pumpWidget(_statusBar());
    await _openDetails(tester, 'upload');
    expect(
      find.descendant(of: _details, matching: find.text('网络速率')),
      findsOneWidget,
    );
    expect(_detailsTexts(tester), containsAll(['2.2 MB/s', '117.2 KB/s']));
    final download = tester.getRect(
      find.descendant(of: _details, matching: find.text('下载')),
    );
    final upload = tester.getRect(
      find.descendant(of: _details, matching: find.text('上传')),
    );
    expect(download.left, lessThan(upload.left));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('存储详情保留带空格的真实挂载点，逐个分区展示容量且可滚动', (tester) async {
    _setView(tester, const Size(360, 300));
    const many = RemoteHostMetrics(
      diskPercent: 72,
      disks: [
        RemoteDiskUsage(
          device: '/dev/sda1',
          mountPoint: '/',
          totalBytes: 100000000000,
          usedBytes: 72000000000,
          availableBytes: 28000000000,
        ),
        RemoteDiskUsage(
          device: '/dev/sdb1',
          mountPoint: '/data',
          totalBytes: 500000000000,
          usedBytes: 125000000000,
          availableBytes: 375000000000,
        ),
        RemoteDiskUsage(
          device: 'server:/export/media',
          mountPoint: '/mnt/media archive',
          totalBytes: 1000000000000,
          usedBytes: 900000000000,
          availableBytes: 100000000000,
        ),
      ],
      disksAvailable: true,
    );
    await tester.pumpWidget(_statusBar(metrics: many));
    await _openDetails(tester, 'disk');
    expect(find.byKey(const ValueKey('disk-mount-/')), findsOneWidget);
    expect(find.byKey(const ValueKey('disk-mount-/data')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('disk-mount-/mnt/media archive')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _details,
        matching: find.text('server:/export/media'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _details, matching: find.byType(Scrollable)),
      findsWidgets,
      reason: '分区较多时详情应可滚动查看',
    );
    // 每个分区显示各自的容量，没有把多个盘的总量加在一起。
    expect(
      _detailsTexts(tester),
      contains('已用 838.2 GB · 可用 93.1 GB · 共 931.3 GB'),
    );
    expect(_detailsTexts(tester), contains('72.0%'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
