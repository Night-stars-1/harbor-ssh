import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_config.dart';

// OAuth Client IDs are public application identifiers, not account secrets.
const githubOAuthClientId = String.fromEnvironment(
  'GITHUB_OAUTH_CLIENT_ID',
  defaultValue: 'Ov23liFjzXHcMmwHYDM6',
);

class GitHubAccount {
  const GitHubAccount({required this.token, required this.login});
  final String token, login;
}

class GitHubDeviceCode {
  const GitHubDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.expiresAt,
    required this.interval,
  });
  final String deviceCode, userCode;
  final DateTime expiresAt;
  final Duration interval;
  Uri get verificationUri => Uri.https('github.com', '/login/device');
}

class GitHubAuthCancelled implements Exception {
  const GitHubAuthCancelled();
}

/// OAuth device flow for a public client: no client secret or embedded webview.
class GitHubDeviceAuth {
  GitHubDeviceAuth({
    this.clientId = githubOAuthClientId,
    Uri? loginBase,
    Uri? apiBase,
    DateTime Function()? now,
    this.delay,
  }) : _loginBase = loginBase ?? Uri.https('github.com', '/'),
       _apiBase = apiBase ?? Uri.https('api.github.com', '/'),
       _now = now ?? DateTime.now;

  final String clientId;
  final Uri _loginBase, _apiBase;
  final DateTime Function() _now;
  final Future<void> Function(Duration)? delay;
  final _cancelled = Completer<void>();
  HttpClient? _activeClient;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    _activeClient?.close(force: true);
  }

  void _checkCancelled() {
    if (_cancelled.isCompleted) throw const GitHubAuthCancelled();
  }

  Future<void> _pause(Duration duration) async {
    final elapsed = Completer<void>();
    final timer = delay == null ? Timer(duration, elapsed.complete) : null;
    try {
      await Future.any([
        delay?.call(duration) ?? elapsed.future,
        _cancelled.future,
      ]);
    } finally {
      timer?.cancel();
    }
  }

  Future<GitHubDeviceCode> start() async {
    _checkCancelled();
    if (clientId.trim().isEmpty) {
      throw const SyncFailure(
        '当前版本尚未配置 GitHub 网页登录，请配置 OAuth App Client ID 后重新构建',
      );
    }
    final data = await _request(
      _loginBase.resolve('login/device/code'),
      form: {'client_id': clientId, 'scope': 'gist'},
    );
    _checkCancelled();
    _checkError(data);
    final deviceCode = data['device_code'];
    final userCode = data['user_code'];
    final expires = data['expires_in'];
    final interval = data['interval'] ?? 5;
    if (deviceCode is! String ||
        deviceCode.isEmpty ||
        userCode is! String ||
        !RegExp(r'^[A-Z0-9-]{4,32}$').hasMatch(userCode) ||
        expires is! int ||
        expires <= 0 ||
        expires > 3600 ||
        interval is! int ||
        interval <= 0 ||
        interval > expires ||
        data['verification_uri'] != 'https://github.com/login/device') {
      throw const SyncFailure('GitHub 返回了无效的授权信息，请重试');
    }
    return GitHubDeviceCode(
      deviceCode: deviceCode,
      userCode: userCode,
      expiresAt: _now().add(Duration(seconds: expires)),
      interval: Duration(seconds: interval),
    );
  }

  Future<GitHubAccount> waitForAuthorization(GitHubDeviceCode code) async {
    var interval = code.interval;
    while (true) {
      _checkCancelled();
      final remaining = code.expiresAt.difference(_now());
      if (remaining <= Duration.zero) {
        throw const SyncFailure('GitHub 验证码已过期，请重新登录');
      }
      await _pause(interval < remaining ? interval : remaining);
      _checkCancelled();
      if (!_now().isBefore(code.expiresAt)) {
        throw const SyncFailure('GitHub 验证码已过期，请重新登录');
      }
      final data = await _request(
        _loginBase.resolve('login/oauth/access_token'),
        form: {
          'client_id': clientId,
          'device_code': code.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      _checkCancelled();
      if (!_now().isBefore(code.expiresAt)) {
        throw const SyncFailure('GitHub 验证码已过期，请重新登录');
      }
      if (data['error'] == 'authorization_pending') continue;
      if (data['error'] == 'slow_down') {
        // GitHub requires at least five more seconds on all subsequent polls.
        final suggested = data['interval'];
        interval += const Duration(seconds: 5);
        if (suggested is int && suggested > interval.inSeconds) {
          interval = Duration(seconds: suggested);
        }
        continue;
      }
      _checkError(data);
      final token = data['access_token'];
      final scopes = (data['scope'] as String? ?? '').split(RegExp(r'[\s,]+'));
      if (token is! String ||
          token.isEmpty ||
          RegExp(r'\s').hasMatch(token) ||
          data['token_type']?.toString().toLowerCase() != 'bearer') {
        throw const SyncFailure('GitHub 未返回有效的登录凭据，请重试');
      }
      if (!scopes.contains('gist')) {
        throw const SyncFailure('未获得 Gist 权限，请重新登录并允许授权');
      }
      final profile = await _request(_apiBase.resolve('user'), token: token);
      _checkCancelled();
      final login = profile['login'];
      if (login is! String || login.isEmpty) {
        throw const SyncFailure('无法读取 GitHub 账号，请重新登录');
      }
      return GitHubAccount(token: token, login: login);
    }
  }

  static void _checkError(Map<String, dynamic> data) {
    if (data['error'] == null) return;
    throw SyncFailure(switch (data['error']) {
      'access_denied' => '已拒绝 GitHub 授权，可重新登录',
      'expired_token' => 'GitHub 验证码已过期，请重新登录',
      'device_flow_disabled' => '请先在 GitHub OAuth App 中启用 Device Flow',
      'incorrect_client_credentials' => 'GitHub OAuth App Client ID 无效',
      'incorrect_device_code' => 'GitHub 验证码无效，请重新登录',
      _ => 'GitHub 授权失败，请重试',
    });
  }

  Future<Map<String, dynamic>> _request(
    Uri uri, {
    Map<String, String>? form,
    String? token,
  }) async {
    _checkCancelled();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    _activeClient = client;
    try {
      return await (() async {
        final request = await client.openUrl(
          form == null ? 'GET' : 'POST',
          uri,
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.userAgentHeader, 'Harbor-SSH');
        if (token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        }
        if (form != null) {
          request.headers.contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
          );
          request.write(Uri(queryParameters: form).query);
        }
        final response = await request.close();
        if (response.statusCode != 200) {
          throw SyncFailure(switch (response.statusCode) {
            401 => 'GitHub 登录凭据无效，请重新登录',
            403 || 429 => 'GitHub 暂时拒绝了授权请求，请稍后重试',
            _ => 'GitHub 授权请求失败（${response.statusCode}）',
          });
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536) {
            throw const SyncFailure('GitHub 授权响应过大');
          }
          bytes.addAll(chunk);
        }
        return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      })().timeout(const Duration(seconds: 30));
    } on SyncFailure {
      _checkCancelled();
      rethrow;
    } catch (error) {
      _checkCancelled();
      if (error is TimeoutException) {
        throw const SyncFailure('GitHub 授权超时，请检查网络后重试');
      }
      throw const SyncFailure('无法完成 GitHub 授权，请检查网络后重试');
    } finally {
      client.close(force: true);
      _activeClient = null;
    }
  }
}
