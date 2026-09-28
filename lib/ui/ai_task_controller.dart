import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/ai_conversation_store.dart';
import '../data/terminal_ai.dart';
import '../data/ai_image.dart';

class AiTaskEntry {
  AiTaskEntry(
    this.text, {
    this.command = false,
    this.images,
    this.user,
    this.notice,
    this.model,
  });
  final String? model;
  final bool? user, notice;
  final List<AiImage>? images;
  String text;
  final bool command;
  String output = '';
  String? reason;
  int? exitCode;
  bool finished = false;
  bool? started;
  String? interruption;
}

/// A conservative extra check, in addition to the model's explicit approval flag.
bool aiCommandNeedsApproval(AiToolCall call) =>
    call.requiresApproval ||
    RegExp(
      r'(^|[\s;&|/])(sudo|su|rm|rmdir|mv|dd|mkfs\S*|wipefs|shred|truncate|chmod|chown|reboot|shutdown|poweroff|kill|killall|pkill|tee)(\s|$)|(^|[^>])>(?!>)|\b(apt|apt-get|yum|dnf|pip|npm)\s|\bsystemctl\s+(stop|restart|reload|disable|enable|mask)|\bgit\s+(push|reset|clean|checkout|restore|rebase)|\b(docker|kubectl)\s+(rm|rmi|stop|kill|restart|delete|apply|replace|rollout)|\bservice\s+\S+\s+(stop|restart|reload)',
      caseSensitive: false,
    ).hasMatch(call.command);

enum AiApprovalMode { manual, auto, readOnly }

class AiTaskController extends ChangeNotifier {
  AiTaskController({
    required this.settings,
    required this.executorFactory,
    required this.connected,
    TerminalAiClient Function()? clientFactory,
    this.historyStore,
    this.historyScope,
  }) : clientFactory = clientFactory ?? TerminalAiClient.new;
  final AiSettings Function() settings;
  final AiCommandExecutor Function() executorFactory;
  final bool Function() connected;
  final TerminalAiClient Function() clientFactory;

  /// Local encrypted history. When null (or [historyScope] is null) the
  /// controller never touches platform storage.
  final AiConversationStore? historyStore;
  final String? historyScope;

  final entries = <AiTaskEntry>[];
  bool running = false;
  String status = '';
  String? failure;
  AiToolCall? pending;
  Completer<bool>? _approval;
  TerminalAiClient? _client;
  AiCommandExecutor? _executor;
  bool _disposed = false;
  int _revision = 0;
  final _history = <Map<String, dynamic>>[];
  final _unresolved = <String, AiTaskEntry?>{};
  String? _contextModel;
  String? _modelOverride;
  DateTime? turnStartedAt;
  AiApprovalMode approvalMode = AiApprovalMode.manual;

  final _random = Random.secure();
  final _summaries = <AiConversationSummary>[];
  String? _activeId;
  DateTime? _activeCreatedAt;
  bool _historyLoading = false;
  bool _historyLoaded = false;
  String? _historyFailure;
  bool _historyFailureFromSave = false;
  Future<void>? _historyReady;
  Future<bool>? _pendingPersist;
  Future<void>? _pendingReset;
  int _persistSerial = 0;
  int _loadedSerial = 0;

  bool get autoApprove => approvalMode == AiApprovalMode.auto;

  /// Stored conversations, newest first. Empty when history is not wired.
  List<AiConversationSummary> get conversations =>
      List.unmodifiable(_summaries);

  /// Id of the conversation currently open, or null for a fresh, unsaved one.
  String? get activeConversationId => _activeId;

  bool get historyLoading => _historyLoading;

  /// Last history problem (load/open/save/delete); cleared by the next
  /// successful history operation.
  String? get historyFailure => _historyFailure;

  String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  String? _commandForTool(AiToolCall call) {
    if (call.name == 'run_command') return call.command;
    final path = (call.arguments['path'] as String?)?.trim() ?? '';
    final reason = call.arguments['reason'];
    if (reason is! String || reason.trim().isEmpty) return null;
    switch (call.name) {
      case 'list_directory':
        return 'ls -la -- ${_shellQuote(path.isEmpty ? '.' : path)}';
      case 'read_file':
        if (path.isEmpty) return null;
        return 'cat -- ${_shellQuote(path)}';
      case 'search_text':
        final query = (call.arguments['query'] as String?)?.trim() ?? '';
        if (query.isEmpty) return null;
        return 'grep -RIn -- ${_shellQuote(query)} ${_shellQuote(path.isEmpty ? '.' : path)}';
      case 'system_info':
        return 'uname -a; id; pwd';
      default:
        return null;
    }
  }

  String get activeModel => _effectiveSettings().model;

  AiSettings _effectiveSettings() {
    final base = settings();
    final model = _modelOverride?.trim();
    if (model == null || model.isEmpty || model == base.model) return base;
    return base.withModel(model);
  }

  void setModel(String? model) {
    if (running || _disposed) return;
    final next = model?.trim();
    _modelOverride = next == null || next.isEmpty ? null : next;
    _notify();
  }

  void setAutoApprove(bool enabled) {
    setApprovalMode(enabled ? AiApprovalMode.auto : AiApprovalMode.manual);
  }

  void setApprovalMode(AiApprovalMode mode) {
    if (_disposed) return;
    approvalMode = mode;
    if (mode == AiApprovalMode.auto && pending != null) approve(true);
    if (mode == AiApprovalMode.readOnly && running) {
      stop(message: '已切换为只读模式，当前任务已停止');
      return;
    }
    _notify();
  }

  Future<List<String>> listModels() async {
    if (_disposed) return const [];
    final client = clientFactory();
    try {
      return await client.listModels(_effectiveSettings());
    } finally {
      client.cancel();
    }
  }

  // --- history ---------------------------------------------------------------

  /// Loads (or refreshes) the stored conversation list.
  ///
  /// Idempotent: repeated calls reuse the in-flight load, and a call after a
  /// successful load only re-reads when a save happened in the meantime. Any
  /// in-flight persistence is settled first, so a test or the panel can call
  /// this right after [newConversation] and still see the archived entry.
  Future<void> loadHistory() async {
    final store = historyStore;
    final scope = historyScope;
    if (store == null || scope == null || _disposed) return;
    final reset = _pendingReset;
    if (reset != null) await reset;
    if (_disposed) return;
    final inFlight = _historyReady;
    if (_historyLoading && inFlight != null) await inFlight;
    if (_disposed) return;
    if (_historyLoaded &&
        _loadedSerial == _persistSerial &&
        _pendingPersist == null) {
      return;
    }
    final pending = _loadHistory(store, scope);
    _historyReady = pending;
    await pending;
  }

  Future<void> _loadHistory(AiConversationStore store, String scope) async {
    _historyLoading = true;
    _notify();
    try {
      final inFlight = _pendingPersist;
      if (inFlight != null) await inFlight;
      if (_disposed) return;
      // Captured before the read: a save that lands during it makes
      // [_loadedSerial] stale on purpose, so the next call re-reads.
      final serial = _persistSerial;
      final loaded = await store.list(scope);
      if (_disposed) return;
      _summaries
        ..clear()
        ..addAll(loaded);
      _loadedSerial = serial;
      _historyLoaded = true;
      // A successful read clears read-side problems but never an unresolved
      // save failure: that stays visible until a save actually succeeds.
      _clearHistoryFailure(keepSaveFailures: true);
    } on AiConversationFailure catch (error) {
      _recordHistoryFailure(error.message, fromSave: false);
    } catch (_) {
      _recordHistoryFailure('读取历史对话失败', fromSave: false);
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  /// Opens a stored conversation. The current one is archived first; if that
  /// save fails, the panel stays on the current conversation instead of
  /// dropping it. No-op while a task is running.
  Future<void> openConversation(String id) async {
    final store = historyStore;
    final scope = historyScope;
    if (store == null || scope == null || _disposed) return;
    final reset = _pendingReset;
    if (reset != null) await reset;
    if (_disposed || running) return;
    if (_activeId == id && entries.isNotEmpty) return;
    final revision = _revision;
    _historyLoading = true;
    _notify();
    try {
      if (!await _persistConversation()) return;
      if (_disposed || running || revision != _revision) return;
      final conversation = await store.load(scope, id);
      if (_disposed || running || revision != _revision) return;
      if (conversation == null) {
        _summaries.removeWhere((item) => item.id == id);
        _recordHistoryFailure('历史对话已不存在，可能已被删除', fromSave: false);
        return;
      }
      final restored = <AiTaskEntry>[];
      for (final row in conversation.entries) {
        restored.add(await _entryFromJson(row));
      }
      if (_disposed || running || revision != _revision) return;
      _revision++;
      entries
        ..clear()
        ..addAll(restored);
      _history
        ..clear()
        ..addAll([
          for (final message in conversation.history)
            Map<String, dynamic>.from(message),
        ]);
      _unresolved.clear();
      _contextModel = conversation.contextModel;
      _modelOverride = _restoredModelOverride(conversation);
      _activeId = conversation.id;
      _activeCreatedAt = conversation.createdAt;
      status = '';
      failure = null;
      pending = null;
      turnStartedAt = null;
      _clearHistoryFailure(keepSaveFailures: true);
    } on AiConversationFailure catch (error) {
      _recordHistoryFailure(error.message, fromSave: false);
    } catch (_) {
      _recordHistoryFailure('读取历史对话失败', fromSave: false);
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  /// Reads a stored conversation for a read-only preview.
  ///
  /// Returns the archived entries, or a snapshot of the live [entries] when
  /// [id] is the conversation already open. Unlike [openConversation] this
  /// never archives the current conversation and never mutates [entries],
  /// the model context, [activeConversationId] or the model, so it is safe to
  /// call while a task is running and for callers that only want to look.
  /// Returns null when the conversation cannot be read (missing entry, broken
  /// ciphertext, undecodable image); [historyFailure] then explains why, and a
  /// successful read still clears a read-side failure but never an unresolved
  /// save error. Late results are the caller's problem: the UI picks its own
  /// revision and ignores previews that arrive after a newer selection.
  Future<List<AiTaskEntry>?> previewConversation(String id) async {
    final store = historyStore;
    final scope = historyScope;
    if (store == null || scope == null || _disposed) return null;
    if (id == _activeId) return List.unmodifiable(entries);
    final reset = _pendingReset;
    if (reset != null) await reset;
    if (_disposed) return null;
    try {
      final inFlight = _pendingPersist;
      if (inFlight != null) await inFlight;
      if (_disposed) return null;
      final conversation = await store.load(scope, id);
      if (_disposed) return null;
      if (conversation == null) {
        _recordHistoryFailure('历史对话已不存在，可能已被删除', fromSave: false);
        return null;
      }
      final restored = <AiTaskEntry>[];
      for (final row in conversation.entries) {
        restored.add(await _entryFromJson(row));
      }
      if (_disposed) return null;
      _clearHistoryFailure(keepSaveFailures: true);
      return List.unmodifiable(restored);
    } on AiConversationFailure catch (error) {
      _recordHistoryFailure(error.message, fromSave: false);
      return null;
    } catch (_) {
      _recordHistoryFailure('读取历史对话失败', fromSave: false);
      return null;
    }
  }

  /// Deletes a stored conversation. Deleting the open one resets the panel to a
  /// fresh conversation. No-op while a task is running.
  Future<void> deleteConversation(String id) async {
    final store = historyStore;
    final scope = historyScope;
    if (store == null || scope == null || _disposed) return;
    final reset = _pendingReset;
    if (reset != null) await reset;
    if (_disposed || running) return;
    final revision = _revision;
    _historyLoading = true;
    _notify();
    try {
      await store.delete(scope, id);
      if (_disposed || running || revision != _revision) return;
      _summaries.removeWhere((item) => item.id == id);
      if (_activeId == id) {
        _revision++;
        _history.clear();
        _unresolved.clear();
        entries.clear();
        _activeId = null;
        _activeCreatedAt = null;
        _contextModel = null;
        status = '';
        failure = null;
        pending = null;
        turnStartedAt = null;
      }
      _clearHistoryFailure(keepSaveFailures: true);
    } on AiConversationFailure catch (error) {
      _recordHistoryFailure(error.message, fromSave: false);
    } catch (_) {
      _recordHistoryFailure('删除历史对话失败', fromSave: false);
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  void _recordHistoryFailure(String message, {required bool fromSave}) {
    _historyFailure = message;
    _historyFailureFromSave = fromSave;
    _notify();
  }

  /// Clears the visible failure. [keepSaveFailures] protects an unresolved save
  /// error from being wiped by an unrelated successful read.
  void _clearHistoryFailure({required bool keepSaveFailures}) {
    if (_historyFailure == null) return;
    if (keepSaveFailures && _historyFailureFromSave) return;
    _historyFailure = null;
    _historyFailureFromSave = false;
    _notify();
  }

  /// Snapshots the current conversation and stores it, returning whether the
  /// snapshot is now durable. The payload is captured synchronously, before any
  /// await, so a caller that clears [entries] right after still persists the
  /// finished conversation. Reports `true` when there was nothing to save.
  Future<bool> _persistConversation() {
    AiConversation? conversation;
    try {
      conversation = _snapshotConversation();
    } catch (_) {
      _recordHistoryFailure('保存历史对话失败', fromSave: true);
      return Future.value(false);
    }
    if (conversation == null) return Future.value(true);
    final pending = _storeConversation(conversation);
    _pendingPersist = pending;
    pending.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_pendingPersist, pending)) _pendingPersist = null;
    });
    return pending;
  }

  AiConversation? _snapshotConversation() {
    final scope = historyScope;
    if (historyStore == null || scope == null || _disposed) return null;
    if (entries.isEmpty && _history.isEmpty) return null;
    final now = DateTime.now();
    final createdAt = _activeCreatedAt ??= now;
    return AiConversation(
      id: _activeId ??= _newConversationId(),
      scope: scope,
      title: _titleFor(entries),
      model: _conversationModel(),
      createdAt: createdAt,
      updatedAt: now,
      entries: [for (final entry in entries) _entryJson(entry)],
      history: [
        for (final message in _history) Map<String, dynamic>.from(message),
      ],
      contextModel: _contextModel,
    );
  }

  /// The model this conversation actually used, so reopening it restores the
  /// same model even if the global default changed in the meantime.
  String _conversationModel() {
    for (final entry in entries.reversed) {
      final model = entry.model?.trim();
      if (model != null && model.isNotEmpty) return model;
    }
    return _effectiveSettings().model;
  }

  Future<bool> _storeConversation(AiConversation conversation) async {
    final store = historyStore;
    if (store == null) return true;
    try {
      await store.save(conversation);
    } on AiConversationFailure catch (error) {
      _recordHistoryFailure(error.message, fromSave: true);
      return false;
    } catch (_) {
      _recordHistoryFailure('保存历史对话失败', fromSave: true);
      return false;
    }
    _persistSerial++;
    if (_disposed) return true;
    _upsertSummary(conversation.summary);
    _clearHistoryFailure(keepSaveFailures: false);
    return true;
  }

  void _upsertSummary(AiConversationSummary summary) {
    _summaries.removeWhere((item) => item.id == summary.id);
    _summaries.add(summary);
    _summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  String _newConversationId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  String _titleFor(List<AiTaskEntry> items) {
    for (final entry in items) {
      if (entry.user == true && entry.text.trim().isNotEmpty) {
        return _shortTitle(entry.text);
      }
    }
    for (final entry in items) {
      if (entry.text.trim().isNotEmpty) return _shortTitle(entry.text);
    }
    return '图片对话';
  }

  String _shortTitle(String text) {
    final trimmed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return trimmed.length <= 40 ? trimmed : '${trimmed.substring(0, 40)}…';
  }

  String? _restoredModelOverride(AiConversation conversation) {
    final model = conversation.model.trim();
    if (model.isEmpty || model == settings().model) return null;
    return model;
  }

  Map<String, dynamic> _entryJson(AiTaskEntry entry) => {
    'text': entry.text,
    if (entry.command) 'command': true,
    if (entry.user != null) 'user': entry.user,
    if (entry.notice != null) 'notice': entry.notice,
    if (entry.model != null) 'model': entry.model,
    if (entry.output.isNotEmpty) 'output': entry.output,
    if (entry.reason != null) 'reason': entry.reason,
    if (entry.exitCode != null) 'exitCode': entry.exitCode,
    if (entry.finished) 'finished': true,
    if (entry.started != null) 'started': entry.started,
    if (entry.interruption != null) 'interruption': entry.interruption,
    if (entry.images != null && entry.images!.isNotEmpty)
      'images': [
        for (final image in entry.images!)
          {
            'name': image.name,
            'mime': image.mimeType,
            'bytes': base64Encode(image.bytes),
          },
      ],
  };

  Future<List<AiImage>?> _imagesFromJson(Object? value) async {
    if (value == null) return null;
    if (value is! List) {
      throw const AiConversationFailure('历史对话中的图片数据已损坏，已取消打开该对话');
    }
    final images = <AiImage>[];
    for (final row in value) {
      final name = row is Map ? row['name'] : null;
      final bytes = row is Map ? row['bytes'] : null;
      if (name is! String || bytes is! String) {
        throw const AiConversationFailure('历史对话中的图片数据已损坏，已取消打开该对话');
      }
      try {
        images.add(await AiImage.fromBytes(name, base64Decode(bytes)));
      } catch (_) {
        // Never drop an attachment silently: the model context still carries
        // its data URL, so an image that cannot be decoded must fail loudly
        // instead of opening a conversation with a missing preview.
        throw const AiConversationFailure('历史对话中的图片无法恢复，已取消打开该对话');
      }
    }
    return images.isEmpty ? null : List.unmodifiable(images);
  }

  Future<AiTaskEntry> _entryFromJson(Map<String, dynamic> json) async {
    final entry = AiTaskEntry(
      json['text'] is String ? json['text'] as String : '',
      command: json['command'] == true,
      images: await _imagesFromJson(json['images']),
      user: json['user'] is bool ? json['user'] as bool : null,
      notice: json['notice'] is bool ? json['notice'] as bool : null,
      model: json['model'] is String ? json['model'] as String : null,
    );
    entry.output = json['output'] is String ? json['output'] as String : '';
    entry.reason = json['reason'] is String ? json['reason'] as String : null;
    entry.exitCode = json['exitCode'] is int ? json['exitCode'] as int : null;
    entry.finished = json['finished'] == true;
    entry.started = json['started'] is bool ? json['started'] as bool : null;
    entry.interruption = json['interruption'] is String
        ? json['interruption'] as String
        : null;
    return entry;
  }

  // --- conversation ----------------------------------------------------------

  /// Starts a fresh conversation. When history is wired and the current
  /// conversation has content, it is archived first: if that save fails the
  /// current conversation is kept (nothing is cleared) and [historyFailure]
  /// reports why. Without a history store this still clears synchronously.
  Future<void> newConversation() {
    if (running || _disposed) return Future.value();
    if (historyStore == null ||
        historyScope == null ||
        (entries.isEmpty && _history.isEmpty)) {
      _resetConversation();
      return Future.value();
    }
    final inFlight = _pendingReset;
    if (inFlight != null) return inFlight;
    final reset = _archiveThenReset();
    _pendingReset = reset;
    reset.whenComplete(() {
      if (identical(_pendingReset, reset)) _pendingReset = null;
    });
    return reset;
  }

  Future<void> _archiveThenReset() async {
    if (!await _persistConversation()) return;
    if (_disposed) return;
    _resetConversation();
  }

  void _resetConversation() {
    _revision++;
    _history.clear();
    _unresolved.clear();
    entries.clear();
    failure = null;
    status = '';
    turnStartedAt = null;
    _activeId = null;
    _activeCreatedAt = null;
    _contextModel = null;
    _notify();
  }

  // Complete every tool-call pair before allowing another user message. A
  // cancelled command can have side effects, so never invent a success result.
  void _interruptTurn(String reason) {
    for (final item in _unresolved.entries) {
      final entry = item.value;
      final started = entry?.started == true;
      if (entry != null) {
        entry.interruption = started ? '已中止 · 执行结果待确认' : '未执行';
      }
      _history.add({
        'role': 'tool',
        'tool_call_id': item.key,
        'content': jsonEncode({
          'status': started ? 'interrupted' : 'not_executed',
          'output': entry?.output ?? '',
          'exitCode': null,
          'error': reason,
          if (started) 'note': '已请求终止，但远程进程可能仍在运行；继续前先检查实际状态',
        }),
      });
    }
    _unresolved.clear();
    _history.add({'role': 'assistant', 'content': '[应用状态] $reason'});
    entries.add(AiTaskEntry(reason, notice: true));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int revision) => !_disposed && running && revision == _revision;

  void approve(bool allowed) {
    if (allowed) {
      if (_approval?.isCompleted == false) _approval!.complete(true);
      pending = null;
      _notify();
    } else {
      stop();
    }
  }

  void stop({String? message}) {
    if (!running) return;
    _revision++;
    _client?.cancel();
    _executor?.cancel();
    if (_approval?.isCompleted == false) _approval!.complete(false);
    pending = null;
    running = false;
    status = message ?? '已停止；如有正在运行的命令，已请求终止';
    _interruptTurn(status);
    _notify();
    unawaited(_persistConversation());
  }

  Future<void> start(String goal, {List<AiImage> images = const []}) async {
    if (_disposed) return;
    final reset = _pendingReset;
    if (reset != null) await reset;
    if (running || _disposed) return;
    if (historyStore != null && historyScope != null && !_historyLoaded) {
      unawaited(loadHistory());
    }
    failure = null;
    final config = _effectiveSettings();
    try {
      config.endpoint;
      if (!connected()) throw const AiFailure('请先连接 SSH');
      AiImage.validateBatch(images);
      if ((goal.trim().isEmpty && images.isEmpty) || goal.length > 16000) {
        throw const AiFailure('请输入消息或添加图片，文字不超过 16000 字符');
      }
    } on AiFailure catch (error) {
      failure = error.message;
      _notify();
      return;
    }
    final revision = ++_revision;
    final client = _client = clientFactory();
    final executor = _executor = executorFactory();
    final contextModel =
        '${config.endpoint}|${config.protocol}|${config.model}';
    if (_contextModel != null && _contextModel != contextModel) {
      // Provider-specific signed thinking cannot be replayed to another model.
      for (final message in _history) {
        message.remove('_anthropicContent');
      }
    }
    _contextModel = contextModel;
    if (_history.isEmpty) {
      _history.add({'role': 'system', 'content': aiSystemPrompt});
    }
    final attachments = List<AiImage>.unmodifiable(images);
    entries.add(AiTaskEntry(goal.trim(), images: attachments, user: true));
    running = true;
    turnStartedAt = DateTime.now();
    final messages = _history;
    messages.add({
      'role': 'user',
      'content': attachments.isEmpty
          ? goal.trim()
          : [
              for (final image in attachments) image.toContent(),
              if (goal.trim().isNotEmpty) {'type': 'text', 'text': goal.trim()},
            ],
    });
    var commands = 0;
    try {
      while (_current(revision)) {
        if (!connected()) throw const AiFailure('SSH 已断开，任务已停止');
        status = commands == 0 ? '思考中' : '整理结果';
        _notify();
        AiTaskEntry? streamedReply;
        final reply = await client.stream(
          config,
          messages,
          toolMode: approvalMode == AiApprovalMode.readOnly
              ? AiToolMode.readOnly
              : AiToolMode.command,
          onText: (delta) {
            if (!_current(revision)) return;
            streamedReply ??= AiTaskEntry('', model: config.model.trim());
            if (!entries.contains(streamedReply)) {
              entries.add(streamedReply!);
            }
            streamedReply!.text += delta;
            _notify();
          },
        );
        if (!_current(revision)) return;
        messages.add(Map<String, dynamic>.from(reply.message));
        if (reply.text.trim().isNotEmpty) {
          if (streamedReply != null) {
            streamedReply!.text = reply.text.trim();
          } else {
            entries.add(
              AiTaskEntry(reply.text.trim(), model: config.model.trim()),
            );
          }
        }
        if (reply.calls.isEmpty) {
          status = '已完成';
          return;
        }
        for (final call in reply.calls) {
          _unresolved[call.id] = null;
        }
        for (final call in reply.calls) {
          if (!_current(revision)) return;
          if (++commands > 24) {
            throw const AiFailure('本轮已执行 24 条命令，可以继续发送消息');
          }
          final command = _commandForTool(call);
          final entry = AiTaskEntry(
            command ?? call.command,
            command: true,
            model: config.model.trim(),
          )..reason = call.reason;
          entries.add(entry);
          _unresolved[call.id] = entry;
          final blockedByReadOnly =
              approvalMode == AiApprovalMode.readOnly &&
              !const [
                'list_directory',
                'read_file',
                'search_text',
                'system_info',
              ].contains(call.name);
          if (command == null || blockedByReadOnly) {
            entry.interruption = blockedByReadOnly
                ? '只读模式不允许此工具'
                : '工具参数无效，未执行';
            entry.finished = true;
            messages.add({
              'role': 'tool',
              'tool_call_id': call.id,
              'content': jsonEncode({
                'status': 'tool_not_allowed',
                'output': '',
                'exitCode': null,
                'error': entry.interruption,
              }),
            });
            _unresolved.remove(call.id);
            _notify();
            continue;
          }
          if (aiCommandNeedsApproval(call) &&
              approvalMode == AiApprovalMode.manual) {
            pending = call;
            status = '等待确认';
            final approval = _approval = Completer<bool>();
            _notify();
            if (!await approval.future || !_current(revision)) return;
          }
          if (!_current(revision)) return;
          if (!connected()) throw const AiFailure('SSH 已断开，未执行命令');
          status = '执行命令';
          entry.started = true;
          _notify();
          final result = await executor.execute(command, (output) {
            if (!_current(revision)) return;
            entry.output += output;
            _notify();
          });
          if (!_current(revision)) return;
          entry.output = result.output;
          if (result.truncated && !entry.output.endsWith('已截断')) {
            entry.output += '\n…输出已截断';
          }
          entry.exitCode = result.exitCode;
          entry.finished = true;
          messages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content': jsonEncode(result.toJson()),
          });
          _unresolved.remove(call.id);
          _notify();
        }
      }
    } catch (error) {
      if (_current(revision)) {
        failure = error is AiFailure ? error.message : '回复中断，请检查配置后重试';
        status = '回复中断';
        _interruptTurn(failure!);
      }
    } finally {
      client.cancel();
      executor.cancel();
      if (revision == _revision) {
        running = false;
        pending = null;
        _notify();
        // Runs after the turn is frozen, so the snapshot is complete.
        unawaited(_persistConversation());
      }
    }
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
