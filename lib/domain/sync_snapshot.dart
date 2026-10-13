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

  static List<String> _bookmarks(Map<dynamic, dynamic> data) => [
    for (final path in data['sftpBookmarks'] as List? ?? const [])
      if (path is String && path.isNotEmpty) path,
  ];

  /// Re-applies the local bookmark edits made while an upload was in flight on
  /// top of the already merged cloud snapshot [this].
  ///
  /// [started] is the local snapshot the sync captured before it left for the
  /// network, [current] the local snapshot read again at commit time. Only
  /// concurrent `sftpBookmarks` deltas are carried over: additions are appended
  /// to the incoming merged list and removals are dropped from it, so
  /// remote-added paths, remote host fields and remote credentials all survive.
  ///
  /// Nothing else local may be silently overwritten. Any other concurrent local
  /// change to a host record — another field or its secret, or the host being
  /// added/removed locally — and a remote deletion of a host whose bookmarks
  /// changed locally are reported as [SyncConflict] instead.
  ///
  /// When [started] and [current] are equal the incoming merge is returned
  /// untouched: re-running the merge or its credential validation could undo a
  /// conflict choice the user already approved, such as clearing a password.
  /// No input map is mutated.
  SyncSnapshot rebaseLocalBookmarks({
    required SyncSnapshot started,
    required SyncSnapshot current,
  }) {
    if (same(started.records, current.records)) return this;
    final result = <String, Map<String, dynamic>>{...records};
    final conflicts = <String>[];
    for (final id in {...started.records.keys, ...current.records.keys}) {
      final before = started.records[id];
      final after = current.records[id];
      if (same(before, after)) continue;
      final name = ((after ?? before)!['data'] as Map)['name'] as String;
      if (!id.startsWith('host:') || before == null || after == null) {
        conflicts.add(name);
        continue;
      }
      final beforeData = before['data'] as Map;
      final afterData = after['data'] as Map;
      // Restore the original field presence of the one field this rebase is
      // allowed to change, so everything else can be compared verbatim.
      final normalized = <String, dynamic>{...afterData};
      if (beforeData.containsKey('sftpBookmarks')) {
        normalized['sftpBookmarks'] = beforeData['sftpBookmarks'];
      } else {
        normalized.remove('sftpBookmarks');
      }
      if (!same(normalized, beforeData) ||
          !same(after['secret'], before['secret'])) {
        conflicts.add(name);
        continue;
      }
      final incoming = records[id];
      if (incoming == null) {
        // The merge dropped this host (remote deletion): applying it would
        // throw away the bookmarks the user just edited.
        conflicts.add(name);
        continue;
      }
      final beforePaths = _bookmarks(beforeData);
      final afterPaths = _bookmarks(afterData);
      final removals = beforePaths
          .where((path) => !afterPaths.contains(path))
          .toSet();
      final incomingData = incoming['data'] as Map;
      final incomingPaths = _bookmarks(incomingData);
      final paths = <String>[
        for (final path in incomingPaths)
          if (!removals.contains(path)) path,
      ];
      for (final path in afterPaths) {
        if (!beforePaths.contains(path) && !paths.contains(path)) {
          paths.add(path);
        }
      }
      final data = <String, dynamic>{...incomingData};
      if (paths.isEmpty) {
        // An empty list is the same as no bookmarks: keep the optional JSON
        // field absent, exactly like Host.toJson.
        data.remove('sftpBookmarks');
      } else {
        data['sftpBookmarks'] = paths;
      }
      result[id] = {...incoming, 'data': data};
    }
    if (conflicts.isNotEmpty) throw SyncConflict(conflicts);
    return SyncSnapshot(result);
  }
}
