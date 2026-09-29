import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/port_forward_manager.dart';
import 'package:harbor_ssh/domain/port_forward.dart';

import 'support.dart';

PortForwardRule rule({
  String id = 'one',
  PortForwardType type = PortForwardType.local,
  String bindHost = '127.0.0.1',
  int bindPort = 0,
  int targetPort = 80,
}) => PortForwardRule(
  id: id,
  name: 'Test',
  type: type,
  bindHost: bindHost,
  bindPort: bindPort,
  targetPort: targetPort,
);

class Handle implements PortForwardHandle {
  int closes = 0;
  bool failClose = false;
  @override
  int get port => 43210;
  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw StateError('server refused');
  }
}

void main() {
  for (final type in PortForwardType.values) {
    test('round-trip ${type.name} and IPv6 route', () {
      final value = rule(type: type, bindHost: '::1');
      expect(
        PortForwardRule.fromJson(jsonDecode(jsonEncode(value.toJson())))
            .toJson(),
        value.toJson(),
      );
      expect(value.route(actualPort: 1080), startsWith('[::1]:1080'));
    });
  }
  test('validates bind and target ports and rejects public SOCKS', () {
    for (final invalid in [
      rule(bindPort: -1),
      rule(bindPort: 65536),
      rule(targetPort: 0),
      rule(targetPort: 65536),
      rule(bindHost: ''),
      rule(bindHost: 'bad host'),
      rule(type: PortForwardType.dynamic, bindHost: '0.0.0.0'),
    ]) {
      expect(invalid.validate, throwsFormatException);
    }
    rule(type: PortForwardType.dynamic, targetPort: 0).validate();
  });
  test('stores per-host rules locally and surfaces write failures', () async {
    final memory = MemoryStore();
    final store = PortForwardStore(memory, 'host-a');
    await store.save([rule()]);
    expect((await store.load()).single.id, 'one');
    expect(await PortForwardStore(memory, 'host-b').load(), isEmpty);
    memory.failWrites = true;
    await expectLater(store.save([]), throwsStateError);
    expect((await store.load()).length, 1);
  });
  test(
    'corrupt storage and duplicate IDs are not silently overwritten',
    () async {
      final memory = MemoryStore();
      final store = PortForwardStore(memory, 'host');
      await expectLater(store.save([rule(), rule()]), throwsFormatException);
      memory.values['harbor.port-forwards.v1.host'] = 'invalid';
      await expectLater(store.load(), throwsFormatException);
    },
  );
  test('duplicate start reuses handle; stop and restart work', () async {
    var starts = 0;
    final handle = Handle();
    final manager = PortForwardManager((_) async {
      starts++;
      return handle;
    });
    addTearDown(manager.dispose);
    await manager.start(rule());
    await manager.start(rule());
    expect(starts, 1);
    expect(manager.state('one').port, 43210);
    await manager.stop('one');
    expect(handle.closes, 1);
    expect(manager.activeCount, 0);
    await manager.start(rule());
    expect(starts, 2);
  });
  test('bind errors remain retryable', () async {
    var fail = true;
    final manager = PortForwardManager((_) async {
      if (fail) throw StateError('address in use');
      return Handle();
    });
    addTearDown(manager.dispose);
    await manager.start(rule());
    expect(manager.state('one').status, PortForwardStatus.failed);
    expect(manager.state('one').error, contains('address in use'));
    fail = false;
    await manager.start(rule());
    expect(manager.state('one').status, PortForwardStatus.running);
  });
  for (final disconnect in [false, true]) {
    test(
      'late bind cleaned after ${disconnect ? 'disconnect' : 'stop'}',
      () async {
        final opening = Completer<PortForwardHandle>();
        final manager = PortForwardManager((_) => opening.future);
        addTearDown(manager.dispose);
        final start = manager.start(rule());
        final stop = disconnect ? manager.close() : manager.stop('one');
        final handle = Handle();
        opening.complete(handle);
        await Future.wait([start, stop]);
        expect(handle.closes, 1);
        expect(manager.activeCount, 0);
        if (disconnect) {
          await expectLater(manager.start(rule()), throwsStateError);
        }
      },
    );
  }
  test(
    'dispose while starting suppresses listeners and cleans late handle',
    () async {
      final opening = Completer<PortForwardHandle>();
      final manager = PortForwardManager((_) => opening.future);
      final start = manager.start(rule());
      manager.dispose();
      final handle = Handle();
      opening.complete(handle);
      await start;
      expect(handle.closes, 1);
    },
  );
  test('rejected stop stays active and supports retry', () async {
    final handle = Handle()..failClose = true;
    final manager = PortForwardManager((_) async => handle);
    addTearDown(manager.dispose);
    await manager.start(rule());
    await manager.stop('one');
    expect(manager.state('one').status, PortForwardStatus.running);
    expect(manager.state('one').error, contains('停止失败'));
    handle.failClose = false;
    await manager.stop('one');
    expect(manager.activeCount, 0);
  });
  test('session close cleans every rule including pending bind', () async {
    final handles = <Handle>[];
    final manager = PortForwardManager((_) async {
      final handle = Handle();
      handles.add(handle);
      return handle;
    });
    addTearDown(manager.dispose);
    await Future.wait([
      for (var i = 0; i < 3; i++) manager.start(rule(id: '$i')),
    ]);
    await manager.close();
    expect(handles.every((h) => h.closes == 1), isTrue);
    expect(manager.activeCount, 0);
  });
}
