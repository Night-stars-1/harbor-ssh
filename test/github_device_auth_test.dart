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

  test('可续期登录会保存轮换凭据，且凭据只写入安全存储', () async {
    final fixture = await _Fixture.start([
      {
        'access_token': 'oauth-token',
        'scope': 'gist',
        'token_type': 'bearer',
        'expires_in': 28800,
        'refresh_token': 'refresh-1',
        'refresh_token_expires_in': 15897600,
      },
    ]);
    addTearDown(fixture.close);
    final auth = fixture.auth();
    final code = await auth.start();
    final account = await auth.waitForAuthorization(code);
    final issuedAt = DateTime.utc(2026, 9, 20, 0, 0, 5);
    expect(account.login, 'harbor-user');
    expect(account.refreshToken, 'refresh-1');
    expect(account.expiresAt, issuedAt.add(const Duration(hours: 8)));
    expect(
      account.refreshExpiresAt,
      issuedAt.add(const Duration(seconds: 15897600)),
    );
    final repository = memoryRepository();
    final sync = CloudSync(repository);
    await sync.saveGitHubAccount(
      account.token,
      account.login,
      refreshToken: account.refreshToken,
      expiresAt: account.expiresAt,
      refreshExpiresAt: account.refreshExpiresAt,
    );
    expect((repository.preferences as MemoryStore).values, isEmpty);
    expect(
      (repository.secrets as MemoryStore).values.values.join(),
      contains('refresh-1'),
    );
    final reopened = CloudSync(repository);
    await reopened.initialize();
    expect(reopened.settings!.refreshToken, 'refresh-1');
    expect(reopened.settings!.expiresAt, account.expiresAt);
    expect(reopened.settings!.refreshExpiresAt, account.refreshExpiresAt);
    await reopened.saveGitHubAccount('', '');
    expect(reopened.settings!.token, isEmpty);
    expect(reopened.settings!.refreshToken, isEmpty);
    expect(reopened.settings!.expiresAt, isNull);
    expect(reopened.settings!.refreshExpiresAt, isNull);
    sync.dispose();
    reopened.dispose();
  });

  test('旧版设置仍可读取，退出登录或非过期登录会清除续期信息', () {
    final legacy = CloudSyncConfig.fromJson({
      'provider': 'gist',
      'gistId': 'abc123',
      'token': 'legacy-token',
      'githubLogin': 'harbor-user',
      'encryptionPassword': '',
    });
    expect(legacy.token, 'legacy-token');
    expect(legacy.refreshToken, isEmpty);
    expect(legacy.expiresAt, isNull);
    expect(legacy.refreshExpiresAt, isNull);

    final renewed = legacy.withGitHubAccount(
      'rotated-token',
      'Harbor-User',
      refreshToken: 'refresh-2',
      expiresAt: DateTime.utc(2026, 9, 21, 12),
      refreshExpiresAt: DateTime.utc(2027, 3, 21, 12),
    );
    expect(renewed.gistId, 'abc123');
    expect(renewed.githubLogin, 'Harbor-User');
    expect(renewed.refreshToken, 'refresh-2');
    expect(renewed.expiresAt, DateTime.utc(2026, 9, 21, 12));
    final rewrapped = renewed.withGistId('def456');
    expect(rewrapped.gistId, 'def456');
    expect(rewrapped.refreshToken, 'refresh-2');
    expect(rewrapped.expiresAt, DateTime.utc(2026, 9, 21, 12));
    expect(rewrapped.refreshExpiresAt, DateTime.utc(2027, 3, 21, 12));

    final reopened = CloudSyncConfig.fromJson(
      jsonDecode(jsonEncode(renewed.toJson())) as Map<String, dynamic>,
    );
    expect(reopened.refreshToken, 'refresh-2');
    expect(reopened.expiresAt, DateTime.utc(2026, 9, 21, 12));
    expect(reopened.refreshExpiresAt, DateTime.utc(2027, 3, 21, 12));

    final signedOut = renewed.withGitHubAccount('', '');
    expect(signedOut.token, isEmpty);
    expect(signedOut.refreshToken, isEmpty);
    expect(signedOut.expiresAt, isNull);
    expect(signedOut.refreshExpiresAt, isNull);

    final plain = renewed.withGitHubAccount('plain-token', 'harbor-user');
    expect(plain.expiresAt, isNull);
    expect(plain.refreshToken, isEmpty);
    expect(plain.refreshExpiresAt, isNull);
    expect(plain.toJson().containsKey('refreshToken'), isFalse);
    expect(plain.gistId, 'abc123');

    for (final partial in <CloudSyncConfig Function()>[
      () => renewed.withGitHubAccount(
        'token-only',
        'harbor-user',
        expiresAt: DateTime.utc(2026, 9, 21, 12),
      ),
      () => renewed.withGitHubAccount(
        'token-only',
        'harbor-user',
        refreshToken: 'refresh-3',
      ),
      () => renewed.withGitHubAccount(
        'token-only',
        'harbor-user',
        expiresAt: DateTime.utc(2026, 9, 21, 12),
        refreshExpiresAt: DateTime.utc(2027, 3, 21, 12),
      ),
    ]) {
      expect(partial, throwsA(isA<SyncFailure>()));
    }
  });

  for (final malformed in <(String, Map<String, Object?>)>[
    (
      '缺少刷新令牌',
      {
        'access_token': 'oauth-token',
        'scope': 'gist',
        'token_type': 'bearer',
        'expires_in': 28800,
      },
    ),
    (
      '刷新令牌先于访问令牌过期',
      {
        'access_token': 'oauth-token',
        'scope': 'gist',
        'token_type': 'bearer',
        'expires_in': 28800,
        'refresh_token': 'refresh-1',
        'refresh_token_expires_in': 60,
      },
    ),
    (
      '过期秒数不是整数',
      {
        'access_token': 'oauth-token',
        'scope': 'gist',
        'token_type': 'bearer',
        'expires_in': '8h',
        'refresh_token': 'refresh-1',
        'refresh_token_expires_in': 15897600,
      },
    ),
    (
      '刷新令牌含空白',
      {
        'access_token': 'oauth-token',
        'scope': 'gist',
        'token_type': 'bearer',
        'expires_in': 28800,
        'refresh_token': 'bad token',
        'refresh_token_expires_in': 15897600,
      },
    ),
  ]) {
    test('无效的过期凭据（${malformed.$1}）不会被接受', () async {
      final fixture = await _Fixture.start([malformed.$2]);
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

  test('刷新返回轮换凭据，不读取账号且不发送客户端密钥', () async {
    final fixture = await _Fixture.start(
      const [],
      refreshReplies: [
        {
          'access_token': 'rotated-token',
          'token_type': 'bearer',
          'expires_in': 28800,
          'refresh_token': 'refresh-2',
          'refresh_token_expires_in': 15897600,
        },
      ],
    );
    addTearDown(fixture.close);
    // GitHub rotates the pair before any profile request, so a failing account
    // endpoint must not be able to swallow the new credentials.
    fixture.userStatus = 500;
    final renewal = await fixture.auth().refresh('refresh-1');
    expect(fixture.refreshes, 1);
    expect(fixture.delays, isEmpty);
    expect(renewal.token, 'rotated-token');
    expect(renewal.refreshToken, 'refresh-2');
    expect(renewal.expiresAt, DateTime.utc(2026, 9, 20, 8));
    expect(
      renewal.refreshExpiresAt,
      DateTime.utc(2026, 9, 20).add(const Duration(seconds: 15897600)),
    );
    expect(fixture.profiles, 0);
    expect(fixture.userTokens, isEmpty);
  });

  test('刷新结果携带非 gist 权限时不会返回凭据', () async {
    final fixture = await _Fixture.start(
      const [],
      refreshReplies: [
        {
          'access_token': 'rotated-token',
          'token_type': 'bearer',
          'scope': 'read:user',
          'expires_in': 28800,
          'refresh_token': 'refresh-2',
          'refresh_token_expires_in': 15897600,
        },
      ],
    );
    addTearDown(fixture.close);
    await expectLater(
      fixture.auth().refresh('refresh-1'),
      throwsA(isA<SyncFailure>()),
    );
    expect(fixture.profiles, 0);
  });

  test('刷新失败或轮换不完整时不返回任何凭据', () async {
    final fixture = await _Fixture.start(
      const [],
      refreshReplies: [
        {'error': 'bad_refresh_token'},
        {
          'access_token': 'rotated-token',
          'token_type': 'bearer',
          'expires_in': 28800,
        },
        {'access_token': 'token-only', 'token_type': 'bearer', 'scope': 'gist'},
      ],
    );
    addTearDown(fixture.close);
    final auth = fixture.auth();
    await expectLater(
      auth.refresh('refresh-1'),
      throwsA(
        isA<SyncFailure>().having(
          (e) => e.message,
          'message',
          contains('重新登录'),
        ),
      ),
    );
    await expectLater(auth.refresh('refresh-1'), throwsA(isA<SyncFailure>()));
    await expectLater(auth.refresh('refresh-1'), throwsA(isA<SyncFailure>()));
    expect(fixture.refreshes, 3);
    expect(fixture.profiles, 0);
    await expectLater(auth.refresh(''), throwsA(isA<SyncFailure>()));
    await expectLater(auth.refresh('bad token'), throwsA(isA<SyncFailure>()));
    expect(fixture.refreshes, 3);
  });
}

class _Fixture {
  _Fixture(this.server, this.replies, this.refreshReplies);
  final HttpServer server;
  final List<Map<String, Object?>> replies;
  final List<Map<String, Object?>> refreshReplies;
  final delays = <int>[];
  DateTime time = DateTime.utc(2026, 9, 20);
  int polls = 0, profiles = 0, refreshes = 0;
  String? startError;
  int? userStatus;
  final userTokens = <String?>[];
  bool holdPoll = false;
  final pollArrived = Completer<void>();

  static Future<_Fixture> start(
    List<Map<String, Object?>> replies, {
    List<Map<String, Object?>> refreshReplies = const [],
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _Fixture(server, replies, refreshReplies);
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
      final status = userStatus;
      if (status != null) {
        request.response.statusCode = status;
        await request.response.close();
        return;
      }
      final authorization = request.headers.value('authorization');
      userTokens.add(authorization);
      expect(authorization, 'Bearer oauth-token');
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
        if (form['grant_type'] == 'refresh_token') {
          expect(form['refresh_token'], 'refresh-1');
          expect(form.containsKey('device_code'), isFalse);
          refreshes++;
          response = refreshReplies[refreshes - 1];
        } else {
          expect(
            form['grant_type'],
            'urn:ietf:params:oauth:grant-type:device_code',
          );
          expect(form['device_code'], 'private-device-code');
          if (!pollArrived.isCompleted) pollArrived.complete();
          polls++;
          if (holdPoll) return;
          response = replies[polls - 1];
        }
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
