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
      404 => 'Gist 不存在或无法访问，请检查 ID 和登录账号',
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
  GistSyncBackend(this.config, this.client);
  final CloudSyncConfig config;
  final GitHubGistClient client;

  @override
  Future<void> test() async {
    final id = config.normalizedGistId;
    final response = await client.request(
      'GET',
      id.isEmpty ? 'user' : 'gists/$id',
    );
    GitHubGistClient.check(response, {200});
  }

  @override
  Future<RemoteSyncData> read() async {
    final id = config.normalizedGistId;
    if (id.isEmpty) return const RemoteSyncData();
    final response = await client.request('GET', 'gists/$id');
    GitHubGistClient.check(response, {200});
    final data = GitHubGistClient.object(response);
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
    final id = config.normalizedGistId;
    if (id.isEmpty) {
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
        throw const SyncFailure('Gist 已创建但未返回有效 ID，请在 GitHub 找到该 Gist 后填写 ID');
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
