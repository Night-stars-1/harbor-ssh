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

/// One keychain item for every secret. macOS authorizes an item, not the app,
/// so a separate item per password asks for permission once per password.
class SecretStore implements KeyValueStore {
  SecretStore({SecretBackend? backend})
    : _backend =
          backend ??
          _SecureStorageBackend(
            const FlutterSecureStorage(
              mOptions: MacOsOptions(
                usesDataProtectionKeychain: false,
                accountName: 'dev.harborssh.credentials',
              ),
            ),
          );

  static const bundleKey = 'harbor.secrets.bundle.v1';
  final SecretBackend _backend;
  final _values = <String, String>{};
  var _loaded = false;
  Future<void> _chain = Future<void>.value();

  Future<T> _sync<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<String?> read(String key) => _sync(() async {
    await _ensure();
    return _values[key];
  });

  @override
  Future<void> write(String key, String value) => _sync(() async {
    await _ensure();
    if (_values[key] == value) return;
    _values[key] = value;
    await _persist();
  });

  @override
  Future<void> delete(String key) => _sync(() async {
    await _ensure();
    if (_values.remove(key) == null) return;
    await _persist();
  });

  Future<void> _ensure() async {
    if (_loaded) return;
    final bundled = await _backend.read(bundleKey);
    if (bundled != null) {
      _values.addAll(_decode(bundled));
      _loaded = true;
      return;
    }
    final legacy = await _backend.readAll();
    legacy.remove(bundleKey);
    if (legacy.isNotEmpty) {
      await _backend.write(bundleKey, jsonEncode(legacy));
      for (final key in legacy.keys) {
        await _backend.delete(key);
      }
    }
    _values.addAll(legacy);
    _loaded = true;
  }

  Future<void> _persist() => _backend.write(bundleKey, jsonEncode(_values));

  static Map<String, String> _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('凭据存档已损坏');
    return {
      for (final entry in decoded.entries)
        if (entry.value is String) '${entry.key}': entry.value as String,
    };
  }
}

abstract interface class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

class _SecureStorageBackend implements SecretBackend {
  const _SecureStorageBackend(this._storage);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
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
