import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/host_repository.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/ui/app.dart';
import 'package:harbor_ssh/ui/expressive_widgets.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

const _hosts = [
  Host(id: 'a', name: 'Alpha', address: '192.0.2.1', username: 'root'),
  Host(id: 'b', name: 'Beta', address: '192.0.2.2', username: 'root'),
  Host(id: 'c', name: 'Charlie', address: '192.0.2.3', username: 'root'),
];

class _RecordingWorkspace extends WorkspaceModel {
  _RecordingWorkspace(super.repository);
  int connections = 0;
  @override
  void connect(Host host, Credentials credentials, TrustHost prompt) {
    connections++;
  }
}

Finder _card(String id) => find.byWidgetPredicate(
  (widget) => widget is ExpressiveHostCard && widget.host.id == id,
);

Future<_RecordingWorkspace> _pumpHosts(
  WidgetTester tester,
  double width, {
  List<Host> hosts = _hosts,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = memoryRepository();
  await repository.saveHosts(hosts);
  for (final host in hosts) {
    await repository.saveCredentials(
      host.id,
      const Credentials(password: 'test'),
    );
  }
  final model = _RecordingWorkspace(repository);
  await tester.pumpWidget(HarborApp(model: model));
  await tester.pumpAndSettle();
  return model;
}

List<String> _displayOrder(WidgetTester tester) => tester
    .widgetList<ExpressiveHostCard>(find.byType(ExpressiveHostCard))
    .map((widget) => widget.host.id)
    .toList();

void main() {
  testWidgets('跨行拖动时相邻卡片先让位，取消后恢复原布局', (tester) async {
    final hosts = List.generate(
      6,
      (index) => Host(
        id: '$index',
        name: 'Node $index',
        address: '192.0.2.${index + 1}',
        username: 'root',
      ),
    );
    final model = await _pumpHosts(tester, 1280, hosts: hosts);
    final firstSlot = tester.getTopLeft(_card('0'));
    final thirdSlot = tester.getTopLeft(_card('2'));
    final positions = {
      for (final host in hosts) host.id: tester.getTopLeft(_card(host.id)),
    };
    final target = tester.getCenter(_card('5'));
    final gesture = await tester.startGesture(tester.getCenter(_card('0')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect((tester.getTopLeft(_card('1')) - firstSlot).distance, lessThan(1));
    expect((tester.getTopLeft(_card('3')) - thirdSlot).distance, lessThan(1));
    expect(model.filteredHosts.map((host) => host.id), [
      '0',
      '1',
      '2',
      '3',
      '4',
      '5',
    ]);
    await gesture.cancel();
    await tester.pumpAndSettle();
    for (final host in hosts) {
      expect(
        (tester.getTopLeft(_card(host.id)) - positions[host.id]!).distance,
        lessThan(1),
      );
    }
    expect(model.connections, 0);
    expect(find.text('编辑连接'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('松手保存失败时撤销空间预览并恢复原顺序', (tester) async {
    final model = await _pumpHosts(tester, 1280);
    (model.repository.preferences as MemoryStore).failWrites = true;
    final target = tester.getCenter(_card('c'));
    final gesture = await tester.startGesture(tester.getCenter(_card('a')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_displayOrder(tester), ['a', 'b', 'c']);
    expect(model.filteredHosts.map((host) => host.id), ['a', 'b', 'c']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('长按拖动改变卡片顺序且不连接，宽度 $width', (tester) async {
      final model = await _pumpHosts(tester, width);
      final originalA = tester.getTopLeft(_card('a'));
      final originalB = tester.getTopLeft(_card('b'));
      final originalC = tester.getTopLeft(_card('c'));
      final listGapOffset = width < 800
          ? tester.getSize(_card('a')).height + 4
          : 0.0;
      final target = tester.getCenter(_card('c')).translate(0, listGapOffset);
      final drag = await tester.startGesture(tester.getCenter(_card('a')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await drag.moveTo(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect((tester.getTopLeft(_card('b')) - originalA).distance, lessThan(1));
      expect((tester.getTopLeft(_card('c')) - originalB).distance, lessThan(1));
      expect(model.filteredHosts.map((host) => host.id), ['a', 'b', 'c']);
      await drag.up();
      await tester.pumpAndSettle();
      expect(_displayOrder(tester), ['b', 'c', 'a']);
      expect(model.connections, 0);
      expect(find.text('编辑连接'), findsNothing);
      expect(tester.takeException(), isNull);
      final reloaded = WorkspaceModel(model.repository);
      await reloaded.initialize();
      expect(reloaded.filteredHosts.map((host) => host.id), ['b', 'c', 'a']);
      reloaded.dispose();

      final firstTarget = tester
          .getCenter(_card('b'))
          .translate(0, -listGapOffset);
      final reverse = await tester.startGesture(tester.getCenter(_card('a')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await reverse.moveTo(firstTarget);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect((tester.getTopLeft(_card('b')) - originalB).distance, lessThan(1));
      expect((tester.getTopLeft(_card('c')) - originalC).distance, lessThan(1));
      await reverse.up();
      await tester.pumpAndSettle();
      expect(_displayOrder(tester), ['a', 'b', 'c']);
      expect(model.connections, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('启用排序后静止长按仍打开菜单，取消拖动不改变顺序', (tester) async {
    final model = await _pumpHosts(tester, 390);
    await tester.longPress(_card('a'));
    await tester.pumpAndSettle();
    expect(find.text('编辑连接'), findsOneWidget);
    expect(model.connections, 0);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(model.hosts.firstWhere((host) => host.id == 'a').favorite, isTrue);
    final before = _displayOrder(tester);
    final sourcePosition = tester.getTopLeft(_card('a'));
    final drag = await tester.startGesture(tester.getCenter(_card('a')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await drag.moveTo(
      tester
          .getCenter(_card('b'))
          .translate(0, tester.getSize(_card('a')).height + 4),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      (tester.getTopLeft(_card('b')) - sourcePosition).distance,
      lessThan(1),
    );
    await drag.moveTo(const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();
    expect(_displayOrder(tester), before);
    expect(find.text('编辑连接'), findsNothing);
    expect(model.connections, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖动反馈不泄露隐藏地址且边缘拖动可滚动列表', (tester) async {
    final hosts = List.generate(
      18,
      (index) => Host(
        id: '$index',
        name: 'Node ${index.toString().padLeft(2, '0')}',
        address: '192.0.2.${index + 1}',
        username: 'root',
      ),
    );
    final model = await _pumpHosts(tester, 390, hosts: hosts);
    await tester.tap(find.byKey(const ValueKey('toggle-host-addresses')));
    await tester.pumpAndSettle();
    final source = _card('0');
    final scrollable = Scrollable.of(tester.element(source));
    final before = scrollable.position.pixels;
    final drag = await tester.startGesture(tester.getCenter(source));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(find.textContaining('192.0.2.'), findsNothing);
    final viewport = scrollable.context.findRenderObject()! as RenderBox;
    final bottom = viewport.localToGlobal(
      Offset(viewport.size.width / 2, viewport.size.height - 2),
    );
    await drag.moveTo(bottom);
    for (
      var i = 0;
      i < 120 &&
          scrollable.position.pixels < scrollable.position.maxScrollExtent;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(scrollable.position.pixels, greaterThan(before));
    expect(
      scrollable.position.pixels,
      closeTo(scrollable.position.maxScrollExtent, 1),
    );
    await drag.up();
    await tester.pumpAndSettle();
    expect(model.filteredHosts.last.id, '0');
    expect(model.connections, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
