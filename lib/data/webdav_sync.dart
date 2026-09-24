import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/sync_snapshot.dart';
import 'host_repository.dart';
import 'sync_cipher.dart';
import 'sync_storage.dart';
import 'sync_config.dart';
import 'sync_backend.dart';
import 'gist_sync.dart';
import 'github_device_auth.dart';

export 'sync_config.dart';

class WebDavResponse {
  const WebDavResponse(this.status, this.body, this.etag);
  final int status;
  final String body;
  final String? etag;
}

class WebDavClient {
  WebDavClient(this.settings);
  final CloudSyncConfig settings;
  static const maxBytes = 8 * 1024 * 1024;

  Future<WebDavResponse> request(
    String method, {
    bool directory = false,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      return await (() async {
        final uri = directory
            ? settings.directory
            : settings.directory.resolve('harbor-ssh-sync.v1.json');
        final request = await client.openUrl(method, uri);
        // Never forward WebDAV authentication through redirects.
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode('${settings.username}:${settings.password}'))}',
        );
        headers.forEach(request.headers.set);
        if (body != null) {
          final bytes = utf8.encode(body);
          if (bytes.length > maxBytes) throw const SyncFailure('同步数据超过 8 MB');
          request.headers.contentType = ContentType.json;
          request.add(bytes);
        }
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const SyncFailure('云端同步数据超过 8 MB');
          }
          bytes.addAll(chunk);
        }
        return WebDavResponse(
          response.statusCode,
          utf8.decode(bytes, allowMalformed: true),
          response.headers.value(HttpHeaders.etagHeader),
        );
      })().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const SyncFailure('连接超时，请检查 WebDAV 地址和网络');
    } on HandshakeException {
      throw const SyncFailure('无法验证 WebDAV 服务器证书');
    } on SocketException {
      throw const SyncFailure('无法连接 WebDAV 服务器，请检查网络');
    } on HttpException {
      throw const SyncFailure('WebDAV 服务器响应异常');
    } finally {
      client.close(force: true);
    }
  }

  static void check(WebDavResponse response, Set<int> accepted) {
    if (accepted.contains(response.status)) return;
    throw SyncFailure(switch (response.status) {
      401 || 403 => 'WebDAV 认证失败或没有访问权限，请检查账号和应用密码',
      404 || 409 => 'WebDAV 目录不存在，请填写已创建的目录地址',
      412 => '云端数据刚刚发生变化，请重新同步',
      301 || 302 || 307 || 308 => 'WebDAV 地址发生重定向，请填写最终目录地址',
      423 => '云端文件正在被占用，请稍后重试',
      507 => 'WebDAV 存储空间不足',
      _ => 'WebDAV 请求失败（${response.status}）',
    });
  }
}

class WebDavSyncBackend implements SyncBackend {
  WebDavSyncBackend(this.client);
  final WebDavClient client;
  @override
  Future<void> test() async {
    final response = await client.request(
      'PROPFIND',
      directory: true,
      headers: {'Depth': '0'},
    );
    WebDavClient.check(response, {200, 207});
  }

  @override
  Future<RemoteSyncData> read() async {
    final response = await client.request('GET');
    WebDavClient.check(response, {200, 404});
    return RemoteSyncData(
      content: response.status == 404 ? null : response.body,
      version: response.etag,
    );
  }

  @override
  Future<String?> write(String encrypted, RemoteSyncData previous) async {
    if (previous.content != null &&
        (previous.version == null || previous.version!.startsWith('W/'))) {
      throw const SyncFailure('服务器未提供可用于防冲突的 ETag，无法安全更新同步文件');
    }
    final written = await client.request(
      'PUT',
      body: encrypted,
      headers: {
        if (previous.content == null)
          'If-None-Match': '*'
        else
          'If-Match': previous.version!,
      },
    );
    WebDavClient.check(written, {200, 201, 204});
    return null;
  }
}

class CloudSync extends ChangeNotifier {
  CloudSync(
    this.repository, {
    WebDavClient Function(CloudSyncConfig)? clientFactory,
    GitHubGistClient Function(CloudSyncConfig)? gistClientFactory,
    GitHubDeviceAuth Function()? githubAuthFactory,
    DateTime Function()? now,
  }) : _clientFactory = clientFactory ?? WebDavClient.new,
       _gistClientFactory = gistClientFactory ?? GitHubGistClient.new,
       _githubAuthFactory = githubAuthFactory ?? GitHubDeviceAuth.new,
       _now = now ?? DateTime.now;
  final HostRepository repository;
  final WebDavClient Function(CloudSyncConfig) _clientFactory;
  final GitHubGistClient Function(CloudSyncConfig) _gistClientFactory;
  final GitHubDeviceAuth Function() _githubAuthFactory;
  final DateTime Function() _now;
  SyncBackend _backend(CloudSyncConfig config) =>
      config.provider == SyncProvider.gist
      ? GistSyncBackend(config, _gistClientFactory(config))
      : WebDavSyncBackend(_clientFactory(config));
  static const _settingsKey = 'harbor.sync.settings.v1';

  /// Device-flow access tokens live eight hours. Renew shortly before they
  /// expire so a slow transfer never starts on a dead token.
  static const _renewWindow = Duration(minutes: 2);
  String _lastSyncKey(CloudSyncConfig config) => '${config.baselineKey}.last';
  CloudSyncConfig? settings;
  DateTime? lastSync;
  bool busy = false;
  String? message;
  bool failed = false;
  bool _disposed = false;
  String? _reviewedRemote;
  SyncSnapshot? _reviewedLocal;

  /// A rotating refresh token is single-use, and GitHub rotates it before the
  /// exchange returns: the whole renewal — exchange, validation, secure write —
  /// is shared per token so a second caller cannot spend it from under the
  /// first and get a spurious re-login.
  Future<CloudSyncConfig>? _renewal;
  String _renewalToken = '';

  /// Credential mutations share one queue, so a renewal that lands after a
  /// login or logout was already saved can never write its stale pair back.
  Future<void> _credentialWrites = Future<void>.value();

  Future<T> _serializeCredentials<T>(Future<T> Function() action) {
    final result = _credentialWrites.then((_) => action());
    _credentialWrites = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final value = await repository.secrets.read(_settingsKey);
      settings = value == null
          ? null
          : CloudSyncConfig.fromJson(jsonDecode(value) as Map<String, dynamic>);
      lastSync = settings == null
          ? null
          : DateTime.tryParse(
              await repository.preferences.read(_lastSyncKey(settings!)) ?? '',
            );
    } catch (_) {
      failed = true;
      message = '无法读取云同步设置，请重新配置';
    }
    _notify();
  }

  Future<void> saveSettings(CloudSyncConfig next) async {
    if (busy) throw const SyncFailure('正在同步，请稍后再修改设置');
    await _serializeCredentials(() async {
      // A sync may have started while this save waited in the queue: it must
      // never change the settings the running sync is working from.
      if (busy) throw const SyncFailure('正在同步，请稍后再修改设置');
      // The independent settings window can hold a snapshot from before an
      // automatic token rotation. Never restore an already-spent refresh token
      // when saving unrelated form fields for the same signed-in account.
      next = _withStoredCredentials(next, settings, preserveSameAccount: true);
      next.validate();
      await repository.secrets.write(_settingsKey, jsonEncode(next.toJson()));
      if (settings?.baselineKey != next.baselineKey ||
          settings?.encryptionPassword != next.encryptionPassword) {
        _reviewedRemote = null;
        _reviewedLocal = null;
        lastSync = DateTime.tryParse(
          await repository.preferences.read(_lastSyncKey(next)) ?? '',
        );
      }
      settings = next;
      failed = false;
      message = '同步设置已保存';
      _notify();
    });
  }

  Future<void> saveGitHubAccount(
    String token,
    String login, {
    String refreshToken = '',
    DateTime? expiresAt,
    DateTime? refreshExpiresAt,
  }) async {
    if (busy) throw const SyncFailure('正在同步，请稍后再修改账号');
    await _serializeCredentials(() async {
      // A sync may have started while this save waited in the queue: it must
      // never change the credentials the running sync is working from.
      if (busy) throw const SyncFailure('正在同步，请稍后再修改账号');
      final next =
          (settings ??
                  const CloudSyncConfig(
                    provider: SyncProvider.gist,
                    encryptionPassword: '',
                  ))
              .withGitHubAccount(
                token,
                login,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                refreshExpiresAt: refreshExpiresAt,
              );
      // Login is independent of completing the sync form. Tokens stay in the
      // same secure store as the existing configuration, never preferences.
      await repository.secrets.write(_settingsKey, jsonEncode(next.toJson()));
      if (settings?.gistId != next.gistId &&
          next.provider == SyncProvider.gist) {
        _reviewedLocal = null;
        _reviewedRemote = null;
        lastSync = null;
      }
      settings = next;
      failed = false;
      message = token.isEmpty ? '已退出 GitHub 登录' : 'GitHub 登录成功';
      _notify();
    });
  }

  Future<void> testConnection(CloudSyncConfig value) async {
    value.validate(requireEncryptionPassword: false);
    final stored = settings;
    // A connection test never persists the form's unsaved fields: only the
    // stored account renews its own credentials, and the form fields are
    // merged back for this one test.
    final renewed =
        value.provider == SyncProvider.gist &&
            _sameSignedInAccount(value, stored)
        ? await _renewGitHubAuth(stored!, github: true)
        : stored;
    await _backend(_withStoredCredentials(value, renewed)).test();
  }

  /// Whether the submitted config describes the stored signed-in account: the
  /// same login, with either the rotating pair or no credential of its own.
  /// Provider-independent, because a settings window keeps the account's
  /// credentials in its form while the user switches between WebDAV and Gist.
  bool _sameSignedInAccount(CloudSyncConfig value, CloudSyncConfig? stored) =>
      stored != null &&
      stored.refreshToken.isNotEmpty &&
      value.githubLogin.trim().isNotEmpty &&
      value.githubLogin.trim().toLowerCase() ==
          stored.githubLogin.trim().toLowerCase() &&
      (value.refreshToken.isNotEmpty || value.token.trim().isEmpty);

  /// Form fields as they were typed, credentials from the secure store.
  ///
  /// A background sync rotates the token pair, so a form snapshot of the same
  /// signed-in account may still hold the previous one; testing it would fail
  /// with 401 even though the account is fine. Saves preserve whatever
  /// credentials the secure store currently holds for the same account;
  /// explicit account replacement goes through [saveGitHubAccount].
  CloudSyncConfig _withStoredCredentials(
    CloudSyncConfig value,
    CloudSyncConfig? stored, {
    bool preserveSameAccount = false,
  }) {
    final sameLogin =
        stored != null &&
        stored.token.isNotEmpty &&
        value.githubLogin.trim().isNotEmpty &&
        value.githubLogin.trim().toLowerCase() ==
            stored.githubLogin.trim().toLowerCase();
    if (!sameLogin ||
        (!preserveSameAccount && !_sameSignedInAccount(value, stored))) {
      return value;
    }
    return CloudSyncConfig(
      provider: value.provider,
      url: value.url,
      username: value.username,
      password: value.password,
      encryptionPassword: value.encryptionPassword,
      automatic: value.automatic,
      gistId: value.gistId,
      githubLogin: value.githubLogin,
      token: stored.token,
      refreshToken: stored.refreshToken,
      expiresAt: stored.expiresAt,
      refreshExpiresAt: stored.refreshExpiresAt,
    );
  }

  /// Exchange the stored refresh token for a new access token when the current
  /// one is expired or about to expire. GitHub rotates the refresh token on
  /// every exchange, so the new pair reaches the secure store before any
  /// GitHub request can use it. Without a refresh token the saved credentials
  /// are used as they are, exactly like a non-expiring OAuth token.
  Future<CloudSyncConfig> _renewGitHubAuth(
    CloudSyncConfig config, {
    required bool github,
  }) {
    // [github] is the caller's intent: a stored WebDAV config may still hold
    // the signed-in GitHub account, and only a GitHub request may renew it —
    // a WebDAV sync never rotates the pair it does not use.
    if (!github || config.refreshToken.isEmpty) {
      return Future.value(config);
    }
    final expiresAt = config.expiresAt;
    if (expiresAt != null && expiresAt.isAfter(_now().add(_renewWindow))) {
      return Future.value(config);
    }
    final token = config.refreshToken;
    final active = _renewal;
    if (active != null && _renewalToken == token) return active;
    // The shared future spans the exchange, its validation and the secure
    // write: the token is already rotated at GitHub once the reply arrives, so
    // a second caller must wait for the stored pair instead of spending it.
    late final Future<CloudSyncConfig> renewal;
    renewal = _renew(config, token).whenComplete(() {
      if (identical(_renewal, renewal)) {
        _renewal = null;
        _renewalToken = '';
      }
    });
    _renewal = renewal;
    _renewalToken = token;
    return renewal;
  }

  /// Shares one in-flight renewal between callers holding the same stored
  /// token, so a manual test and an automatic sync cannot spend it twice.
  Future<CloudSyncConfig> _renew(CloudSyncConfig config, String token) async {
    final GitHubRenewal renewal;
    try {
      renewal = await _githubAuthFactory().refresh(token);
    } catch (_) {
      // Keep every stored credential untouched: a signed-in user is never
      // logged out and an expired token is never reused as a fallback.
      throw const SyncFailure('GitHub 登录凭据已失效，请重新登录');
    }
    // The queue keeps this check-and-write atomic against a login or logout
    // saved while the exchange was in flight.
    return _serializeCredentials(() async {
      final current = settings;
      if (current == null) {
        throw const SyncFailure('GitHub 登录状态已更新，请重新同步');
      }
      if (current.token == renewal.token &&
          current.refreshToken == renewal.refreshToken) {
        // A concurrent caller already stored this exchange; those settings are
        // the authoritative ones, so they are adopted instead of rewritten.
        if (current.provider != config.provider) {
          throw const SyncFailure('GitHub 登录状态已更新，请重新同步');
        }
        return current;
      }
      // Any credential replacement wins, including an explicit re-login to
      // the same account with a non-expiring token. Provider-only saves keep
      // this refresh token through [_withStoredCredentials].
      if (current.refreshToken != token) {
        throw const SyncFailure('GitHub 登录状态已更新，请重新同步');
      }
      if (current.githubLogin.trim().isEmpty) {
        throw const SyncFailure('GitHub 登录凭据不完整，请重新登录');
      }
      // GitHub invalidates the submitted refresh token as soon as it answers,
      // so the rotated pair is stored — even when the form switched provider
      // meanwhile, because discarding it would leave the account with nothing
      // but a spent credential. Only the credentials change: every other field
      // keeps whatever the stored settings hold now.
      final renewed = current.withGitHubAccount(
        renewal.token,
        current.githubLogin,
        refreshToken: renewal.refreshToken,
        expiresAt: renewal.expiresAt,
        refreshExpiresAt: renewal.refreshExpiresAt,
      );
      // Never persist a downgraded credential: a renewal that lost its rotating
      // pair would fail again at the next expiry with no way to recover.
      if (renewed.refreshToken != renewal.refreshToken ||
          renewed.refreshToken.isEmpty ||
          renewed.expiresAt != renewal.expiresAt) {
        throw const SyncFailure('GitHub 未返回可续期的登录凭据，请重新登录');
      }
      await repository.secrets.write(
        _settingsKey,
        jsonEncode(renewed.toJson()),
      );
      settings = renewed;
      _notify();
      // The caller started on another account or provider, so its operation
      // must not continue with these credentials.
      if (renewed.provider != config.provider) {
        throw const SyncFailure('GitHub 登录状态已更新，请重新同步');
      }
      return renewed;
    });
  }

  Future<SyncSnapshot> _decode(String data, CloudSyncConfig config) async {
    try {
      return SyncSnapshot.decode(
        await decryptSync(data, config.encryptionPassword),
      );
    } catch (_) {
      throw const SyncFailure('解密失败，请确认各设备使用相同的同步加密密码，且云端文件未损坏');
    }
  }

  Future<void> synchronize({SyncConflictChoice? choice}) async {
    var config = settings;
    if (config == null) throw const SyncFailure('请先配置云同步');
    if (busy) throw const SyncFailure('正在同步，请稍后重试');
    config.validate();
    busy = true;
    failed = false;
    message = '正在同步';
    _notify();
    try {
      // Renew before anything reaches GitHub, so a failed refresh leaves the
      // local snapshot, the stored credentials and the remote archive alone.
      config = await _renewGitHubAuth(
        config,
        github: config.provider == SyncProvider.gist,
      );
      // Retry persistence if a previous Gist creation succeeded before a local
      // settings write failed. Keep using that ID instead of creating another.
      await repository.secrets.write(_settingsKey, jsonEncode(config.toJson()));
      final storage = SyncStorage(repository);
      await storage.recover();
      final backend = _backend(config);
      if (backend is GistSyncBackend) {
        final resolvedId = await backend.resolve();
        if (resolvedId != null && resolvedId != config.normalizedGistId) {
          config = config.withGistId(resolvedId);
          settings = config;
          _notify();
          await repository.secrets.write(
            _settingsKey,
            jsonEncode(config.toJson()),
          );
        }
      }
      final local = await storage.capture();
      final baseData = await repository.preferences.read(config.baselineKey);
      final base = baseData == null
          ? SyncSnapshot.empty()
          : await _decode(baseData, config);
      final response = await backend.read();
      if (response.content == null && baseData != null) {
        throw const SyncFailure('云端同步文件已被删除，请恢复该文件或更换同步位置');
      }
      final remote = response.content == null
          ? SyncSnapshot.empty()
          : await _decode(response.content!, config);
      if (choice != null &&
          (response.content != _reviewedRemote ||
              !SyncSnapshot.same(local.records, _reviewedLocal?.records))) {
        throw const SyncFailure('冲突内容已发生变化，请重新同步并选择版本');
      }
      late final SyncSnapshot merged;
      try {
        merged = SyncSnapshot.merge(
          local: local,
          remote: remote,
          base: base,
          choice: choice,
        );
      } on SyncConflict {
        _reviewedRemote = response.content;
        _reviewedLocal = local;
        rethrow;
      }
      var encrypted = response.content;
      if (response.content == null ||
          !SyncSnapshot.same(merged.records, remote.records)) {
        encrypted = await encryptSync(
          merged.encode(),
          config.encryptionPassword,
        );
        final createdId = await backend.write(encrypted, response);
        if (createdId != null) {
          config = config.withGistId(createdId);
          settings = config;
          _notify();
          await repository.secrets.write(
            _settingsKey,
            jsonEncode(config.toJson()),
          );
        }
      }
      if (!SyncSnapshot.same(local.records, merged.records)) {
        await storage.apply(merged);
      }
      await repository.preferences.write(config.baselineKey, encrypted!);
      lastSync = DateTime.now();
      await repository.preferences.write(
        _lastSyncKey(config),
        lastSync!.toIso8601String(),
      );
      message = '同步完成';
      _reviewedRemote = null;
      _reviewedLocal = null;
    } on SyncConflict {
      failed = true;
      message = '存在冲突，请打开云同步选择保留的版本';
      rethrow;
    } catch (error) {
      failed = true;
      message = error is SyncFailure ? error.message : '同步未完成，请检查网络与本地存储后重试';
      throw SyncFailure(message!);
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

typedef WebDavSettings = CloudSyncConfig;
typedef WebDavSync = CloudSync;
