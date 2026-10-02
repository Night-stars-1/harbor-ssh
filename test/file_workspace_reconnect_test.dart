import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/file_workspace.dart';
import 'package:harbor_ssh/ui/file_workspace_model.dart';
import 'package:harbor_ssh/ui/theme.dart';

import 'file_browser_test.dart' show FileTestSession;

void main() {
  testWidgets('终端原会话重连后自动恢复其 SFTP 标签和原目录', (tester) async {
    final session = _TrackedSession();
    final model = FileWorkspaceModel();
    addTearDown(session.dispose);
    addTearDown(model.dispose);
    final tab = model.add(
      1,
      name: session.host.name,
      files: session.files,
      session: session,
    );
    var requests = 0;
    await _showWorkspace(
      tester,
      model,
      sessions: [session],
      onConnect: (_) async {
        requests++;
        return null;
      },
    );
    await tab.browse('/home/tester/documents');
    tab.filter('report');
    tab.toggleHidden();
    session.close();
    await tester.pumpAndSettle();
    expect(tab.error, isNotNull);
    session.status = ConnectionStatus.connecting;
    session.notifyListeners();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    session.status = ConnectionStatus.connected;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(model.tabs.single, same(tab));
    expect(tab.session, same(session));
    expect(tab.path, '/home/tester/documents');
    expect(tab.query, 'report');
    expect(tab.showHidden, isTrue);
    expect(tab.error, isNull);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final width in [320.0, 1100.0]) {
    testWidgets('断线重试在原标签重连并保留目录，连续点击只连接一次 $width', (tester) async {
      tester.view.physicalSize = Size(width, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = _TrackedSession();
      final next = _TrackedSession();
      final model = FileWorkspaceModel();
      addTearDown(previous.dispose);
      addTearDown(next.dispose);
      addTearDown(model.dispose);
      final tab = model.add(
        1,
        name: previous.host.name,
        files: previous.files,
        session: previous,
        ownsSession: true,
      );
      final savedHost = Host.fromJson({
        ...previous.host.toJson(),
        'name': '更新后的主机',
      });
      final gate = Completer<SshConnection?>();
      var requests = 0;
      await _showWorkspace(
        tester,
        model,
        hosts: [savedHost],
        onConnect: (host) {
          expect(host, same(savedHost));
          requests++;
          return gate.future;
        },
      );
      model.clipboard = FileDragData(
        tab,
        tab.entries.where((f) => !f.isDirectory),
      );
      await tab.browse('/home/tester/documents');
      tab.toggleHidden();
      tab.filter('report');
      previous.close();
      await tester.pumpAndSettle();

      expect(find.text('连接已断开，点击重试以重新连接'), findsOneWidget);
      final retry = find.byKey(ValueKey('retry-file-tab-${tab.id}'));
      final callback = tester.widget<TextButton>(retry).onPressed;
      expect(callback, isNotNull);
      await tester.tap(retry);
      callback!();
      await tester.pump();
      expect(requests, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete(next);
      await tester.pumpAndSettle();
      final restored = model.panes[1].active!;
      expect(model.tabs, hasLength(1));
      expect(restored.id, tab.id);
      expect(model.activeTab, same(restored));
      expect(restored.path, '/home/tester/documents');
      expect(restored.query, 'report');
      expect(restored.showHidden, isTrue);
      expect(restored.session, same(next));
      expect(restored.ownsSession, isTrue);
      expect(restored.error, isNull);
      expect(model.clipboard, isNull);
      expect(previous.disposed, isTrue);
      model.close(1, restored);
      await tester.pumpAndSettle();
      expect(next.disposed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('断线标签复用同主机的新 SSH 会话，关闭标签不释放借用的会话', (tester) async {
    final previous = _TrackedSession();
    final current = _TrackedSession();
    final model = FileWorkspaceModel();
    addTearDown(previous.dispose);
    addTearDown(current.dispose);
    addTearDown(model.dispose);
    final tab = model.add(
      0,
      name: previous.host.name,
      files: previous.files,
      session: previous,
    );
    var requests = 0;
    await _showWorkspace(
      tester,
      model,
      sessions: [previous, current],
      onConnect: (_) async {
        requests++;
        return null;
      },
    );
    previous.close();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('retry-file-tab-${tab.id}')));
    await tester.pumpAndSettle();
    final restored = model.tabs.single;
    expect(requests, 0);
    expect(restored.session, same(current));
    expect(restored.ownsSession, isFalse);
    expect(previous.disposed, isFalse);
    expect(find.text('report.txt'), findsOneWidget);
    model.close(0, restored);
    await tester.pumpAndSettle();
    expect(current.status, ConnectionStatus.connected);
    expect(current.disposed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消或连接失败后仍可重试，已连接的目录错误只刷新目录', (tester) async {
    final previous = _TrackedSession();
    final next = _TrackedSession()..fake.failBrowse = true;
    final model = FileWorkspaceModel();
    addTearDown(previous.dispose);
    addTearDown(next.dispose);
    addTearDown(model.dispose);
    final tab = model.add(
      0,
      name: previous.host.name,
      files: previous.files,
      session: previous,
    );
    var requests = 0;
    await _showWorkspace(
      tester,
      model,
      onConnect: (_) async {
        requests++;
        if (requests == 1) return null;
        if (requests == 2) throw StateError('模拟连接失败');
        return next;
      },
    );
    previous.close();
    await tester.pumpAndSettle();
    final retry = find.byKey(ValueKey('retry-file-tab-${tab.id}'));
    for (var attempt = 1; attempt <= 2; attempt++) {
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(requests, attempt);
      expect(model.tabs.single, same(tab));
      expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    }
    expect(find.textContaining('模拟连接失败'), findsOneWidget);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(model.tabs.single.session, same(next));
    expect(find.textContaining('模拟目录读取失败'), findsOneWidget);
    next.fake.failBrowse = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(requests, 3);
    expect(model.tabs.single.error, isNull);
    expect(find.text('report.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final removeWorkspace in [false, true]) {
    testWidgets('重连等待期间关闭${removeWorkspace ? '工作区' : '标签'}会释放晚到的连接', (
      tester,
    ) async {
      final previous = _TrackedSession();
      final next = _TrackedSession();
      final model = FileWorkspaceModel();
      addTearDown(previous.dispose);
      addTearDown(next.dispose);
      addTearDown(model.dispose);
      final tab = model.add(
        0,
        name: previous.host.name,
        files: previous.files,
        session: previous,
        ownsSession: true,
      );
      final gate = Completer<SshConnection?>();
      await _showWorkspace(tester, model, onConnect: (_) => gate.future);
      previous.close();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('retry-file-tab-${tab.id}')));
      await tester.pump();
      if (removeWorkspace) {
        await tester.pumpWidget(const SizedBox.shrink());
      } else {
        await tester.tap(find.byKey(ValueKey('close-file-tab-${tab.id}')));
        await tester.pumpAndSettle();
        expect(model.tabs, isEmpty);
      }
      gate.complete(next);
      await tester.pumpAndSettle();
      expect(next.disposed, isTrue);
      expect(model.tabs.any((tab) => tab.session == next), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _showWorkspace(
  WidgetTester tester,
  FileWorkspaceModel model, {
  List<Host> hosts = const [],
  List<SshConnection> sessions = const [],
  required Future<SshConnection?> Function(Host) onConnect,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: harborTheme(),
      home: Scaffold(
        body: FileWorkspace(
          model: model,
          hosts: hosts,
          sessions: sessions,
          onConnect: onConnect,
          initializeLocal: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _TrackedSession extends FileTestSession {
  bool disposed = false;

  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    super.dispose();
  }
}
