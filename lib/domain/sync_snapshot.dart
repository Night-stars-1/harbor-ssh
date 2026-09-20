import 'dart:convert';

import 'host.dart';

enum SyncConflictChoice { local, remote }

class SyncConflict implements Exception {
  const SyncConflict(this.names);
  final List<String> names;
  @override
  String toString() => '两端同时修改了：${names.join('、')}';
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
      final a = local.records[id],
          b = remote.records[id],
          previous = base.records[id];
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
      if (selected != null) result[id] = selected;
    }
    if (conflicts.isNotEmpty) throw SyncConflict(conflicts);
    return SyncSnapshot(result);
  }
}
