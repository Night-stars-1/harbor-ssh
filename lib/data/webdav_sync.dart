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
  }) : _clientFactory = clientFactory ?? WebDavClient.new,
       _gistClientFactory = gistClientFactory ?? GitHubGistClient.new;
  final HostRepository repository;
  final WebDavClient Function(CloudSyncConfig) _clientFactory;
  final GitHubGistClient Function(CloudSyncConfig) _gistClientFactory;
  SyncBackend _backend(CloudSyncConfig config) =>
      config.provider == SyncProvider.gist
      ? GistSyncBackend(config, _gistClientFactory(config))
      : WebDavSyncBackend(_clientFactory(config));
  static const _settingsKey = 'harbor.sync.settings.v1';
  String _lastSyncKey(CloudSyncConfig config) => '${config.baselineKey}.last';
  CloudSyncConfig? settings;
  DateTime? lastSync;
  bool busy = false;
  String? message;
  bool failed = false;
  bool _disposed = false;
  String? _reviewedRemote;
  SyncSnapshot? _reviewedLocal;

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
  }

  Future<void> saveGitHubAccount(String token, String login) async {
    if (busy) throw const SyncFailure('正在同步，请稍后再修改账号');
    final next =
        (settings ??
                const CloudSyncConfig(
                  provider: SyncProvider.gist,
                  encryptionPassword: '',
                ))
            .withGitHubAccount(token, login);
    // Login is independent of completing the sync form. Tokens stay in the
    // same secure store as the existing configuration, never preferences.
    await repository.secrets.write(_settingsKey, jsonEncode(next.toJson()));
    settings = next;
    failed = false;
    message = token.isEmpty ? '已退出 GitHub 登录' : 'GitHub 登录成功';
    _notify();
  }

  Future<void> testConnection(CloudSyncConfig value) async {
    value.validate(requireEncryptionPassword: false);
    await _backend(value).test();
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
      // Retry persistence if a previous Gist creation succeeded before a local
      // settings write failed. Keep using that ID instead of creating another.
      await repository.secrets.write(_settingsKey, jsonEncode(config.toJson()));
      final storage = SyncStorage(repository);
      await storage.recover();
      final local = await storage.capture();
      final baseData = await repository.preferences.read(config.baselineKey);
      final base = baseData == null
          ? SyncSnapshot.empty()
          : await _decode(baseData, config);
      final backend = _backend(config);
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
