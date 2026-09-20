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
    this.group = '',
    this.authMethod = AuthMethod.password,
    this.favorite = false,
    this.userId = '',
  });
  final String id, name, address, username, group, userId;
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
    group: group,
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
    'group': group,
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
    group: json['group'] as String? ?? '',
    authMethod: AuthMethod.values.byName(json['authMethod'] as String),
    favorite: json['favorite'] as bool? ?? false,
    userId: json['userId'] as String? ?? '',
  );
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
