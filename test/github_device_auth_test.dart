import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harbor_ssh/data/github_device_auth.dart';
import 'package:harbor_ssh/data/webdav_sync.dart';

import 'support.dart';

void main() {
  test('设备授权使用 gist 权限，按服务端间隔轮询并处理 slow_down', () async {
    final fixture = await _Fixture.start([
      {'error': 'authorization_pending'},
      {'error': 'slow_down', 'interval': 12},
      {'access_token': 'oauth-token', 'scope': 'gist', 'token_type': 'bearer'},
    ]);
    addTearDown(fixture.close);
    final auth = fixture.auth();
    final code = await auth.start();
    expect(code.userCode, 'ABCD-EFGH');
    expect(code.verificationUri.toString(), 'https://github.com/login/device');
    final account = await auth.waitForAuthorization(code);
    expect(account.token, 'oauth-token');
    expect(account.login, 'harbor-user');
    expect(fixture.delays, [5, 5, 12]);
    expect(fixture.polls, 3);
    expect(fixture.profiles, 1);
    final repository = memoryRepository();
    final sync = CloudSync(repository);
    await sync.saveGitHubAccount(account.token, account.login);
    expect(
      (repository.preferences as MemoryStore).values.values.join(),
      isNot(contains('oauth-token')),
    );
    final reopened = CloudSync(repository);
    await reopened.initialize();
    expect(reopened.settings!.githubLogin, 'harbor-user');
    expect(reopened.settings!.token, 'oauth-token');
    expect(reopened.settings!.automatic, isFalse);
    await reopened.saveGitHubAccount('', '');
    expect(reopened.settings!.token, isEmpty);
    sync.dispose();
    reopened.dispose();
  });

  for (final error in [
    'access_denied',
    'expired_token',
    'incorrect_device_code',
  ]) {
    test('授权失败 $error 不读取账号或返回 Token', () async {
      final fixture = await _Fixture.start([
        {'error': error},
      ]);
      addTearDown(fixture.close);
      final auth = fixture.auth();
      final code = await auth.start();
      await expectLater(
        auth.waitForAuthorization(code),
        throwsA(isA<SyncFailure>()),
      );
      expect(fixture.profiles, 0);
    });
  }

  test('缺少 gist 权限不会接受登录凭据', () async {
    final fixture = await _Fixture.start([
      {
        'access_token': 'oauth-token',
        'scope': 'read:user',
        'token_type': 'bearer',
      },
    ]);
    addTearDown(fixture.close);
    final auth = fixture.auth();
    final code = await auth.start();
    await expectLater(
      auth.waitForAuthorization(code),
      throwsA(isA<SyncFailure>()),
    );
    expect(fixture.profiles, 0);
  });

  test('取消会停止轮询，过期验证码不发请求', () async {
    final fixture = await _Fixture.start([]);
    addTearDown(fixture.close);
    final waiting = Completer<void>();
    final auth = fixture.auth(delay: (_) => waiting.future);
    final code = await auth.start();
    final result = auth.waitForAuthorization(code);
    auth.cancel();
    await expectLater(result, throwsA(isA<GitHubAuthCancelled>()));
    expect(fixture.polls, 0);
    waiting.complete();
    final expired = fixture.auth();
    final expiredCode = await expired.start();
    fixture.time = fixture.time.add(const Duration(minutes: 16));
    await expectLater(
      expired.waitForAuthorization(expiredCode),
      throwsA(isA<SyncFailure>()),
    );
    expect(fixture.polls, 0);
  });

  test('取消正在等待的网络响应，不接受迟到的 Token', () async {
    final fixture = await _Fixture.start([]);
    addTearDown(fixture.close);
    fixture.holdPoll = true;
    final auth = fixture.auth();
    final code = await auth.start();
    final result = auth.waitForAuthorization(code);
    final expectation = expectLater(
      result,
      throwsA(isA<GitHubAuthCancelled>()),
    );
    await fixture.pollArrived.future;
    auth.cancel();
    await expectation;
    expect(fixture.profiles, 0);
  });

  test('未配置 Client ID 以及未启用 Device Flow 提供明确错误', () async {
    await expectLater(
      GitHubDeviceAuth(clientId: '').start(),
      throwsA(isA<SyncFailure>()),
    );
    final fixture = await _Fixture.start([]);
    addTearDown(fixture.close);
    fixture.startError = 'device_flow_disabled';
    await expectLater(
      fixture.auth().start(),
      throwsA(
        isA<SyncFailure>().having(
          (e) => e.message,
          'message',
          contains('Device Flow'),
        ),
      ),
    );
    expect(fixture.polls, 0);
  });
}

class _Fixture {
  _Fixture(this.server, this.replies);
  final HttpServer server;
  final List<Map<String, Object?>> replies;
  final delays = <int>[];
  DateTime time = DateTime.utc(2026, 9, 20);
  int polls = 0, profiles = 0;
  String? startError;
  bool holdPoll = false;
  final pollArrived = Completer<void>();

  static Future<_Fixture> start(List<Map<String, Object?>> replies) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture(server, replies);
    server.listen(fixture.handle);
    return fixture;
  }

  GitHubDeviceAuth auth({Future<void> Function(Duration)? delay}) =>
      GitHubDeviceAuth(
        clientId: 'test-client-id',
        loginBase: Uri.parse('http://127.0.0.1:${server.port}/'),
        apiBase: Uri.parse('http://127.0.0.1:${server.port}/'),
        now: () => time,
        delay:
            delay ??
            (duration) async {
              delays.add(duration.inSeconds);
              time = time.add(duration);
            },
      );

  Future<void> handle(HttpRequest request) async {
    expect(request.headers.value('user-agent'), 'Harbor-SSH');
    Map<String, Object?> response;
    if (request.uri.path == '/user') {
      profiles++;
      expect(request.method, 'GET');
      expect(request.headers.value('authorization'), 'Bearer oauth-token');
      response = {'login': 'harbor-user'};
    } else {
      expect(request.method, 'POST');
      expect(request.headers.value('authorization'), isNull);
      final form = Uri.splitQueryString(
        await utf8.decoder.bind(request).join(),
      );
      expect(form['client_id'], 'test-client-id');
      expect(form.containsKey('client_secret'), isFalse);
      if (request.uri.path == '/login/device/code') {
        expect(form['scope'], 'gist');
        response = startError != null
            ? {'error': startError}
            : {
                'device_code': 'private-device-code',
                'user_code': 'ABCD-EFGH',
                'verification_uri': 'https://github.com/login/device',
                'interval': 5,
                'expires_in': 900,
              };
      } else {
        expect(request.uri.path, '/login/oauth/access_token');
        expect(form['device_code'], 'private-device-code');
        expect(
          form['grant_type'],
          'urn:ietf:params:oauth:grant-type:device_code',
        );
        if (!pollArrived.isCompleted) pollArrived.complete();
        polls++;
        if (holdPoll) return;
        response = replies[polls - 1];
      }
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    await request.response.close();
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}
