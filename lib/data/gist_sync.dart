import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sync_backend.dart';
import 'sync_config.dart';

const gistSyncFileName = 'harbor-ssh-sync.v1.json';

class GitHubResponse {
  const GitHubResponse(this.status, this.body, {this.rateLimited = false});
  final int status;
  final String body;
  final bool rateLimited;
}

class GitHubGistClient {
  GitHubGistClient(this.settings, {Uri? apiBase})
    : apiBase = apiBase ?? Uri.https('api.github.com', '/');
  final CloudSyncConfig settings;
  final Uri apiBase;
  static const maxBytes = 8 * 1024 * 1024;

  Future<GitHubResponse> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) =>
      _request(method, apiBase.resolve(path), body: body, authenticated: true);

  Future<GitHubResponse> readRaw(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'gist.githubusercontent.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw const SyncFailure('Gist 返回了无效的文件下载地址');
    }
    // Secret Gist raw URLs are readable without sending the account token.
    return _request('GET', uri, authenticated: false);
  }

  Future<GitHubResponse> _request(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    required bool authenticated,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      return await (() async {
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'Harbor-SSH');
        if (authenticated) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${settings.token.trim()}',
          );
          request.headers.set(
            HttpHeaders.acceptHeader,
            'application/vnd.github+json',
          );
          request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        }
        if (body != null) {
          final bytes = utf8.encode(jsonEncode(body));
          if (bytes.length > maxBytes) throw const SyncFailure('同步数据超过 8 MB');
          request.headers.contentType = ContentType.json;
          request.add(bytes);
        }
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const SyncFailure('Gist 同步数据超过 8 MB');
          }
          bytes.addAll(chunk);
        }
        return GitHubResponse(
          response.statusCode,
          utf8.decode(bytes, allowMalformed: true),
          rateLimited:
              response.statusCode == 429 ||
              response.headers.value('x-ratelimit-remaining') == '0',
        );
      })().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const SyncFailure('GitHub 连接超时，请检查网络');
    } on HandshakeException {
      throw const SyncFailure('无法验证 GitHub 服务器证书');
    } on SocketException {
      throw const SyncFailure('无法连接 GitHub，请检查网络');
    } on HttpException {
      throw const SyncFailure('GitHub 服务器响应异常');
    } finally {
      client.close(force: true);
    }
  }

  static void check(GitHubResponse response, Set<int> accepted) {
    if (accepted.contains(response.status)) return;
    if (response.rateLimited) throw const SyncFailure('GitHub 请求频率受限，请稍后再同步');
    throw SyncFailure(switch (response.status) {
      401 => 'GitHub 登录已失效，请重新登录',
      403 => '没有 Gist 访问权限，请重新登录并允许 Gist 授权',
      404 => '同步存档不存在或无法访问，请检查 GitHub 账号',
      409 || 412 => 'Gist 刚刚发生变化，请重新同步',
      422 => 'GitHub 拒绝了同步内容，请检查 Gist 和文件大小',
      301 || 302 || 307 || 308 => 'GitHub 返回了重定向，未发送凭据到其他地址',
      _ => 'GitHub 请求失败（${response.status}）',
    });
  }

  static Map<String, dynamic> object(GitHubResponse response) {
    try {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw const SyncFailure('GitHub 返回了无效的 Gist 数据');
    }
  }
}

class GistSyncBackend implements SyncBackend {
  GistSyncBackend(this.config, this.client) : _gistId = config.normalizedGistId;
  final CloudSyncConfig config;
  final GitHubGistClient client;
  String _gistId;
  String? _ownerLogin;

  bool _ownedByCurrentAccount(Map data) =>
      data['owner'] is Map &&
      (data['owner'] as Map)['login'] is String &&
      ((data['owner'] as Map)['login'] as String).toLowerCase() == _ownerLogin;

  /// Resolve the account's storage location before loading the merge baseline.
  /// The cached ID is only a hint; never use another account's public Gist.
  Future<String?> resolve() async {
    final userResponse = await client.request('GET', 'user');
    GitHubGistClient.check(userResponse, {200});
    final login = GitHubGistClient.object(userResponse)['login'];
    if (login is! String || login.isEmpty) {
      throw const SyncFailure('无法确认 GitHub 账号，请重新登录');
    }
    _ownerLogin = login.toLowerCase();
    if (_gistId.isNotEmpty) {
      final response = await client.request('GET', 'gists/$_gistId');
      GitHubGistClient.check(response, {200, 404});
      if (response.status == 200) {
        final data = GitHubGistClient.object(response);
        if (_ownedByCurrentAccount(data)) {
          if (data['files'] is! Map ||
              !(data['files'] as Map).containsKey(gistSyncFileName)) {
            throw const SyncFailure('云端同步文件已被删除，请在 GitHub 恢复该文件后重试');
          }
          return _gistId;
        }
      }
      // A stale cache can be recovered from the account listing. If nothing
      // remains, stop instead of recreating a deleted archive from local data.
      final recovered = await _findExisting();
      if (recovered == null) {
        throw const SyncFailure('找不到此账号的同步存档，请重新登录；已删除的存档需先在 GitHub 恢复');
      }
      _gistId = recovered;
      return recovered;
    }
    _gistId = await _findExisting() ?? '';
    return _gistId.isEmpty ? null : _gistId;
  }

  Future<String?> _findExisting() async {
    final candidates = <String>{};
    // Fail closed if listing is incomplete, rather than creating a duplicate.
    for (var page = 1; page <= 100; page++) {
      final response = await client.request(
        'GET',
        'gists?per_page=100&page=$page',
      );
      GitHubGistClient.check(response, {200});
      final Object? data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        throw const SyncFailure('无法读取 GitHub 同步存档列表，请重试');
      }
      if (data is! List) throw const SyncFailure('无法读取 GitHub 同步存档列表，请重试');
      for (final gist in data) {
        if (gist is! Map ||
            gist['files'] is! Map ||
            gist['owner'] is! Map ||
            (gist['owner'] as Map)['login'] is! String) {
          throw const SyncFailure('GitHub 同步存档列表不完整，请重试');
        }
        if (!_ownedByCurrentAccount(gist) ||
            !(gist['files'] as Map).containsKey(gistSyncFileName)) {
          continue;
        }
        final id = gist['id'];
        if (id is! String || !RegExp(r'^[a-fA-F0-9]{5,64}$').hasMatch(id)) {
          throw const SyncFailure('GitHub 同步存档信息无效，请重试');
        }
        candidates.add(id.toLowerCase());
      }
      if (candidates.length > 1) {
        throw const SyncFailure('此账号有多个 Harbor SSH 同步存档，请在 GitHub 确认保留的存档后重试');
      }
      if (data.length < 100) return candidates.firstOrNull;
    }
    throw const SyncFailure('GitHub 存档过多，暂时无法完成查找，请稍后重试');
  }

  @override
  Future<void> test() async {
    await resolve();
  }

  @override
  Future<RemoteSyncData> read() async {
    final id = _gistId;
    if (id.isEmpty) return const RemoteSyncData();
    final response = await client.request('GET', 'gists/$id');
    GitHubGistClient.check(response, {200});
    final data = GitHubGistClient.object(response);
    if (_ownerLogin != null && !_ownedByCurrentAccount(data)) {
      throw const SyncFailure('同步存档不属于当前 GitHub 账号，请重新登录');
    }
    final history = data['history'];
    final version =
        history is List && history.isNotEmpty && history.first is Map
        ? (history.first as Map)['version'] as String?
        : null;
    if (version == null || version.isEmpty || data['files'] is! Map) {
      throw const SyncFailure('无法读取 Gist 版本，请稍后重试');
    }
    final file = (data['files'] as Map)[gistSyncFileName];
    if (file == null) return RemoteSyncData(version: version);
    if (file is! Map) throw const SyncFailure('Gist 同步文件格式无效');
    String? content = file['content'] as String?;
    if (file['truncated'] == true || content == null) {
      final raw = file['raw_url'];
      if (raw is! String) throw const SyncFailure('无法下载完整的 Gist 同步文件');
      final downloaded = await client.readRaw(raw);
      GitHubGistClient.check(downloaded, {200});
      content = downloaded.body;
    }
    return RemoteSyncData(content: content, version: version);
  }

  @override
  Future<String?> write(String encrypted, RemoteSyncData previous) async {
    final files = <String, Object?>{
      gistSyncFileName: {'content': encrypted},
    };
    final id = _gistId;
    if (id.isEmpty) {
      if (_ownerLogin == null) await resolve();
      if (_gistId.isNotEmpty || await _findExisting() != null) {
        throw const SyncFailure('已找到另一台设备创建的同步存档，请重新同步');
      }
      final response = await client.request(
        'POST',
        'gists',
        body: {
          'description': 'Harbor SSH encrypted sync',
          'public': false,
          'files': files,
        },
      );
      GitHubGistClient.check(response, {201});
      final created = GitHubGistClient.object(response)['id'];
      if (created is! String ||
          !RegExp(r'^[a-fA-F0-9]{5,64}$').hasMatch(created)) {
        throw const SyncFailure('同步存档已创建但返回信息不完整，请重新同步以自动查找');
      }
      return created.toLowerCase();
    }
    // Gist PATCH has no documented atomic If-Match guarantee. Re-read the
    // revision and content immediately before updating; never treat its ETag
    // as the WebDAV compare-and-swap contract. Gist retains revision history.
    final current = await read();
    if (current.version != previous.version ||
        current.content != previous.content) {
      throw const SyncFailure('Gist 刚刚发生变化，请重新同步');
    }
    final response = await client.request(
      'PATCH',
      'gists/$id',
      body: {'files': files},
    );
    GitHubGistClient.check(response, {200});
    return null;
  }
}
