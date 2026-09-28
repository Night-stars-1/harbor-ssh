import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'host_repository.dart';

/// Raised when local conversation history cannot be read or written. The
/// message is user-facing: storage problems are reported, never swallowed and
/// never "fixed" by overwriting existing ciphertext.
class AiConversationFailure implements Exception {
  const AiConversationFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Metadata shown in the history list. Carries no message body.
class AiConversationSummary {
  const AiConversationSummary({
    required this.id,
    required this.title,
    required this.model,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String model;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    'updatedAt': updatedAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is AiConversationSummary &&
      other.id == id &&
      other.title == title &&
      other.model == model &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, title, model, updatedAt);
}

/// One conversation as persisted: display entries plus the raw model context
/// (`_history`) needed to continue it after a restart.
class AiConversation {
  AiConversation({
    required this.id,
    required this.scope,
    required this.title,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    required this.entries,
    required this.history,
    this.contextModel,
  });

  final String id;
  final String scope;
  final String title;
  final String model;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Serialized display entries (text, tool output, exit codes, image bytes).
  final List<Map<String, dynamic>> entries;

  /// Raw model messages replayed verbatim when the conversation continues.
  final List<Map<String, dynamic>> history;
  final String? contextModel;

  AiConversationSummary get summary => AiConversationSummary(
    id: id,
    title: title,
    model: model,
    updatedAt: updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'id': id,
    'scope': scope,
    'title': title,
    'model': model,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'contextModel': contextModel,
    'entries': entries,
    'history': history,
  };
}

/// Local, encrypted, cross-restart storage for terminal AI conversations.
///
/// Only the 32-byte AES-256-GCM key lives in the injected secure
/// [KeyValueStore] (the same store that holds SSH credentials). Every
/// conversation body and the per-scope index are sealed files under the
/// application support directory, written atomically (`.new` + rename) with
/// interrupted-write recovery. Nothing here reaches `SyncStorage`, Gist or
/// WebDAV, and plaintext preferences are never used.
class AiConversationStore {
  AiConversationStore({required this.secrets, required this.directory});

  /// Secure store holding only the local encryption key.
  final KeyValueStore secrets;

  /// Application support directory resolver (injected for tests).
  final Future<Directory> Function() directory;

  /// Key name inside [secrets]; never the payload.
  static const keyName = 'harbor.ai.chats.key.v1';

  static const _aad = 'Harbor SSH AI history v1';
  static const _rootName = 'ai_conversations';

  /// Index file inside each scope directory (also sealed).
  static const indexFileName = 'index.bin';

  /// A single conversation above this size is refused, never truncated.
  static const maxConversationBytes = 64 * 1024 * 1024;

  final _random = Random.secure();
  Future<SecretKey>? _key;
  Future<void> _queue = Future<void>.value();

  /// Serializes every read-modify-write so concurrent saves cannot interleave.
  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<AiConversationSummary>> list(String scope) =>
      _serialize(() async {
        final directory = await _scopeDirectory(scope);
        final index = await _readIndex(directory, scope);
        final summaries = <AiConversationSummary>[];
        for (final row in index) {
          final id = row['id'];
          if (id is! String || id.isEmpty) continue;
          summaries.add(
            AiConversationSummary(
              id: id,
              title: row['title'] is String ? row['title'] as String : '',
              model: row['model'] is String ? row['model'] as String : '',
              updatedAt: _date(row['updatedAt']),
            ),
          );
        }
        summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        return summaries;
      });

  Future<AiConversation?> load(String scope, String id) => _serialize(() async {
    final directory = await _scopeDirectory(scope);
    final raw = await _readAtomic(_contentFile(directory, id));
    if (raw == null) return null;
    final clear = await _open(raw, _recordAad(scope, id));
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } catch (_) {
      throw const AiConversationFailure('本地历史文件内容已损坏，无法读取');
    }
    if (decoded is! Map) {
      throw const AiConversationFailure('本地历史文件结构不受支持');
    }
    try {
      return _conversationFromJson(
        Map<String, dynamic>.from(decoded),
        scope: scope,
        id: id,
      );
    } on AiConversationFailure {
      rethrow;
    } catch (_) {
      throw const AiConversationFailure('本地历史文件结构不受支持');
    }
  });

  /// Writes [conversation] and refreshes the scope index. Refuses to write when
  /// the existing index cannot be read, so a damaged store is never clobbered.
  Future<void> save(AiConversation conversation) => _serialize(() async {
    final directory = await _scopeDirectory(conversation.scope);
    final index = await _readIndex(directory, conversation.scope);
    final clear = utf8.encode(jsonEncode(conversation.toJson()));
    if (clear.length > maxConversationBytes) {
      throw const AiConversationFailure('该对话内容过大（含图片与输出），未能保存到本地历史');
    }
    await _writeAtomic(
      _contentFile(directory, conversation.id),
      await _seal(clear, _recordAad(conversation.scope, conversation.id)),
    );

    index.removeWhere((row) => row['id'] == conversation.id);
    index.add(conversation.summary.toJson());
    index.sort(
      (a, b) => _date(b['updatedAt']).compareTo(_date(a['updatedAt'])),
    );
    await _writeIndex(directory, conversation.scope, index);
  });

  /// Removes a conversation. The index entry disappears first, then the sealed
  /// body and any swap siblings are deleted.
  Future<void> delete(String scope, String id) => _serialize(() async {
    final directory = await _scopeDirectory(scope);
    final index = await _readIndex(directory, scope);
    index.removeWhere((row) => row['id'] == id);
    await _writeIndex(directory, scope, index);
    await _erase(_contentFile(directory, id));
  });

  // --- encryption -----------------------------------------------------------

  Future<SecretKey> _secretKey() {
    final cached = _key;
    if (cached != null) return cached;
    final pending = _loadKey();
    _key = pending;
    pending.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_key, pending)) _key = null;
      },
    );
    return pending;
  }

  Future<SecretKey> _loadKey() async {
    final stored = await secrets.read(keyName);
    if (stored == null) {
      // Generating a fresh key over existing ciphertext would silently destroy
      // it, so refuse instead when any sealed history is already on disk.
      if (await _hasStoredHistory()) {
        throw const AiConversationFailure('本地加密密钥已丢失，无法读取历史对话；未改动任何已有数据');
      }
      final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
      await secrets.write(keyName, base64Encode(bytes));
      return SecretKey(bytes);
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(stored);
    } on FormatException {
      throw const AiConversationFailure('本地加密密钥已损坏，历史对话暂不可用');
    }
    if (bytes.length != 32) {
      throw const AiConversationFailure('本地加密密钥长度异常，历史对话暂不可用');
    }
    return SecretKey(bytes);
  }

  Future<bool> _hasStoredHistory() async {
    try {
      final root = await _rootDirectory();
      if (!await root.exists()) return false;
      return !(await root.list().isEmpty);
    } catch (_) {
      throw const AiConversationFailure('无法访问本地历史目录，已停止以避免覆盖已有数据');
    }
  }

  /// Ciphertext is authenticated against its exact home: the record's scope,
  /// kind and id. Moving a sealed file to another host or id cannot be made to
  /// decrypt, even with a valid key.
  static String _indexAad(String scope) => '$_aad|index|$scope';

  static String _recordAad(String scope, String id) =>
      '$_aad|record|$scope|$id';

  Future<List<int>> _seal(List<int> clear, String aad) async {
    final box = await AesGcm.with256bits().encrypt(
      clear,
      secretKey: await _secretKey(),
      aad: utf8.encode(aad),
    );
    return utf8.encode(
      jsonEncode({
        'format': _aad,
        'v': 1,
        'nonce': base64Encode(box.nonce),
        'mac': base64Encode(box.mac.bytes),
        'data': base64Encode(box.cipherText),
      }),
    );
  }

  Future<List<int>> _open(List<int> raw, String aad) async {
    final Map<String, dynamic> envelope;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map) throw const FormatException();
      envelope = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw const AiConversationFailure('本地历史文件已损坏，无法读取');
    }
    if (envelope['format'] != _aad) {
      throw const AiConversationFailure('本地历史文件格式不受支持');
    }
    final nonce = _decodeField(envelope['nonce']);
    final mac = _decodeField(envelope['mac']);
    final data = _decodeField(envelope['data']);
    if (nonce.length != 12 || mac.length != 16) {
      throw const AiConversationFailure('本地历史文件不完整，无法读取');
    }
    try {
      return await AesGcm.with256bits().decrypt(
        SecretBox(data, nonce: nonce, mac: Mac(mac)),
        secretKey: await _secretKey(),
        aad: utf8.encode(aad),
      );
    } on SecretBoxAuthenticationError {
      throw const AiConversationFailure('本地历史解密失败：密钥不匹配或文件已损坏');
    } catch (_) {
      throw const AiConversationFailure('本地历史解密失败');
    }
  }

  List<int> _decodeField(Object? value) {
    if (value is! String) {
      throw const AiConversationFailure('本地历史文件不完整，无法读取');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw const AiConversationFailure('本地历史文件不完整，无法读取');
    }
  }

  // --- files ----------------------------------------------------------------

  Future<Directory> _rootDirectory() async =>
      Directory(_join((await directory()).path, _rootName));

  Future<Directory> _scopeDirectory(String scope) async {
    final digest = await Sha256().hash(utf8.encode(scope));
    final name = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return Directory(_join((await _rootDirectory()).path, name));
  }

  File _indexFile(Directory directory) =>
      File(_join(directory.path, indexFileName));

  File _contentFile(Directory directory, String id) => File(
    _join(
      directory.path,
      '${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.bin',
    ),
  );

  /// Reads a sealed file, recovering from an interrupted write: the swap is
  /// "write .new, replace target, drop backup", so either sibling surviving a
  /// crash is promoted back into place.
  Future<List<int>?> _readAtomic(File target) async {
    if (await target.exists()) return target.readAsBytes();
    for (final suffix in const ['.new', '.bak']) {
      final sibling = File('${target.path}$suffix');
      if (await sibling.exists()) {
        await sibling.rename(target.path);
        return target.readAsBytes();
      }
    }
    return null;
  }

  /// Writes through a sibling `.new` file, then swaps it in. Dart's rename
  /// replaces an existing file atomically on the platforms this app targets,
  /// but a `.bak` rotation is kept as a fallback (and a recovery point) for
  /// platforms where replacing fails.
  Future<void> _writeAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final pending = File('${target.path}.new');
    await pending.writeAsBytes(bytes, flush: true);
    try {
      await pending.rename(target.path);
      return;
    } catch (_) {
      // Fall through to the backup rotation below.
    }
    final backup = File('${target.path}.bak');
    if (await target.exists()) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }
    try {
      await pending.rename(target.path);
    } catch (_) {
      if (await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  /// Removes a sealed file and every swap sibling. The siblings go first: a
  /// surviving `.bak` would otherwise be promoted back by [_readAtomic] and
  /// resurrect a deleted conversation. The payload is already encrypted, so
  /// this deletes the local records — it makes no secure-erasure claim about
  /// the underlying storage.
  Future<void> _erase(File file) async {
    for (final suffix in const ['.new', '.bak', '']) {
      final victim = File('${file.path}$suffix');
      if (await victim.exists()) await victim.delete();
    }
  }

  Future<List<Map<String, dynamic>>> _readIndex(
    Directory directory,
    String scope,
  ) async {
    final raw = await _readAtomic(_indexFile(directory));
    if (raw == null) return [];
    final clear = await _open(raw, _indexAad(scope));
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(clear));
    } catch (_) {
      throw const AiConversationFailure('本地历史索引已损坏，无法读取');
    }
    if (decoded is! List) {
      throw const AiConversationFailure('本地历史索引已损坏，无法读取');
    }
    return [
      for (final row in decoded)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }

  Future<void> _writeIndex(
    Directory directory,
    String scope,
    List<Map<String, dynamic>> index,
  ) async {
    final sealed = await _seal(
      utf8.encode(jsonEncode(index)),
      _indexAad(scope),
    );
    await _writeAtomic(_indexFile(directory), sealed);
  }

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  static DateTime _date(Object? value) => value is String
      ? (DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0))
      : DateTime.fromMillisecondsSinceEpoch(0);

  static AiConversation _conversationFromJson(
    Map<String, dynamic> json, {
    required String scope,
    required String id,
  }) {
    List<Map<String, dynamic>> rows(Object? value) => [
      for (final row in value is List ? value : const [])
        if (row is Map) Map<String, dynamic>.from(row),
    ];
    final storedId = json['id'];
    final storedScope = json['scope'];
    if (storedId is! String || storedId.isEmpty || storedId != id) {
      throw const AiConversationFailure('本地历史文件位置与内容不匹配，已拒绝读取');
    }
    if (storedScope is! String || storedScope != scope) {
      throw const AiConversationFailure('本地历史文件不属于当前主机，已拒绝读取');
    }
    return AiConversation(
      id: storedId,
      scope: scope,
      title: json['title'] is String ? json['title'] as String : '',
      model: json['model'] is String ? json['model'] as String : '',
      createdAt: _date(json['createdAt']),
      updatedAt: _date(json['updatedAt']),
      entries: rows(json['entries']),
      history: rows(json['history']),
      contextModel: json['contextModel'] is String
          ? json['contextModel'] as String
          : null,
    );
  }
}
