import 'package:flutter/foundation.dart';

enum AuthMethod { password, privateKey, none }

@immutable
class Host {
  const Host({
    required this.id,
    required this.name,
    required this.address,
    required this.username,
    this.port = 22,
    this.tags = const [],
    this.authMethod = AuthMethod.password,
    this.favorite = false,
    this.userId = '',
    this.jumpHostId = '',
    this.sftpPath = '',
    this.sftpBookmarks = const [],
    this.icon = '',
  });
  final String id, name, address, username, userId, jumpHostId;

  /// 列表、会话和标签中显示的图标 id；为空或本版本不认识时显示默认服务器图标。
  /// 原样保存不认识的 id，新版本同步来的图标不会被旧版本抹掉。
  final String icon;

  /// SFTP 打开该主机时进入的目录；为空时进入登录用户的主目录。
  final String sftpPath;
  String get sftpStartPath => sftpPath.isEmpty ? '~' : sftpPath;

  /// SFTP 中收藏的远程目录（服务器返回的绝对路径），按收藏顺序排列。
  final List<String> sftpBookmarks;
  final List<String> tags;
  final int port;
  final AuthMethod authMethod;
  final bool favorite;
  String get endpoint => '${address.toLowerCase()}:$port';
  String get destination =>
      '$username@${address.contains(':') ? '[$address]' : address}:$port';
  Host withFavorite(bool value) => _copy(favorite: value);
  Host withSftpBookmarks(List<String> paths) => _copy(sftpBookmarks: paths);
  Host _copy({bool? favorite, List<String>? sftpBookmarks}) => Host(
    id: id,
    name: name,
    address: address,
    username: username,
    port: port,
    tags: tags,
    authMethod: authMethod,
    favorite: favorite ?? this.favorite,
    userId: userId,
    jumpHostId: jumpHostId,
    sftpPath: sftpPath,
    sftpBookmarks: sftpBookmarks ?? this.sftpBookmarks,
    icon: icon,
  );
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'username': username,
    'port': port,
    'tags': tags,
    'authMethod': authMethod.name,
    'favorite': favorite,
    'userId': userId,
    if (jumpHostId.isNotEmpty) 'jumpHostId': jumpHostId,
    if (sftpPath.isNotEmpty) 'sftpPath': sftpPath,
    if (sftpBookmarks.isNotEmpty) 'sftpBookmarks': sftpBookmarks,
    if (icon.isNotEmpty) 'icon': icon,
  };
  factory Host.fromJson(Map<String, dynamic> json) => Host(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String,
    username: json['username'] as String,
    port: json['port'] as int,
    tags: _tagsFromJson(json),
    authMethod: AuthMethod.values.byName(json['authMethod'] as String),
    favorite: json['favorite'] as bool? ?? false,
    userId: json['userId'] as String? ?? '',
    jumpHostId: json['jumpHostId'] as String? ?? '',
    sftpPath: json['sftpPath'] as String? ?? '',
    sftpBookmarks: [
      for (final path in json['sftpBookmarks'] as List? ?? const [])
        if (path is String && path.isNotEmpty) path,
    ],
    icon: json['icon'] is String ? json['icon'] as String : '',
  );

  /// `tags` 数组优先；仅当字段缺失（或为 null）时才把旧数据的
  /// `group` 字符串降级为单个标签，显式的空数组不会回落到旧字段。
  static List<String> _tagsFromJson(Map<String, dynamic> json) {
    final value = json['tags'];
    if (value != null) {
      if (value is! List) throw const FormatException('tags 必须是字符串数组');
      return _normalizeTags(value);
    }
    final legacy = json['group'];
    if (legacy == null) return const [];
    if (legacy is! String) throw const FormatException('group 必须是字符串');
    return _normalizeTags([legacy]);
  }

  /// 去除首尾空白、丢弃空项与重复项（保持顺序，区分大小写）。
  static List<String> _normalizeTags(Iterable<Object?> values) {
    final tags = <String>[];
    for (final value in values) {
      if (value is! String) throw const FormatException('标签必须是字符串');
      final tag = value.trim();
      if (tag.isEmpty || tags.contains(tag)) continue;
      tags.add(tag);
    }
    return tags;
  }
}

/// Resolve the outermost jump host first, keeping the supplied target's edits.
/// Missing references and cycles must never fall back to a direct connection.
List<Host> resolveSshRoute(Host target, Iterable<Host> hosts) {
  final byId = {for (final host in hosts) host.id: host};
  final visited = <String>{};
  final route = <Host>[];
  var current = target;
  while (true) {
    if (!visited.add(current.id)) {
      throw const FormatException('中转主机存在循环引用，请修改连接配置。');
    }
    route.add(current);
    if (current.jumpHostId.isEmpty) return route.reversed.toList();
    final next = byId[current.jumpHostId];
    if (next == null) {
      throw FormatException('「${current.name}」的中转主机已不存在，请重新选择。');
    }
    current = next;
  }
}

@immutable
class SshUser {
  const SshUser({
    required this.id,
    required this.name,
    required this.username,
    this.authMethod = AuthMethod.password,
    this.publicKey = '',
  });
  final String id, name, username, publicKey;
  final AuthMethod authMethod;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'username': username,
    'authMethod': authMethod.name,
    'publicKey': publicKey,
  };
  factory SshUser.fromJson(Map<String, dynamic> json) => SshUser(
    id: json['id'] as String,
    name: json['name'] as String,
    username: json['username'] as String,
    authMethod: AuthMethod.values.byName(json['authMethod'] as String),
    publicKey: json['publicKey'] as String? ?? '',
  );
}

@immutable
class Credentials {
  const Credentials({
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
  });
  final String password, privateKey, passphrase;
  Map<String, String> toJson() => {
    'password': password,
    'privateKey': privateKey,
    'passphrase': passphrase,
  };
  factory Credentials.fromJson(Map<String, dynamic> json) => Credentials(
    password: json['password'] as String? ?? '',
    privateKey: json['privateKey'] as String? ?? '',
    passphrase: json['passphrase'] as String? ?? '',
  );
}
