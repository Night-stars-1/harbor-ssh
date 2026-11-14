import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/ssh_connection.dart';
import 'package:harbor_ssh/data/sync_cipher.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';
import 'package:harbor_ssh/domain/host.dart';
import 'package:harbor_ssh/domain/port_forward.dart';
import 'package:harbor_ssh/domain/sync_snapshot.dart';
import 'package:harbor_ssh/ui/workspace_model.dart';

import 'support.dart';

void main() {
  test(
    '真实前台恢复先检查 SSH，超时后不重连转发并恢复云同步',
    () async {
      await SshConnection.setMobileBackgrounded(false);
      final fixture = await Process.start('python', ['tool/ssh_fixture.py']);
      addTearDown(() async {
        fixture.kill();
        await fixture.exitCode;
      });
      final ready = Completer<Map<String, dynamic>>();
      fixture.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (!ready.isCompleted) {
              ready.complete(jsonDecode(line) as Map<String, dynamic>);
            }
          });
      fixture.stderr.transform(utf8.decoder).listen((line) {
        if (!ready.isCompleted) ready.completeError(StateError(line));
      });
      final config = await ready.future.timeout(const Duration(seconds: 20));
      final host = Host(
        id: 'background-sync',
        name: '后台恢复测试主机',
        address: '127.0.0.1',
        port: config['port'] as int,
        username: 'slow-keepalive',
      );
      final repository = memoryRepository();
      await repository.saveHosts([host]);
      const credentials = Credentials(password: 'fixture-password');
      await repository.saveCredentials(host.id, credentials);
      final model = WorkspaceModel(repository);
      final connection = SshConnection(id: host.id, host: host);
      addTearDown(() async {
        model.dispose();
        connection.dispose();
        await SshConnection.setMobileBackgrounded(false);
      });
      await model.initialize();
      await connection.connect(credentials, repository, (_, _) async => true);
      expect(connection.status, ConnectionStatus.connected, reason: connection.error);
      const forward = PortForwardRule(
        id: 'background-forward',
        name: '后台转发',
        type: PortForwardType.dynamic,
        bindPort: 0,
      );
      await connection.portForwards.start(forward);
      expect(connection.portForwards.state(forward.id).status, PortForwardStatus.running);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      String? uploaded;
      server.listen((request) async {
        requests.add(request.method);
        if (request.method == 'GET') {
          await request.drain<void>();
          request.response.statusCode = uploaded == null ? 404 : 200;
          if (uploaded != null) {
            request.response.headers.set(HttpHeaders.etagHeader, '"version-1"');
            request.response.write(uploaded);
          }
        } else if (request.method == 'PUT') {
          uploaded = await utf8.decoder.bind(request).join();
          request.response.statusCode = 201;
        } else {
          await request.drain<void>();
          request.response.statusCode = 405;
        }
        await request.response.close();
      });
      const encryptionPassword = 'background-sync-test-password';
      await model.setMobileBackgrounded(true);
      await model.configureSync(
        CloudSyncConfig(
          url: 'http://127.0.0.1:${server.port}/sync/',
          username: 'test',
          password: 'test-password',
          encryptionPassword: encryptionPassword,
          automatic: true,
        ),
      );
      final synced = Completer<void>();
      model.cloudSync.addListener(() {
        if (!synced.isCompleted && model.cloudSync.lastSync != null) {
          synced.complete();
        }
      });
      var checked = false;
      final resumed = model.setMobileBackgrounded(false).then((_) => checked = true);
      // The fixture withholds keepalive replies for six seconds. Waiting past
      // the ordinary two-second sync debounce must not start a cloud request.
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(checked, isFalse);
      expect(connection.backgroundWorkAllowed, isFalse);
      expect(requests, isEmpty);
      await resumed;
      expect(connection.status, ConnectionStatus.failed);
      expect(connection.error, contains('前台恢复'));
      expect(requests, isEmpty);
      await synced.future.timeout(const Duration(seconds: 20));
      expect(requests, ['GET', 'PUT']);
      final snapshot = SyncSnapshot.decode(
        await decryptSync(uploaded!, encryptionPassword),
      );
      expect(snapshot.records['host:${host.id}']?['data']['name'], host.name);
      expect(model.cloudSync.failed, isFalse);
      expect(connection.status, ConnectionStatus.failed);
      expect(connection.portForwards.activeRules, isEmpty);
    },
    skip: Platform.environment['HARBOR_SSH_INTEGRATION'] != '1',
    timeout: const Timeout(Duration(seconds: 50)),
  );
}
