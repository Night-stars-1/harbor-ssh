import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/host.dart';
import 'expressive_widgets.dart';
import 'reorderable_host_collection.dart';
import 'theme.dart';
import '../domain/remote_file.dart';
import 'remote_file_tile.dart';

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
