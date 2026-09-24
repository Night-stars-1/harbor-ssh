import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/host.dart';
import 'expressive_widgets.dart';
import 'reorderable_host_collection.dart';
import 'theme.dart';
import '../domain/remote_file.dart';
import '../data/remote_metrics.dart';
import 'remote_file_tile.dart';
import 'remote_status_bar.dart';

@Preview(
  name: 'SFTP file list',
  group: 'Harbor SSH · MD3E',
  size: Size(760, 280),
)
@Preview(
  name: 'SFTP file list · mobile',
  group: 'Harbor SSH · MD3E',
  size: Size(320, 280),
)
Widget harborFilesPreview() => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          RemoteFileTile(
            file: const RemoteFile(
              name: '项目文件',
              path: '/projects',
              isDirectory: true,
            ),
            onOpen: previewNoop,
            onDownload: previewNoop,
            slot: HarborListSlot.first,
          ),
          const SizedBox(height: 2),
          RemoteFileTile(
            file: const RemoteFile(
              name: 'release.tar.gz',
              path: '/release.tar.gz',
              size: 48000000,
            ),
            onOpen: previewNoop,
            onDownload: previewNoop,
            slot: HarborListSlot.middle,
          ),
          const SizedBox(height: 2),
          RemoteFileTile(
            file: const RemoteFile(
              name: 'README.md',
              path: '/README.md',
              size: 3800,
            ),
            onOpen: previewNoop,
            onDownload: previewNoop,
            slot: HarborListSlot.last,
          ),
        ],
      ),
    ),
  ),
);

@Preview(name: 'Harbor mark', group: 'Harbor SSH · MD3E', size: Size(220, 140))
Widget harborMarkPreview() => MaterialApp(
  theme: harborTheme(),
  home: const Scaffold(
    body: Center(child: ExpressiveMark(size: 84, flower: true)),
  ),
);

@Preview(
  name: 'SSH host card',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 144),
)
Widget harborHostCardPreview() => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ExpressiveHostCard(
        host: const Host(
          id: 'preview',
          name: '生产 API',
          address: 'api.example.com',
          username: 'deploy',
          tags: ['生产环境'],
          favorite: true,
          authMethod: AuthMethod.privateKey,
        ),
        asCard: true,
        onConnect: previewNoop,
        onFavorite: previewNoop,
        onAction: previewNoopAction,
      ),
    ),
  ),
);

void previewNoop() {}
void previewNoopAction(String _) {}

@Preview(
  name: 'Host list · long-press reorder',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 320),
)
Widget harborReorderPreview() => _reorderPreview(grid: false);

@Preview(
  name: 'Host grid · long-press reorder',
  group: 'Harbor SSH · MD3E',
  size: Size(640, 320),
)
Widget harborReorderGridPreview() => _reorderPreview(grid: true);

Widget _reorderPreview({required bool grid}) => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: _ReorderPreview(grid: grid),
    ),
  ),
);

class _ReorderPreview extends StatefulWidget {
  const _ReorderPreview({required this.grid});

  /// Wide previews arrange cards in a grid, phone width keeps one column.
  final bool grid;

  @override
  State<_ReorderPreview> createState() => _ReorderPreviewState();
}

class _ReorderPreviewState extends State<_ReorderPreview> {
  static const _hosts = [
    Host(
      id: 'reorder-a',
      name: '生产 API',
      address: 'api.example.com',
      username: 'deploy',
      tags: ['生产环境'],
      favorite: true,
      authMethod: AuthMethod.privateKey,
    ),
    Host(
      id: 'reorder-b',
      name: '开发服务器',
      address: 'dev.example.com',
      username: 'deploy',
      tags: ['开发环境'],
      authMethod: AuthMethod.privateKey,
    ),
    Host(
      id: 'reorder-c',
      name: '构建机',
      address: 'build.internal',
      username: 'deploy',
      tags: ['持续集成构建流水线作业', '夜间定时构建任务队列'],
      authMethod: AuthMethod.privateKey,
    ),
  ];

  List<Host> _order = _hosts;

  /// Mirrors the reorder the app applies: the source lands in the visible slot
  /// the target had, so no host is ever duplicated.
  void _reorder(Host source, Host target) {
    final from = _order.indexWhere((host) => host.id == source.id);
    final to = _order.indexWhere((host) => host.id == target.id);
    if (from < 0 || to < 0 || from == to) return;
    setState(() {
      final next = [..._order];
      next.insert(to, next.removeAt(from));
      _order = next;
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CustomScrollView(
      slivers: [
        widget.grid
            ? SliverPadding(
                padding: const EdgeInsets.only(bottom: 12),
                sliver: ReorderableHostGridSliver(
                  hosts: _order,
                  cardBuilder: _card,
                  onReorder: _reorder,
                  width: constraints.maxWidth,
                ),
              )
            : ReorderableHostSliver(
                hosts: _order,
                cardBuilder: _card,
                onReorder: _reorder,
              ),
      ],
    ),
  );

  Widget _card(BuildContext context, int index, HostCardMenuController? menu) =>
      ExpressiveHostCard(
        host: _order[index],
        slot: widget.grid
            ? HarborListSlot.single
            : HarborShapes.listSlot(index, _order.length),
        asCard: widget.grid,
        menuController: menu,
        onConnect: previewNoop,
        onFavorite: previewNoop,
        onAction: previewNoopAction,
      );
}

@Preview(
  name: 'SSH host card · address hidden',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 144),
)
Widget harborHiddenAddressCardPreview() => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ExpressiveHostCard(
        host: const Host(
          id: 'hidden-preview',
          name: '生产 API',
          address: '10.24.8.31',
          username: 'deploy',
          port: 2222,
          tags: ['生产环境'],
          favorite: true,
          authMethod: AuthMethod.privateKey,
        ),
        asCard: true,
        hideAddress: true,
        onConnect: previewNoop,
        onFavorite: previewNoop,
        onAction: previewNoopAction,
      ),
    ),
  ),
);

@Preview(
  name: 'Host card · dark',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 144),
)
Widget harborDarkCardPreview() => MaterialApp(
  theme: harborTheme(brightness: Brightness.dark),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ExpressiveHostCard(
        host: const Host(
          id: 'dark-preview',
          name: '开发服务器',
          address: 'dev.example.com',
          username: 'deploy',
          tags: ['开发环境'],
        ),
        asCard: true,
        onConnect: previewNoop,
        onFavorite: previewNoop,
        onAction: previewNoopAction,
      ),
    ),
  ),
);

@Preview(
  name: 'Host list · large text',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 360),
)
Widget harborLargeTextPreview() => MaterialApp(
  theme: harborTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: ExpressiveHostCard(
        host: const Host(
          id: 'large-preview',
          name: '生产服务器',
          address: 'api.example.com',
          username: 'deploy',
          tags: ['生产环境'],
        ),
        onConnect: previewNoop,
        onFavorite: previewNoop,
        onAction: previewNoopAction,
      ),
    ),
  ),
);

/// Deterministic sample used by the remote status bar previews: eight unevenly
/// loaded cores, a top process list and several mounts, so every detail panel
/// has real content to show.
const _remoteCpuCores = <RemoteCpuCore>[
  RemoteCpuCore(id: 'cpu0', percent: 18),
  RemoteCpuCore(id: 'cpu1', percent: 4),
  RemoteCpuCore(id: 'cpu2', percent: 42),
  RemoteCpuCore(id: 'cpu3', percent: 76),
  RemoteCpuCore(id: 'cpu4', percent: 93),
  RemoteCpuCore(id: 'cpu5', percent: 27),
  RemoteCpuCore(id: 'cpu6', percent: 61),
  RemoteCpuCore(id: 'cpu7', percent: 8),
];

const _remoteProcesses = <RemoteMemoryProcess>[
  RemoteMemoryProcess(pid: 1123, name: 'postgres', residentBytes: 812582912),
  RemoteMemoryProcess(pid: 948, name: 'node', residentBytes: 431226880),
  RemoteMemoryProcess(
    pid: 41,
    name: 'systemd-journald',
    residentBytes: 201326592,
  ),
  RemoteMemoryProcess(pid: 1502, name: 'python3', residentBytes: 178257920),
  RemoteMemoryProcess(pid: 733, name: 'sshd', residentBytes: 96468992),
  RemoteMemoryProcess(
    pid: 2044,
    name: 'containerd-shim-runc-v2',
    residentBytes: 74448896,
  ),
  RemoteMemoryProcess(pid: 611, name: 'dockerd', residentBytes: 62914560),
  RemoteMemoryProcess(
    pid: 12,
    name: 'kworker/0:1H-events_highpri',
    residentBytes: 31457280,
  ),
];

const _remoteDisks = <RemoteDiskUsage>[
  RemoteDiskUsage(
    device: '/dev/nvme0n1p2',
    mountPoint: '/',
    totalBytes: 53687091200,
    usedBytes: 44501510144,
    availableBytes: 9185582080,
  ),
  RemoteDiskUsage(
    device: '/dev/nvme0n1p1',
    mountPoint: '/boot/efi',
    totalBytes: 536870912,
    usedBytes: 62914560,
    availableBytes: 473956352,
  ),
  RemoteDiskUsage(
    device: '/dev/sdb1',
    mountPoint: '/data',
    totalBytes: 2199023255552,
    usedBytes: 1469755596800,
    availableBytes: 729267658752,
  ),
  RemoteDiskUsage(
    device: '192.168.1.20:/export/media',
    mountPoint: '/mnt/media archive',
    totalBytes: 1099511627776,
    usedBytes: 989560465000,
    availableBytes: 109951162776,
  ),
];

const _remoteMetricsSample = RemoteHostMetrics(
  cpuPercent: 41.1,
  memoryPercent: 61.2,
  diskPercent: 82.9,
  downloadBytesPerSecond: 1433600,
  uploadBytesPerSecond: 93184,
  memoryUsedBytes: 2453667840,
  memoryTotalBytes: 4026531840,
  diskUsedBytes: 44501510144,
  diskTotalBytes: 53687091200,
  cpuCores: _remoteCpuCores,
  processes: _remoteProcesses,
  processesAvailable: true,
  disks: _remoteDisks,
  disksAvailable: true,
);

Widget _remoteStatusPreview({
  required Brightness brightness,
  required double width,
  RemoteHostMetrics? metrics = _remoteMetricsSample,
  bool connected = true,
  bool loading = false,
}) => MaterialApp(
  theme: harborTheme(brightness: brightness),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: width,
        child: RemoteStatusBar(
          metrics: metrics,
          connected: connected,
          loading: loading,
        ),
      ),
    ),
  ),
);

@Preview(
  name: 'Remote status bar · 390',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 360),
)
Widget harborRemoteStatusPreview() =>
    _remoteStatusPreview(brightness: Brightness.light, width: 390);

@Preview(
  name: 'Remote status bar · 900',
  group: 'Harbor SSH · MD3E',
  size: Size(900, 360),
)
Widget harborRemoteStatusWidePreview() =>
    _remoteStatusPreview(brightness: Brightness.light, width: 900);

@Preview(
  name: 'Remote status bar · dark 390',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 360),
)
Widget harborRemoteStatusDarkPreview() =>
    _remoteStatusPreview(brightness: Brightness.dark, width: 390);

@Preview(
  name: 'Remote status bar · dark 900',
  group: 'Harbor SSH · MD3E',
  size: Size(900, 360),
)
Widget harborRemoteStatusDarkWidePreview() =>
    _remoteStatusPreview(brightness: Brightness.dark, width: 900);

@Preview(
  name: 'Remote status bar · narrow 320',
  group: 'Harbor SSH · MD3E',
  size: Size(320, 360),
)
Widget harborRemoteStatusNarrowPreview() =>
    _remoteStatusPreview(brightness: Brightness.light, width: 320);

@Preview(
  name: 'Remote status bar · dark narrow 320',
  group: 'Harbor SSH · MD3E',
  size: Size(320, 360),
)
Widget harborRemoteStatusDarkNarrowPreview() =>
    _remoteStatusPreview(brightness: Brightness.dark, width: 320);

@Preview(
  name: 'Remote status bar · first sample',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 360),
)
Widget harborRemoteStatusFirstSamplePreview() => _remoteStatusPreview(
  brightness: Brightness.light,
  width: 390,
  // CPU and network need two samples, so the first read shows placeholders and
  // the per-core grid stays empty; process and mount lists are not reported yet.
  metrics: const RemoteHostMetrics(
    memoryPercent: 61.2,
    diskPercent: 82.9,
    memoryUsedBytes: 2453667840,
    memoryTotalBytes: 4026531840,
    diskUsedBytes: 44501510144,
    diskTotalBytes: 53687091200,
    cpuCores: [
      RemoteCpuCore(id: 'cpu0'),
      RemoteCpuCore(id: 'cpu1'),
      RemoteCpuCore(id: 'cpu2'),
      RemoteCpuCore(id: 'cpu3'),
    ],
  ),
);

@Preview(
  name: 'Remote status bar · unavailable',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 36),
)
Widget harborRemoteStatusUnavailablePreview() => _remoteStatusPreview(
  brightness: Brightness.dark,
  width: 390,
  metrics: null,
  connected: false,
);
