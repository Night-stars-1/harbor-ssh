import 'package:flutter/foundation.dart';

enum AuthMethod { password, privateKey }

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
  });
  final String id, name, address, username, userId;
  final List<String> tags;
  final int port;
  final AuthMethod authMethod;
  final bool favorite;
  String get endpoint => '${address.toLowerCase()}:$port';
  String get destination =>
      '$username@${address.contains(':') ? '[$address]' : address}:$port';
  Host withFavorite(bool value) => Host(
    id: id,
    name: name,
    address: address,
    username: username,
    port: port,
    tags: tags,
    authMethod: authMethod,
    favorite: value,
    userId: userId,
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
