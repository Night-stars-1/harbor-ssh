import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// Bundle secrets only on macOS, where authorization is per keychain item.
/// Other platforms keep the per-key layout understood by earlier releases.
class SecretStore implements KeyValueStore {
  SecretStore({SecretBackend? backend, bool? useBundle})
    : _useBundle =
          useBundle ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS),
      _backend =
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
  final bool _useBundle;
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
    if (!_useBundle) return _backend.read(key);
    final value = _values[key];
    if (value != null) return value;
    // Some platform backends cannot enumerate every legacy item. An existing
    // bundle is therefore not proof that migration included this exact key.
    final legacy = await _backend.read(key);
    if (legacy == null) return null;
    await _persist({..._values, key: legacy});
    await _backend.delete(key);
    return legacy;
  });

  @override
  Future<void> write(String key, String value) => _sync(() async {
    await _ensure();
    if (!_useBundle) return _backend.write(key, value);
    if (_values[key] == value) return;
    await _persist({..._values, key: value});
  });

  @override
  Future<void> delete(String key) => _sync(() async {
    await _ensure();
    if (!_useBundle) return _backend.delete(key);
    // Remove a leftover legacy copy too, so a later read cannot resurrect it.
    await _backend.delete(key);
    if (!_values.containsKey(key)) return;
    final next = {..._values}..remove(key);
    await _persist(next);
  });

  Future<void> _ensure() async {
    if (_loaded) return;
    final bundled = await _backend.read(bundleKey);
    if (!_useBundle) {
      if (bundled != null) {
        // Reverse the 1.0.10 migration on platforms that do not need bundling.
        // A legacy client may have edited individual entries since migration;
        // preserve those newer values. Keep the bundle until every write lands.
        for (final entry in _decode(bundled).entries) {
          if (await _backend.read(entry.key) == null) {
            await _backend.write(entry.key, entry.value);
          }
        }
        await _backend.delete(bundleKey);
      }
      _loaded = true;
      return;
    }
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

  Future<void> _persist(Map<String, String> next) async {
    await _backend.write(bundleKey, jsonEncode(next));
    // Keep failed writes retryable and never expose unpersisted credentials.
    _values
      ..clear()
      ..addAll(next);
  }

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
      '主机 $endpoint 的指纹已改变，连接已阻止。\n已保存：$expected\n当前：$actual\n请先向服务器管理员核实，再重新连接并确认更新指纹。';
}

typedef TrustHost = Future<bool> Function(String type, String fingerprint);
typedef ConfirmHostKeyChange = Future<bool> Function(
  String type,
  String fingerprint,
  String previousKey,
);

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

  /// A saved label or a credential for another authentication method is not
  /// sufficient to log in. Keep this resolution shared by terminal and SFTP.
  Future<Credentials?> loginCredentials(Host host) async {
    bool usable(Credentials? value) =>
        value != null &&
        (host.authMethod == AuthMethod.password
            ? value.password.isNotEmpty
            : value.privateKey.trim().isNotEmpty);
    final direct = await credentials(host.id);
    if (usable(direct)) return direct;
    if (host.userId.isEmpty) return null;
    final inherited = await userCredentials(host.userId);
    return usable(inherited) ? inherited : null;
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
    TrustHost prompt, {
    ConfirmHostKeyChange? confirmKeyChange,
  }) async {
    final key = _hostKey(host);
    final presented = '$type $fingerprint';
    final known = await secrets.read(key);
    if (known == presented) return true;
    if (known != null) {
      if (confirmKeyChange == null ||
          !await confirmKeyChange(type, fingerprint, known)) {
        throw HostKeyMismatch(host.endpoint, known, presented);
      }
    } else if (!await prompt(type, fingerprint)) {
      return false;
    }
    return _serializeKeys(() async {
      final latest = await secrets.read(key);
      if (latest == presented) return true;
      // Only replace the exact key shown in the confirmation. A concurrent
      // trust or reset must never be overwritten by a stale approval.
      if (latest != known) {
        throw HostKeyMismatch(host.endpoint, latest ?? '（已重置）', presented);
      }
      await secrets.write(key, presented);
      return true;
    });
  }

  Future<void> forgetHostKey(Host host) =>
      _serializeKeys(() => secrets.delete(_hostKey(host)));
}
