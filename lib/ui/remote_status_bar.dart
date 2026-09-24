import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/remote_metrics.dart';

/// Compact metrics with a single anchored detail panel; missing data stays
/// unavailable instead of being rendered as zero.
class RemoteStatusBar extends StatefulWidget {
  const RemoteStatusBar({
    super.key,
    this.metrics,
    required this.connected,
    required this.loading,
  });

  final RemoteHostMetrics? metrics;
  final bool connected;
  final bool loading;
  static const double height = 26;

  @override
  State<RemoteStatusBar> createState() => _RemoteStatusBarState();
}

enum _Metric { cpu, memory, disk, download, upload }

class _RemoteStatusBarState extends State<RemoteStatusBar> {
  final _menu = MenuController();
  Timer? _hoverTimer;
  _Metric _selected = _Metric.cpu;
  bool _pinned = false;
  BuildContext? _anchorContext;

  bool get _available => widget.connected && widget.metrics != null;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didUpdateWidget(RemoteStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_available) {
      _hoverTimer?.cancel();
      _pinned = false;
      // Closing an overlay changes its tree; defer until this build completes.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_available) _menu.close();
      });
    }
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (!_menu.isOpen ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    _menu.close();
    return true;
  }

  void _open(_Metric metric, BuildContext trigger, {required bool pinned}) {
    _hoverTimer?.cancel();
    if (!mounted || !_available || !trigger.mounted) return;
    if (_menu.isOpen && _selected == metric) {
      _pinned = pinned || _pinned;
      return;
    }
    final box = trigger.findRenderObject();
    final anchor = _anchorContext?.findRenderObject();
    if (box is! RenderBox || anchor is! RenderBox) return;
    final position = anchor.globalToLocal(
      box.localToGlobal(Offset(0, box.size.height)),
    );
    setState(() => _selected = metric);
    _menu.open(position: position);
    _pinned = pinned;
  }

  void _hover(_Metric metric, BuildContext trigger) {
    _hoverTimer?.cancel();
    if (_pinned) return;
    _hoverTimer = Timer(const Duration(milliseconds: 180), () {
      _open(metric, trigger, pinned: false);
    });
  }

  void _leave() {
    _hoverTimer?.cancel();
    if (_pinned) return;
    _hoverTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) _menu.close();
    });
  }

  void _toggle(_Metric metric, BuildContext trigger) {
    _hoverTimer?.cancel();
    if (_menu.isOpen && _selected == metric && _pinned) {
      _menu.close();
    } else {
      _open(metric, trigger, pinned: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: RemoteStatusBar.height,
      child: Material(
        color: colors.surfaceContainerHigh,
        child: MenuAnchor(
          controller: _menu,
          useRootOverlay: true,
          consumeOutsideTap: true,
          style: MenuStyle(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colors.outlineVariant),
              ),
            ),
            elevation: const WidgetStatePropertyAll(4),
          ),
          onClose: () {
            _hoverTimer?.cancel();
            _pinned = false;
          },
          menuChildren: [
            MouseRegion(
              onEnter: (_) => _hoverTimer?.cancel(),
              onExit: (_) => _leave(),
              child: _details(context),
            ),
          ],
          builder: (context, controller, child) {
            _anchorContext = context;
            return _content(colors);
          },
        ),
      ),
    );
  }

  Widget _content(ColorScheme colors) {
    final metrics = widget.metrics;
    if (!_available || metrics == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            widget.connected && widget.loading ? '状态读取中…' : '状态不可用',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: NotificationListener<ScrollStartNotification>(
        onNotification: (_) {
          _hoverTimer?.cancel();
          _menu.close();
          return false;
        },
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _item(
                _Metric.cpu,
                Icons.developer_board_outlined,
                'CPU 使用率',
                _percent(metrics.cpuPercent),
                colors,
                percent: metrics.cpuPercent,
              ),
              _item(
                _Metric.memory,
                Icons.memory_rounded,
                '内存',
                _percent(metrics.memoryPercent),
                colors,
                percent: metrics.memoryPercent,
              ),
              _item(
                _Metric.disk,
                Icons.storage_outlined,
                '根分区',
                _percent(metrics.diskPercent),
                colors,
                percent: metrics.diskPercent,
              ),
              _item(
                _Metric.download,
                Icons.arrow_downward_rounded,
                '下载速率',
                _rate(metrics.downloadBytesPerSecond),
                colors,
              ),
              _item(
                _Metric.upload,
                Icons.arrow_upward_rounded,
                '上传速率',
                _rate(metrics.uploadBytesPerSecond),
                colors,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(
    _Metric metric,
    IconData icon,
    String label,
    String value,
    ColorScheme colors, {
    double? percent,
  }) {
    final color = percent == null || percent < 75
        ? colors.onSurfaceVariant
        : percent >= 90
        ? colors.error
        : colors.tertiary;
    return Builder(
      builder: (context) => MouseRegion(
        onEnter: (_) => _hover(metric, context),
        onExit: (_) => _leave(),
        child: Semantics(
          button: true,
          label: '$label $value，查看详情',
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('remote-status-${metric.name}'),
            onTap: () => _toggle(metric, context),
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: RemoteStatusBar.height,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 3),
                    Text(
                      value,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1,
                        color: color,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _details(BuildContext context) {
    final metrics = widget.metrics;
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    // Keep the panel off the pane edges; narrow screens shrink below desktop.
    final room = math.max(
      0.0,
      media.size.width - media.padding.horizontal - 24,
    );
    final Widget body = switch (_selected) {
      _Metric.cpu => _cpuDetails(context, metrics, colors),
      _Metric.memory => _memoryDetails(context, metrics, colors),
      _Metric.disk => _diskDetails(context, metrics, colors),
      _Metric.download ||
      _Metric.upload => _networkDetails(context, metrics, colors),
    };
    return SizedBox(
      key: const ValueKey('remote-status-details'),
      width: math.max(0.0, math.min(380.0, room)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.max(
            48,
            media.size.height -
                media.viewInsets.bottom -
                media.padding.vertical -
                32,
          ),
        ),
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: body,
        ),
      ),
    );
  }

  Widget _cpuDetails(
    BuildContext context,
    RemoteHostMetrics? metrics,
    ColorScheme colors,
  ) {
    final percent = metrics?.cpuPercent;
    final cores = metrics?.cpuCores ?? const <RemoteCpuCore>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _headline(
          context,
          colors,
          'CPU 使用率',
          _percent(percent, precise: true),
          percent,
        ),
        const SizedBox(height: 10),
        _UsageBar(
          percent: percent,
          color: _barTone(colors, percent),
          height: 8,
        ),
        const SizedBox(height: 14),
        if (cores.isEmpty)
          _note(context, colors, '每核心数据不可用')
        else ...[
          _divider(colors),
          _caption(context, colors, '每核心'),
          const SizedBox(height: 4),
          for (final core in cores) _coreRow(context, colors, core),
        ],
        if (percent == null) ...[
          const SizedBox(height: 6),
          _footer(context, colors, '等待相邻两次采样'),
        ],
      ],
    );
  }

  Widget _coreRow(
    BuildContext context,
    ColorScheme colors,
    RemoteCpuCore core,
  ) {
    final style = Theme.of(context).textTheme.labelMedium;
    return Padding(
      key: ValueKey('cpu-core-${core.id}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 46),
            child: Text(
              core.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _UsageBar(
              percent: core.percent,
              color: _barTone(colors, core.percent),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44),
            child: Text(
              _percent(core.percent),
              textAlign: TextAlign.right,
              maxLines: 1,
              style: style?.copyWith(
                color: _textTone(colors, core.percent),
                fontFeatures: _tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _memoryDetails(
    BuildContext context,
    RemoteHostMetrics? metrics,
    ColorScheme colors,
  ) {
    final percent = metrics?.memoryPercent;
    final processes = metrics?.processes ?? const <RemoteMemoryProcess>[];
    final available = metrics?.processesAvailable ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _headline(
          context,
          colors,
          '内存',
          _percent(percent, precise: true),
          percent,
        ),
        const SizedBox(height: 10),
        _UsageBar(
          percent: percent,
          color: _barTone(colors, percent),
          height: 8,
        ),
        const SizedBox(height: 12),
        _memorySummary(
          context,
          colors,
          used: _bytes(metrics?.memoryUsedBytes),
          available: _remaining(
            metrics?.memoryUsedBytes,
            metrics?.memoryTotalBytes,
          ),
          total: _bytes(metrics?.memoryTotalBytes),
        ),
        if (metrics?.swapTotalBytes != null) ...[
          const SizedBox(height: 8),
          _swapSummary(context, colors, metrics),
        ],
        if (available && processes.isNotEmpty) ...[
          _divider(colors),
          Row(
            children: [
              Expanded(
                child: _caption(
                  context,
                  colors,
                  '占用最高的 ${processes.length} 个进程',
                ),
              ),
              const SizedBox(width: 12),
              _caption(context, colors, '常驻内存 · 占比'),
            ],
          ),
          const SizedBox(height: 4),
          for (final process in processes)
            _processRow(context, colors, process, metrics?.memoryTotalBytes),
        ] else ...[
          const SizedBox(height: 10),
          _note(context, colors, available ? '暂无进程数据' : '进程列表不可用'),
        ],
      ],
    );
  }

  Widget _swapSummary(
    BuildContext context,
    ColorScheme colors,
    RemoteHostMetrics? metrics,
  ) {
    final used = metrics?.swapUsedBytes;
    final total = metrics?.swapTotalBytes;
    final percent = total == 0 ? null : _usagePercent(used, total);
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('swap-summary'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Swap', style: theme.textTheme.labelMedium)),
              Text(
                total == 0 ? '未启用' : _percent(percent, precise: true),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _textTone(colors, percent),
                  fontFeatures: _tabular,
                ),
              ),
            ],
          ),
          if (total != 0) ...[
            const SizedBox(height: 6),
            _UsageBar(
              percent: percent,
              color: _barTone(colors, percent),
              height: 8,
            ),
            const SizedBox(height: 6),
            Text(
              '已用 ${_bytes(used)} · 可用 ${_remaining(used, total)} · 共 ${_bytes(total)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _memorySummary(
    BuildContext context,
    ColorScheme colors, {
    required String used,
    required String available,
    required String total,
  }) {
    final media = MediaQuery.of(context);
    final textScale = media.textScaler.scale(1);
    final room = math.max(
      0.0,
      media.size.width - media.padding.horizontal - 24,
    );
    final contentWidth = math.max(0.0, math.min(380.0, room) - 32);
    if (contentWidth < 300 || textScale > 1.4) {
      return Column(
        key: const ValueKey('memory-capacity-summary'),
        children: [
          _statRow(context, colors, '已用', used),
          _statRow(context, colors, '可用', available),
          _statRow(context, colors, '总量', total),
        ],
      );
    }
    return Container(
      key: const ValueKey('memory-capacity-summary'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _memorySummaryCell(context, colors, '已用', used),
            VerticalDivider(
              width: 20,
              thickness: 1,
              color: colors.outlineVariant,
            ),
            _memorySummaryCell(context, colors, '可用', available),
            VerticalDivider(
              width: 20,
              thickness: 1,
              color: colors.outlineVariant,
            ),
            _memorySummaryCell(context, colors, '总量', total),
          ],
        ),
      ),
    );
  }

  Widget _memorySummaryCell(
    BuildContext context,
    ColorScheme colors,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: _tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _processRow(
    BuildContext context,
    ColorScheme colors,
    RemoteMemoryProcess process,
    int? memoryTotalBytes,
  ) {
    final theme = Theme.of(context);
    final percent = _usagePercent(process.residentBytes, memoryTotalBytes);
    return Padding(
      key: ValueKey('memory-process-${process.pid}'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  process.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _bytes(process.residentBytes),
                maxLines: 1,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  fontFeatures: _tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                'PID ${process.pid}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: _tabular,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  key: ValueKey(
                    'memory-process-usage-semantics-${process.pid}',
                  ),
                  label: '内存占比 ${_percent(percent, precise: true)}',
                  child: _UsageBar(
                    key: ValueKey('memory-process-usage-${process.pid}'),
                    percent: percent,
                    color: _barTone(colors, percent),
                    height: 4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diskDetails(
    BuildContext context,
    RemoteHostMetrics? metrics,
    ColorScheme colors,
  ) {
    final disks = metrics?.disks ?? const <RemoteDiskUsage>[];
    // Root first; every other mount keeps the order reported by the host.
    final rows = <RemoteDiskUsage>[
      for (final disk in disks)
        if (disk.mountPoint == '/') disk,
      for (final disk in disks)
        if (disk.mountPoint != '/') disk,
    ];
    // The headline mirrors the root filesystem when the host reported one,
    // otherwise the aggregate root reading from the probe.
    final percent = rows.isNotEmpty && rows.first.mountPoint == '/'
        ? rows.first.percent
        : metrics?.diskPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _headline(
          context,
          colors,
          '存储',
          _percent(percent, precise: true),
          percent,
        ),
        const SizedBox(height: 12),
        // No `df` rows means no per-mount figures at all; deriving "available"
        // from the aggregate would disagree with the filesystem's reserved
        // blocks, so the panel stays explicitly unavailable.
        if (rows.isEmpty)
          _note(context, colors, '分区信息不可用')
        else
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) _divider(colors),
            _diskRow(context, colors, rows[i]),
          ],
      ],
    );
  }

  Widget _diskRow(
    BuildContext context,
    ColorScheme colors,
    RemoteDiskUsage disk,
  ) {
    final theme = Theme.of(context);
    final percent = disk.percent;
    return Padding(
      key: ValueKey('disk-mount-${disk.mountPoint}'),
      padding: const EdgeInsets.only(top: 2, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  disk.mountPoint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              _diskDeviceTag(context, colors, disk.device),
              const SizedBox(width: 10),
              Text(
                _percent(percent),
                maxLines: 1,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: _textTone(colors, percent),
                  fontFeatures: _tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _UsageBar(percent: percent, color: _barTone(colors, percent)),
          const SizedBox(height: 6),
          Text(
            '已用 ${_bytes(disk.usedBytes)} · 可用 ${_bytes(disk.availableBytes)}'
            ' · 共 ${_bytes(disk.totalBytes)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: _tabular,
            ),
          ),
        ],
      ),
    );
  }

  Widget _diskDeviceTag(
    BuildContext context,
    ColorScheme colors,
    String device,
  ) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 132),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          child: Text(
            device,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: _tabular,
            ),
          ),
        ),
      ),
    );
  }

  Widget _networkDetails(
    BuildContext context,
    RemoteHostMetrics? metrics,
    ColorScheme colors,
  ) {
    final download = metrics?.downloadBytesPerSecond;
    final upload = metrics?.uploadBytesPerSecond;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('网络速率', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _rateTile(
                  context,
                  Icons.arrow_downward_rounded,
                  '下载',
                  download,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _rateTile(
                  context,
                  Icons.arrow_upward_rounded,
                  '上传',
                  upload,
                ),
              ),
            ],
          ),
        ),
        if (download == null && upload == null) ...[
          const SizedBox(height: 12),
          _footer(context, colors, '等待相邻两次采样'),
        ],
      ],
    );
  }

  Widget _rateTile(
    BuildContext context,
    IconData icon,
    String label,
    double? bytesPerSecond,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: colors.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _rate(bytesPerSecond),
              maxLines: 1,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFeatures: _tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headline(
    BuildContext context,
    ColorScheme colors,
    String title,
    String value,
    double? percent,
  ) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          maxLines: 1,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: _textTone(colors, percent),
            fontFeatures: _tabular,
            height: 1.1,
          ),
        ),
      ],
    );
  }

  Widget _statRow(
    BuildContext context,
    ColorScheme colors,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(fontFeatures: _tabular),
          ),
        ],
      ),
    );
  }

  /// Hairline that separates the summary from a list inside one panel.
  Widget _divider(ColorScheme colors) =>
      Divider(height: 16, thickness: 1, color: colors.outlineVariant);

  Widget _caption(BuildContext context, ColorScheme colors, String text) =>
      Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: colors.onSurfaceVariant, letterSpacing: 0.3),
      );

  Widget _note(BuildContext context, ColorScheme colors, String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: colors.onSurfaceVariant),
  );

  Widget _footer(BuildContext context, ColorScheme colors, String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: colors.onSurfaceVariant),
  );

  static const _tabular = [FontFeature.tabularFigures()];

  static Color _textTone(ColorScheme colors, double? percent) => percent == null
      ? colors.onSurfaceVariant
      : percent >= 90
      ? colors.error
      : percent >= 75
      ? colors.tertiary
      : colors.onSurface;

  static Color _barTone(ColorScheme colors, double? percent) => percent == null
      ? colors.outline
      : percent >= 90
      ? colors.error
      : percent >= 75
      ? colors.tertiary
      : colors.primary;

  static double? _usagePercent(num? used, num? total) {
    if (used == null ||
        total == null ||
        total <= 0 ||
        used < 0 ||
        used > total) {
      return null;
    }
    return used / total * 100;
  }

  static String _percent(double? value, {bool precise = false}) => value == null
      ? '--'
      : '${precise ? value.toStringAsFixed(1) : value.round()}%';
  static String _rate(double? value) =>
      value == null ? '--' : '${_bytes(value)}/s';
  static String _remaining(int? used, int? total) =>
      used == null || total == null || total < used
      ? '--'
      : _bytes(total - used);

  static String _bytes(num? value) {
    if (value == null) return '--';
    if (value < 1024) return '${value.round()} B';
    const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
    var scaled = value.toDouble();
    var unit = -1;
    do {
      scaled /= 1024;
      unit++;
    } while (scaled >= 1024 && unit < units.length - 1);
    return '${scaled.toStringAsFixed(1)} ${units[unit]}';
  }
}

/// Flat usage track. A null [percent] leaves the track empty instead of
/// drawing a full or fake-zero bar.
class _UsageBar extends StatelessWidget {
  const _UsageBar({
    super.key,
    required this.percent,
    required this.color,
    this.height = 4,
  });

  final double? percent;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LinearProgressIndicator(
      value: percent == null ? 0.0 : (percent! / 100).clamp(0.0, 1.0),
      minHeight: height,
      color: color,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: const BorderRadius.all(Radius.circular(2)),
      stopIndicatorColor: color,
      stopIndicatorRadius: 2,
      trackGap: 4,
      // Flutter still gates the current M3 indicator behind this temporary
      // migration flag; remove it once the framework flips the default.
      // ignore: deprecated_member_use
      year2023: false,
    ),
  );
}
