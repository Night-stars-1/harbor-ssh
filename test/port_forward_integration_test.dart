import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/port_forward.dart';

import 'support.dart';

void main() {
  group('loopback SSH forwarding', () {
    late Process fixture;
    late int sshPort;
    setUpAll(() async {
      fixture = await Process.start('python', [
        '-X',
        'utf8',
        'tool/port_forward_fixture.py',
      ]);
      final ready = Completer<int>();
      fixture.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (!ready.isCompleted) {
              ready.complete((jsonDecode(line) as Map)['port'] as int);
            }
          });
      fixture.stderr.transform(utf8.decoder).listen((error) {
        if (!ready.isCompleted) ready.completeError(StateError(error));
      });
      sshPort = await ready.future.timeout(const Duration(seconds: 15));
    });
    tearDownAll(() async {
      fixture.kill();
      await fixture.exitCode;
    });

    Future<SshConnection> connect({String username = 'tester'}) async {
      final session = SshConnection(
        id: 'test',
        host: Host(
          id: 'test',
          name: 'Fixture',
          address: '127.0.0.1',
          port: sshPort,
          username: username,
        ),
      );
      addTearDown(session.dispose);
      await session.connect(
        const Credentials(password: 'fixture-password'),
        memoryRepository(),
        (_, _) async => true,
        openShell: false,
      );
      expect(session.status, ConnectionStatus.connected, reason: session.error);
      return session;
    }

    Future<ServerSocket> responder() async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final clients = <Socket>[];
      server.listen((socket) async {
        clients.add(socket);
        try {
          // Deliberately wait for EOF before responding; verifies half-close.
          final bytes = await socket.fold<List<int>>(
            [],
            (a, b) => a..addAll(b),
          );
          socket.add(bytes);
          await socket.close();
        } catch (_) {
          socket.destroy();
        }
      });
      addTearDown(() async {
        for (final socket in clients) {
          socket.destroy();
        }
        await server.close();
      });
      return server;
    }

    Future<void> until(bool Function() check) async {
      for (var i = 0; i < 200; i++) {
        if (check()) return;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      fail('Timed out waiting for forward state');
    }

    for (final type in PortForwardType.values) {
      test(
        '${type.name}: large response after EOF, stop and port reuse',
        () async {
          final server = await responder();
          final session = await connect();
          final rule = PortForwardRule(
            id: 'forward',
            name: 'Test',
            type: type,
            bindPort: 0,
            targetPort: server.port,
          );
          await session.portForwards.start(rule);
          final state = session.portForwards.state(rule.id);
          expect(state.status, PortForwardStatus.running, reason: state.error);
          final socket = await Socket.connect('127.0.0.1', state.port!);
          addTearDown(socket.destroy);
          final payload = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
          final received = socket.fold<List<int>>([], (a, b) => a..addAll(b));
          // Send one coalesced write: Linux can deliver a first socket event
          // larger than 32 KiB, including valid SOCKS headers and payload.
          socket.add([
            if (type == PortForwardType.dynamic) ...[
              5,
              1,
              0,
              5,
              1,
              0,
              1,
              127,
              0,
              0,
              1,
              server.port >> 8,
              server.port & 255,
            ],
            ...payload,
          ]);
          await socket.close();
          final response = await received.timeout(const Duration(seconds: 20));
          if (type == PortForwardType.dynamic) {
            expect(
              response.length,
              greaterThanOrEqualTo(12),
              reason:
                  'SOCKS greeting and CONNECT replies must arrive before EOF',
            );
          }
          expect(
            type == PortForwardType.dynamic ? response.sublist(12) : response,
            payload,
          );
          if (type == PortForwardType.dynamic) {
            expect(response.take(4), [5, 0, 5, 0]);
          }
          await session.portForwards.stop(rule.id);
          expect(
            session.portForwards.state(rule.id).status,
            PortForwardStatus.stopped,
          );
          // Remote fixture listener shutdown can finish on its accept timeout.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final reused = await ServerSocket.bind('127.0.0.1', state.port!);
          await reused.close();
        },
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }

    test('occupied local port reports failure and can be retried', () async {
      final server = await responder();
      final session = await connect();
      final rule = PortForwardRule(
        id: 'f',
        name: 'Occupied',
        type: PortForwardType.local,
        bindPort: server.port,
        targetPort: 80,
      );
      await session.portForwards.start(rule);
      expect(session.portForwards.state('f').status, PortForwardStatus.failed);
      await server.close();
      await session.portForwards.start(rule);
      expect(session.portForwards.state('f').status, PortForwardStatus.running);
    });
    test('server rejection surfaces a useful error', () async {
      final session = await connect();
      await session.portForwards.start(
        const PortForwardRule(
          id: 'f',
          name: 'Denied',
          type: PortForwardType.remote,
          bindHost: 'deny.invalid',
          bindPort: 0,
          targetPort: 80,
        ),
      );
      expect(session.portForwards.state('f').status, PortForwardStatus.failed);
      expect(session.portForwards.state('f').error, contains('服务器拒绝'));
    });
    test(
      'rejected remote cancellation remains functional and is retryable',
      () async {
        final session = await connect(username: 'reject-once');
        final server = await responder();
        await session.portForwards.start(
          PortForwardRule(
            id: 'f',
            name: 'Retry',
            type: PortForwardType.remote,
            bindPort: 0,
            targetPort: server.port,
          ),
        );
        final port = session.portForwards.state('f').port!;
        await session.portForwards.stop('f');
        expect(
          session.portForwards.state('f').status,
          PortForwardStatus.running,
        );
        final socket = await Socket.connect('127.0.0.1', port);
        final received = socket.fold<List<int>>([], (a, b) => a..addAll(b));
        socket.add([1, 2, 3]);
        await socket.close();
        expect(await received.timeout(const Duration(seconds: 5)), [1, 2, 3]);
        await session.portForwards.stop('f');
        expect(
          session.portForwards.state('f').status,
          PortForwardStatus.stopped,
        );
      },
    );
    test('disconnect closes all listener types and active sockets', () async {
      final session = await connect();
      final server = await responder();
      final sockets = <Socket>[];
      for (final type in PortForwardType.values) {
        await session.portForwards.start(
          PortForwardRule(
            id: type.name,
            name: type.name,
            type: type,
            bindPort: 0,
            targetPort: server.port,
          ),
        );
        sockets.add(
          await Socket.connect(
            '127.0.0.1',
            session.portForwards.state(type.name).port!,
          ),
        );
      }
      final done = [
        for (final socket in sockets)
          socket.drain<void>().catchError((Object _) {}),
      ];
      session.close();
      await Future.wait(done).timeout(const Duration(seconds: 5));
      await until(() => session.portForwards.activeCount == 0);
      for (final socket in sockets) {
        socket.destroy();
      }
    });
  }, skip: Platform.environment['HARBOR_SSH_INTEGRATION'] != '1');
}
