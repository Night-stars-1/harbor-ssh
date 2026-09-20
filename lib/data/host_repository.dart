import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/host.dart';

abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PreferencesStore implements KeyValueStore {
  final _preferences = SharedPreferencesAsync();
  @override
  Future<String?> read(String key) => _preferences.getString(key);
  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);
  @override
  Future<void> delete(String key) => _preferences.remove(key);
}

class SecretStore implements KeyValueStore {
  final _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(
      usesDataProtectionKeychain: false,
      accountName: 'dev.harborssh.credentials',
    ),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class HostKeyMismatch implements Exception {
  const HostKeyMismatch(this.endpoint, this.expected, this.actual);
  final String endpoint, expected, actual;
  @override
  String toString() =>
      '主机 $endpoint 的指纹已改变，连接已阻止。\n已保存：$expected\n当前：$actual\n请先向服务器管理员核实，再在主机菜单中重置指纹。';
}

typedef TrustHost = Future<bool> Function(String type, String fingerprint);

class HostRepository {
  HostRepository({required this.preferences, required this.secrets});
  factory HostRepository.platform() =>
      HostRepository(preferences: PreferencesStore(), secrets: SecretStore());
  final KeyValueStore preferences, secrets;
  static const _hostsKey = 'harbor.hosts.v1';
  static const _usersKey = 'harbor.users.v1';
  Future<void> _keyWrites = Future<void>.value();

  Future<T> _serializeKeys<T>(Future<T> Function() action) {
    final result = _keyWrites.then((_) => action());
    _keyWrites = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<Host>> loadHosts() async {
    final value = await preferences.read(_hostsKey);
    if (value == null) return [];
    return (jsonDecode(value) as List)
        .map((item) => Host.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveHosts(List<Host> hosts) => preferences.write(
    _hostsKey,
    jsonEncode(hosts.map((h) => h.toJson()).toList()),
  );
  Future<Credentials?> credentials(String id) async {
    final value = await secrets.read('harbor.credentials.$id');
    return value == null
        ? null
        : Credentials.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> saveCredentials(String id, Credentials? value) => value == null
      ? secrets.delete('harbor.credentials.$id')
      : secrets.write('harbor.credentials.$id', jsonEncode(value.toJson()));
  Future<List<SshUser>> loadUsers() async {
    final value = await preferences.read(_usersKey);
    if (value == null) return [];
    return (jsonDecode(value) as List)
        .map((item) => SshUser.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveUsers(List<SshUser> users) => preferences.write(
    _usersKey,
    jsonEncode(users.map((u) => u.toJson()).toList()),
  );
  Future<Credentials?> userCredentials(String id) => credentials('user.$id');
  Future<void> saveUserCredentials(String id, Credentials? value) =>
      saveCredentials('user.$id', value);
  String _hostKey(Host host) =>
      'harbor.known.${base64Url.encode(utf8.encode(host.endpoint))}';
  Future<bool> verifyHost(
    Host host,
    String type,
    String fingerprint,
    TrustHost prompt,
  ) async {
    final key = _hostKey(host);
    final presented = '$type $fingerprint';
    final known = await secrets.read(key);
    if (known != null) {
      if (known != presented) {
        throw HostKeyMismatch(host.endpoint, known, presented);
      }
      return true;
    }
    if (!await prompt(type, fingerprint)) return false;
    return _serializeKeys(() async {
      final latest = await secrets.read(key);
      if (latest != null && latest != presented) {
        throw HostKeyMismatch(host.endpoint, latest, presented);
      }
      await secrets.write(key, presented);
      return true;
    });
  }

  Future<void> forgetHostKey(Host host) =>
      _serializeKeys(() => secrets.delete(_hostKey(host)));
}
