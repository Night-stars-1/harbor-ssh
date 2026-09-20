import 'dart:convert';

class SyncFailure implements Exception {
  const SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

enum SyncProvider { webdav, gist }

class CloudSyncConfig {
  const CloudSyncConfig({
    this.provider = SyncProvider.webdav,
    this.url = '',
    this.username = '',
    this.password = '',
    this.gistId = '',
    this.token = '',
    this.githubLogin = '',
    required this.encryptionPassword,
    this.automatic = false,
  });
  final String url, username, password, encryptionPassword;
  final SyncProvider provider;
  final String gistId, token, githubLogin;
  final bool automatic;

  String get providerName =>
      provider == SyncProvider.webdav ? 'WebDAV' : 'GitHub Gist';

  String get normalizedGistId {
    final input = gistId.trim();
    if (input.isEmpty) return '';
    if (RegExp(r'^[a-fA-F0-9]{5,64}$').hasMatch(input)) {
      return input.toLowerCase();
    }
    final uri = Uri.tryParse(input);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'gist.github.com' &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery) {
      final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
      if (parts.isNotEmpty &&
          parts.length <= 2 &&
          RegExp(r'^[a-fA-F0-9]{5,64}$').hasMatch(parts.last)) {
        return parts.last.toLowerCase();
      }
    }
    throw const SyncFailure('请输入有效的 Gist ID 或 gist.github.com 链接');
  }

  CloudSyncConfig withGistId(String id) => CloudSyncConfig(
    provider: provider,
    url: url,
    username: username,
    password: password,
    encryptionPassword: encryptionPassword,
    automatic: automatic,
    token: token,
    githubLogin: githubLogin,
    gistId: id,
  );

  CloudSyncConfig withGitHubAccount(String token, String login) {
    final sameAccount =
        token.isNotEmpty &&
        login.isNotEmpty &&
        login.toLowerCase() == githubLogin.toLowerCase();
    return CloudSyncConfig(
      provider: provider,
      url: url,
      username: username,
      password: password,
      encryptionPassword: encryptionPassword,
      automatic: !sameAccount && provider == SyncProvider.gist
          ? false
          : automatic,
      token: token,
      githubLogin: login,
      gistId: sameAccount ? gistId : '',
    );
  }

  Uri get directory {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw const SyncFailure('请输入 HTTPS WebDAV 目录地址');
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  void validate({bool requireEncryptionPassword = true}) {
    if (provider == SyncProvider.gist) {
      normalizedGistId;
      if (token.trim().isEmpty || RegExp(r'\s').hasMatch(token.trim())) {
        throw const SyncFailure('请先登录 GitHub');
      }
    } else {
      directory;
      if (username.trim().isEmpty || password.isEmpty) {
        throw const SyncFailure('请填写 WebDAV 用户名和密码');
      }
      if (username.contains(':')) throw const SyncFailure('WebDAV 用户名不能包含冒号');
    }
    if (requireEncryptionPassword && encryptionPassword.length < 12) {
      throw const SyncFailure('同步加密密码至少需要 12 个字符');
    }
  }

  String get baselineKey => provider == SyncProvider.gist
      ? 'harbor.sync.gist.base.${normalizedGistId.isEmpty ? 'new' : normalizedGistId}'
      : 'harbor.sync.base.${base64Url.encode(utf8.encode('$directory\n$username'))}';
  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'gistId': gistId,
    'token': token,
    'githubLogin': githubLogin,
    'url': url,
    'username': username,
    'password': password,
    'encryptionPassword': encryptionPassword,
    'automatic': automatic,
  };
  factory CloudSyncConfig.fromJson(Map<String, dynamic> json) =>
      CloudSyncConfig(
        provider: SyncProvider.values.byName(
          json['provider'] as String? ?? 'webdav',
        ),
        gistId: json['gistId'] as String? ?? '',
        token: json['token'] as String? ?? '',
        githubLogin: json['githubLogin'] as String? ?? '',
        url: json['url'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        encryptionPassword: json['encryptionPassword'] as String,
        automatic: json['automatic'] as bool? ?? false,
      );
}
