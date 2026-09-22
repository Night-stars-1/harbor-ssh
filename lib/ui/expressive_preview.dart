import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/host.dart';
import 'expressive_widgets.dart';
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
