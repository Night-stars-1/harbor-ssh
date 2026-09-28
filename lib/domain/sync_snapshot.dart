import 'dart:convert';

import 'host.dart';

enum SyncConflictChoice { local, remote }

class SyncConflict implements Exception {
  const SyncConflict(this.names);
  final List<String> names;
  @override
  String toString() => '两端同时修改了：${names.join('、')}';
}

class SyncCredentialMissing implements Exception {
  const SyncCredentialMissing(this.names);
  final List<String> names;
  @override
  String toString() =>
      '凭证「${names.join('、')}」缺少私钥，已停止同步以防止覆盖完整凭证。请从完整备份恢复或重新导入私钥。';
}

/// Each connection/key and its secret form one record for conflict resolution.
class SyncSnapshot {
  SyncSnapshot(this.records);
  final Map<String, Map<String, dynamic>> records;
  factory SyncSnapshot.empty() => SyncSnapshot({});

  factory SyncSnapshot.decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    if (json['version'] != 1 || json['records'] is! Map) {
      throw const FormatException('不支持的同步数据格式');
    }
    final records = <String, Map<String, dynamic>>{};
    final source = json['records'] as Map;
    if (source.length > 10000) throw const FormatException('同步数据过大');
    for (final entry in source.entries) {
      final id = entry.key as String;
      final record = Map<String, dynamic>.from(entry.value as Map);
      final data = Map<String, dynamic>.from(record['data'] as Map);
      if (id.startsWith('host:')) {
        final host = Host.fromJson(data);
        if (id != 'host:${host.id}' ||
            host.id.isEmpty ||
            host.port < 1 ||
            host.port > 65535) {
          throw const FormatException('无效的连接数据');
        }
      } else if (id.startsWith('key:')) {
        final user = SshUser.fromJson(data);
        if (id != 'key:${user.id}' || user.id.isEmpty) {
          throw const FormatException('无效的凭证数据');
        }
      } else {
        throw const FormatException('不支持的同步记录');
      }
      if (record['secret'] != null) {
        Credentials.fromJson(
          Map<String, dynamic>.from(record['secret'] as Map),
        );
      }
      records[id] = record;
    }
    return SyncSnapshot(records);
  }

  String encode() => jsonEncode({'version': 1, 'records': records});

  static bool same(Object? a, Object? b) => _canonical(a) == _canonical(b);
  static String _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonical).join(',')}]';
    return jsonEncode(value);
  }

  static bool _hasSecret(Map<String, dynamic>? record) {
    if (record == null) return false;
    final data = record['data'] as Map;
    final secret = record['secret'] as Map?;
    final isKey = data['authMethod'] == AuthMethod.privateKey.name;
    final value = secret?[isKey ? 'privateKey' : 'password'] as String? ?? '';
    return isKey ? value.trim().isNotEmpty : value.isNotEmpty;
  }

  static bool _sameAuthentication(
    String id,
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final first = a['data'] as Map, second = b['data'] as Map;
    if (first['authMethod'] != second['authMethod']) return false;
    if (id.startsWith('key:')) {
      if (first['authMethod'] == AuthMethod.password.name) {
        return first['username'] == second['username'];
      }
      final key = (first['publicKey'] as String? ?? '').trim().split(
        RegExp(r'\s+'),
      );
      final other = (second['publicKey'] as String? ?? '').trim().split(
        RegExp(r'\s+'),
      );
      return key.length >= 2 &&
          other.length >= 2 &&
          key[0] == other[0] &&
          key[1] == other[1];
    }
    return [
      'address',
      'port',
      'username',
      'authMethod',
      'userId',
    ].every((field) => first[field] == second[field]);
  }

  static Map<String, dynamic>? _recoverPrivateKey(
    String id,
    Map<String, dynamic>? record,
    List<Map<String, dynamic>?> candidates,
  ) {
    if (record == null ||
        !id.startsWith('key:') ||
        (record['data'] as Map)['authMethod'] != AuthMethod.privateKey.name ||
        _hasSecret(record)) {
      return record;
    }
    for (final candidate in candidates) {
      if (candidate != null &&
          _hasSecret(candidate) &&
          _sameAuthentication(id, record, candidate)) {
        return {...record, 'secret': candidate['secret']};
      }
    }
    return record;
  }

  /// Private-key records always require their signing key. Missing secrets
  /// from a legacy client must never become a cloud or local deletion.
  void requireCompletePrivateKeys() {
    final missing = <String>[];
    for (final entry in records.entries) {
      final data = entry.value['data'] as Map;
      if (entry.key.startsWith('key:') &&
          data['authMethod'] == AuthMethod.privateKey.name &&
          !_hasSecret(entry.value)) {
        missing.add(data['name'] as String);
      }
    }
    if (missing.isNotEmpty) throw SyncCredentialMissing(missing);
  }

  static SyncSnapshot merge({
    required SyncSnapshot local,
    required SyncSnapshot remote,
    required SyncSnapshot base,
    SyncConflictChoice? choice,
  }) {
    final result = <String, Map<String, dynamic>>{};
    final conflicts = <String>[];
    for (final id in {
      ...base.records.keys,
      ...local.records.keys,
      ...remote.records.keys,
    }) {
      final previous = base.records[id];
      final a = _recoverPrivateKey(id, local.records[id], [
        remote.records[id],
        previous,
      ]);
      final b = _recoverPrivateKey(id, remote.records[id], [
        local.records[id],
        previous,
      ]);
      Map<String, dynamic>? selected;
      if (same(a, b) || same(b, previous)) {
        selected = a;
      } else if (same(a, previous)) {
        selected = b;
      } else if (choice != null) {
        selected = choice == SyncConflictChoice.local ? a : b;
      } else {
        conflicts.add(((a ?? b ?? previous)!['data'] as Map)['name'] as String);
      }
      if (selected != null) {
        // Clearing a saved password on an otherwise unchanged account needs
        // an explicit conflict choice. An entirely deleted record still uses
        // normal three-way deletion semantics.
        if (!_hasSecret(selected) &&
            (selected['data'] as Map)['authMethod'] ==
                AuthMethod.password.name &&
            [a, b, previous].any(
              (candidate) =>
                  candidate != null &&
                  _hasSecret(candidate) &&
                  _sameAuthentication(id, selected!, candidate),
            )) {
          if (choice == null) {
            conflicts.add((selected['data'] as Map)['name'] as String);
          } else {
            selected = choice == SyncConflictChoice.local ? a : b;
          }
        }
        if (selected != null) result[id] = selected;
      }
    }
    if (conflicts.isNotEmpty) throw SyncConflict(conflicts);
    final merged = SyncSnapshot(result);
    merged.requireCompletePrivateKeys();
    return merged;
  }
}
