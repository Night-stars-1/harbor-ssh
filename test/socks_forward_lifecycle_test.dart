import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _Channel implements SSHForwardChannel {
  final incoming = StreamController<Uint8List>();
  final outgoing = StreamController<List<int>>();
  final ended = Completer<void>();
  bool destroyed = false;
  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  StreamSink<List<int>> get sink => outgoing.sink;
  @override
  Future<void> get done => ended.future;
  @override
  Future<void> close() async => destroy();
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    unawaited(incoming.close());
    unawaited(outgoing.close());
    ended.complete();
  }
}

void main() {
  const request = [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 0, 80];
  test('SOCKS closes a channel returned after its dial timeout', () async {
    final opening = Completer<SSHForwardChannel>();
    final proxy = await startDynamicForward(
      bindHost: '127.0.0.1',
      bindPort: 0,
      options: const SSHDynamicForwardOptions(
        connectTimeout: Duration(milliseconds: 30),
      ),
      dial: (_, _) => opening.future,
    );
    addTearDown(proxy.close);
    final socket = await Socket.connect('127.0.0.1', proxy.port);
    addTearDown(socket.destroy);
    final done = socket.drain<void>().catchError((Object _) {});
    socket.add(request);
    await done.timeout(const Duration(seconds: 3));
    final channel = _Channel();
    opening.complete(channel);
    await channel.done.timeout(const Duration(seconds: 3));
    expect(channel.destroyed, isTrue);
  });
  test('SOCKS stopping during dial closes late channel', () async {
    final opening = Completer<SSHForwardChannel>();
    final dialStarted = Completer<void>();
    final proxy = await startDynamicForward(
      bindHost: '127.0.0.1',
      bindPort: 0,
      options: const SSHDynamicForwardOptions(),
      dial: (_, _) {
        dialStarted.complete();
        return opening.future;
      },
    );
    addTearDown(proxy.close);
    final socket = await Socket.connect('127.0.0.1', proxy.port);
    addTearDown(socket.destroy);
    final done = socket.drain<void>().catchError((Object _) {});
    socket.add(request);
    await dialStarted.future.timeout(const Duration(seconds: 3));
    await proxy.close();
    final channel = _Channel();
    opening.complete(channel);
    await channel.done.timeout(const Duration(seconds: 3));
    await done.timeout(const Duration(seconds: 3));
  });
  test('SOCKS connection limit includes clients still negotiating', () async {
    final proxy = await startDynamicForward(
      bindHost: '127.0.0.1',
      bindPort: 0,
      options: const SSHDynamicForwardOptions(maxConnections: 1),
      dial: (_, _) async => throw StateError('unexpected dial'),
    );
    addTearDown(proxy.close);
    final first = await Socket.connect('127.0.0.1', proxy.port);
    addTearDown(first.destroy);
    final greeted = Completer<void>();
    first.listen((data) {
      if (!greeted.isCompleted) greeted.complete();
    });
    first.add([5, 1, 0]);
    await greeted.future.timeout(const Duration(seconds: 3));
    final extra = await Socket.connect('127.0.0.1', proxy.port);
    addTearDown(extra.destroy);
    await extra.drain<void>().timeout(const Duration(seconds: 3));
  });
}
