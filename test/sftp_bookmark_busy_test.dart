import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/file_workspace.dart';
import 'package:harbor_ssh/ui/file_workspace_model.dart';
import 'package:harbor_ssh/ui/theme.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'file_browser_test.dart' show FileTestSession;
import 'support.dart';

void main() {
  testWidgets('写入繁忙时移除目录书签会等待完成，不弹失败且不改变路径', (tester) async {
    tester.view.physicalSize = const Size(1100, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = FileTestSession();
    addTearDown(session.dispose);
    final store = _BlockedHostStore();
    final repository = HostRepository(
      preferences: store,
      secrets: MemoryStore(),
    );
    await repository.saveHosts([
      session.host.withSftpBookmarks(['/home/tester']),
    ]);
    await repository.saveCredentials(
      session.host.id,
      const Credentials(password: 'unchanged'),
    );
    final workspace = WorkspaceModel(repository);
    addTearDown(workspace.dispose);
    await workspace.initialize();
    final files = FileWorkspaceModel();
    addTearDown(files.dispose);
    final tab = files.add(
      0,
      name: session.host.name,
      files: session.files,
      session: session,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: harborTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: workspace,
            builder: (context, _) => FileWorkspace(
              model: files,
              initializeLocal: false,
              hosts: workspace.hosts,
              sessions: [session],
              onConnect: (_) async => null,
              onSetBookmark: workspace.setSftpBookmark,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    store.gate = Completer<void>();
    final busy = workspace.toggleFavorite(workspace.hosts.single);
    await store.entered.future;
    final menu = find.byKey(ValueKey('file-bookmarks-${tab.id}'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('file-bookmark-toggle-${tab.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('书签保存失败'), findsNothing);
    expect(tab.path, '/home/tester');
    store.gate!.complete();
    await busy;
    await tester.pumpAndSettle();
    final saved = (await repository.loadHosts()).single;
    expect(saved.sftpBookmarks, isEmpty);
    expect(saved.favorite, isTrue);
    expect(
      (await repository.credentials(session.host.id))!.password,
      'unchanged',
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('file-bookmark-/home/tester')),
      findsNothing,
    );
    expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _BlockedHostStore extends MemoryStore {
  Completer<void>? gate;
  final entered = Completer<void>();

  @override
  Future<void> write(String key, String value) async {
    if (key == 'harbor.hosts.v1' && gate != null) {
      if (!entered.isCompleted) entered.complete();
      await gate!.future;
    }
    await super.write(key, value);
  }
}
