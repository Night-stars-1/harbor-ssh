import 'dart:convert';

import 'host.dart';
import 'network_identity.dart';

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
    // Version 2 adds network identities; version 1 archives stay readable so
    // the first sync after an upgrade still sees the previous baseline.
    if ((json['version'] != 1 && json['version'] != 2) ||
        json['records'] is! Map) {
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
      } else if (id.startsWith('identity:')) {
        final identity = NetworkIdentity.fromJson(data);
        if (data['id'] is! String ||
            identity.id.isEmpty ||
            data['name'] is! String ||
            id != 'identity:${identity.id}') {
          throw const FormatException('无效的网络身份数据');
        }
      } else {
        throw const FormatException('不支持的同步记录');
      }
      // Identities carry no credentials: never parse them as a `key:` record.
      if (!id.startsWith('identity:') && record['secret'] != null) {
        Credentials.fromJson(
          Map<String, dynamic>.from(record['secret'] as Map),
        );
      }
      records[id] = record;
    }
    return SyncSnapshot(records);
  }

  /// Version 2 archives carry network identities. Older clients reject that
  /// version instead of silently dropping them, while archives without
  /// identities stay version 1 for interoperability.
  String encode() => jsonEncode({
    'version': records.keys.any((id) => id.startsWith('identity:')) ? 2 : 1,
    'records': records,
  });

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

  /// Authentication travels as one atomic group: the endpoint, the account and
  /// the secret must never be mixed from two different edits, or a new address
  /// could end up paired with the old account's password.
  static const _hostAuthentication = [
    'address',
    'port',
    'username',
    'authMethod',
    'userId',
  ];
  static const _keyAuthentication = ['username', 'authMethod', 'publicKey'];

  static List<String> _authentication(String id) => id.startsWith('key:')
      ? _keyAuthentication
      : id.startsWith('host:')
      ? _hostAuthentication
      : const [];

  static Map<String, dynamic> _authenticationGroup(
    Map<dynamic, dynamic> data,
    Object? secret,
    List<String> fields,
  ) => {for (final field in fields) field: data[field], 'secret': secret};

  static String _recordName(Map<String, dynamic>? record) =>
      ((record?['data'] as Map?)?['name'] as String?) ?? '';

  /// One sync record for a locally stored connection and its secret, in the
  /// shape the sync snapshot capture stores.
  static Map<String, dynamic> hostRecord(Host host, Credentials? secret) => {
    'data': host.toJson(),
    'secret': secret?.toJson(),
  };

  /// Folds one local edit onto [incoming], the record the caller is about to
  /// write over.
  ///
  /// [original] is the record the editor opened — null when the record is new
  /// locally — and [edited] is what the user now wants, null for a deletion.
  /// Only the difference between those two is applied, so a field that somebody
  /// else changed meanwhile keeps the newer value; a field, authentication
  /// group or bookmark this edit really touched still wins when the other side
  /// left it alone.
  ///
  /// Bookmarks keep their per-path intent: additions are appended to the
  /// incoming list and removals are dropped from it, so unrelated paths from
  /// either side survive. Authentication fields together with the secret, and
  /// any other field both sides changed differently, are reported as
  /// [SyncConflict]. A record that is gone from [incoming] is never
  /// resurrected by an old edit either.
  static Map<String, dynamic>? _mergeRecord({
    required String id,
    required Map<String, dynamic>? original,
    required Map<String, dynamic>? edited,
    required Map<String, dynamic>? incoming,
  }) {
    if (same(original, edited)) return incoming;
    final name = _recordName(edited ?? original ?? incoming);
    if (edited == null) {
      // A deletion wins over an untouched incoming record only; there is no
      // content left to merge into an edit made elsewhere.
      if (incoming == null || same(incoming, original)) return null;
      throw SyncConflict([name]);
    }
    if (original == null) {
      // A locally created record has no earlier version to merge with, so any
      // other record under the same id is a different one.
      if (incoming == null || same(incoming, edited)) return edited;
      throw SyncConflict([name]);
    }
    // The record this edit belongs to is gone: folding the edit back would
    // resurrect something another device or the sync just deleted.
    if (incoming == null) throw SyncConflict([name]);

    final before = original['data'] as Map;
    final local = edited['data'] as Map;
    final remote = incoming['data'] as Map;
    final authentication = _authentication(id);
    final baseAuth = _authenticationGroup(
      before,
      original['secret'],
      authentication,
    );
    final localAuth = _authenticationGroup(
      local,
      edited['secret'],
      authentication,
    );
    final remoteAuth = _authenticationGroup(
      remote,
      incoming['secret'],
      authentication,
    );
    final localAuthChanged = !same(localAuth, baseAuth);
    if (localAuthChanged &&
        !same(remoteAuth, baseAuth) &&
        !same(localAuth, remoteAuth)) {
      throw SyncConflict([name]);
    }

    final data = <String, dynamic>{};
    final fields = <String>{
      ...before.keys.cast<String>(),
      ...local.keys.cast<String>(),
      ...remote.keys.cast<String>(),
    };
    for (final field in fields) {
      if (field == 'sftpBookmarks' || authentication.contains(field)) continue;
      final previousValue = before[field];
      final localValue = local[field];
      final remoteValue = remote[field];
      final localChanged = !same(previousValue, localValue);
      if (localChanged &&
          !same(previousValue, remoteValue) &&
          !same(localValue, remoteValue)) {
        throw SyncConflict([name]);
      }
      final value = localChanged ? localValue : remoteValue;
      if (value != null) data[field] = value;
    }
    for (final field in authentication) {
      final value = localAuthChanged ? local[field] : remote[field];
      if (value != null) data[field] = value;
    }

    final previousPaths = _bookmarks(before);
    final localPaths = _bookmarks(local);
    final remotePaths = _bookmarks(remote);
    final removed = previousPaths
        .where((path) => !localPaths.contains(path))
        .toSet();
    final added = localPaths.where((path) => !previousPaths.contains(path));
    final paths = <String>[
      for (final path in remotePaths)
        if (!removed.contains(path)) path,
      for (final path in added)
        if (!remotePaths.contains(path)) path,
    ];
    if (paths.isNotEmpty) data['sftpBookmarks'] = paths;

    return {
      'data': data,
      'secret': localAuthChanged ? edited['secret'] : incoming['secret'],
    };
  }

  /// Re-applies the local changes made while a cloud upload was in flight on
  /// top of the already merged cloud snapshot [this].
  ///
  /// [started] is the local snapshot the sync captured before it left for the
  /// network, [current] the local snapshot read again at commit time. Only the
  /// intent visible between the two is carried over, record by record through
  /// [_mergeRecord]: remote field values, credentials, additions and deletions
  /// all survive, and a record the merge dropped is never resurrected locally.
  ///
  /// The merge is deliberately not re-run: that would need a baseline this
  /// rebase does not have and could undo a conflict choice the user already
  /// approved, such as clearing a password.
  ///
  /// When [started] and [current] are equal the incoming merge is returned
  /// untouched. No input map is mutated.
  SyncSnapshot rebaseLocalChanges({
    required SyncSnapshot started,
    required SyncSnapshot current,
  }) {
    if (same(started.records, current.records)) return this;
    final result = <String, Map<String, dynamic>>{...records};
    final conflicts = <String>[];
    for (final id in {...started.records.keys, ...current.records.keys}) {
      final edited = current.records[id];
      if (same(started.records[id], edited)) continue;
      try {
        final merged = _mergeRecord(
          id: id,
          original: started.records[id],
          edited: edited,
          incoming: records[id],
        );
        if (merged == null) {
          result.remove(id);
        } else {
          result[id] = merged;
        }
      } on SyncConflict catch (error) {
        conflicts.addAll(error.names);
      }
    }
    if (conflicts.isNotEmpty) throw SyncConflict(conflicts);
    return SyncSnapshot(result);
  }
}
