import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/ai_conversation_store.dart';
import '../data/ai_privilege.dart';
import '../data/mcp_client.dart';
import '../data/terminal_ai.dart';
export '../data/terminal_ai.dart' show AiApprovalMode, AiReasoningEffort;
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

/// Waits before resending a request whose connection dropped; one entry per
/// automatic retry.
const aiRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// Outcome of one pending approval card.
///
/// [denied] is a single-call refusal for `request_root` and
/// `create_port_forward`: the turn keeps running and the model is told the
/// operation was not executed. [cancelled] keeps the stop semantics used by
/// plain commands, MCP calls and explicit stops.
enum _ApprovalDecision { approved, denied, cancelled }

class AiTaskController extends ChangeNotifier {
  AiTaskController({
    required this.settings,
    required this.executorFactory,
    required this.connected,
    TerminalAiClient Function()? clientFactory,
    this.historyStore,
    this.historyScope,
    AiApprovalMode? approvalMode,
  }) : clientFactory = clientFactory ?? TerminalAiClient.new,
       approvalMode = approvalMode ?? settings().defaultApprovalMode;
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
  Completer<_ApprovalDecision>? _approval;
  TerminalAiClient? _client;
  AiCommandExecutor? _executor;
  _AiTurn? _turn;
  int _approvalSerial = 0;
  String _systemContext = '';
  bool _disposed = false;
  bool _rootActive = false;
  bool _authorizingRoot = false;
  String? _privilegeError;
  int _revision = 0;
  // Identifies the current root authorization. A denial or a newer attempt
  // makes an older elevate() result stale, so it can neither install root nor
  // clear the state of the attempt that replaced it.
  int _rootAttempt = 0;
  final _history = <Map<String, dynamic>>[];
  final _unresolved = <String, AiTaskEntry?>{};
  String? _contextModel;
  String? _modelOverride;
  AiReasoningEffort? _reasoningOverride;
  DateTime? turnStartedAt;
  AiApprovalMode approvalMode;

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

  /// Whether this turn currently runs commands as root.
  ///
  /// The executor can close the elevated channel on its own (for example when
  /// the sudo channel drops) without notifying the controller, so the cached
  /// flag is never trusted alone: the live [AiPrivilegeExecutor.elevated] state
  /// must agree. Always false while no turn is running.
  bool get rootActive => _rootChannelLive;

  /// Cached root flag plus the executor's authoritative elevated state.
  bool get _rootChannelLive {
    if (!_rootActive) return false;
    final executor = _executor;
    return executor is AiPrivilegeExecutor && executor.elevated;
  }

  /// True while a password submitted by the privileged UI is being verified.
  bool get authorizingRoot => _authorizingRoot;

  /// Fixed, credential-free reason the last root authorization failed.
  String? get privilegeError => _privilegeError;

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

  /// Rebuilds the first system message for the current turn or restored
  /// conversation. The host context is regenerated, never replayed stale.
  void _refreshSystemPrompt(String hostContext) {
    _history.removeWhere((message) => message['role'] == 'system');
    _history.insert(0, {
      'role': 'system',
      'content': buildAiSystemPrompt(
        supplement: settings().systemPrompt,
        hostContext: hostContext,
      ),
    });
  }

  /// Only plain command calls may be auto-approved by an approval-mode switch.
  /// Local forwards, MCP tools and root requests always need an explicit user
  /// decision; root additionally requires [authorizeRoot].
  static bool _autoApprovable(AiToolCall call) => call.name == 'run_command';

  /// Fixed text for every root authorization failure: never echo SSH output,
  /// which may contain the password prompt or a password echo.
  static const _rootAuthFailure = '提权失败，请检查密码或服务器权限后重试';

  static const _rootScopeNote =
      'root 权限仅在本轮任务内有效，任务结束、取消或结束提权后自动撤销；'
      '每条命令仍是独立的 root 子 shell，cd 和 export 不会在命令之间保留。';

  static String _rootDescription(Map<String, dynamic> arguments) {
    final reason = arguments['reason'];
    final text = reason is String ? reason.trim() : '';
    return text.isEmpty ? '请求 root 权限' : '请求 root 权限：$text';
  }

  /// A malformed `request_root` call must fail before the approval UI: a fake
  /// or drifted tool must never start a privileged authentication.
  static bool _rootArgumentsValid(Map<String, dynamic> arguments) =>
      aiToolSchemaError(aiRootInputSchema, arguments) == null;

  void _clearRootState() {
    _rootActive = false;
    _authorizingRoot = false;
    _privilegeError = null;
  }

  /// Reports the already-granted root identity without any credential and
  /// without another authentication round.
  void _completeRootSuccess(
    AiTaskEntry entry,
    AiToolCall call,
    List<Map<String, dynamic>> messages,
  ) {
    entry.output =
        '已获得 root 权限（仅限本轮任务）。后续命令直接以 root 身份在独立的 '
        'root 子 shell 中执行；cd 和 export 不会在命令之间保留。';
    entry.exitCode = 0;
    entry.finished = true;
    entry.started = true;
    messages.add({
      'role': 'tool',
      'tool_call_id': call.id,
      'content': jsonEncode({
        'status': 'ok',
        'privilege': 'root',
        'scope': 'current_turn',
        'revokedOn': 'turn_end',
        'note': _rootScopeNote,
      }),
    });
    _unresolved.remove(call.id);
    _notify();
  }

  static String _forwardDescription(Map<String, dynamic> arguments) {
    final local = arguments['local_port'];
    final targetHost = arguments['target_host'] is String
        ? (arguments['target_host'] as String).trim()
        : '127.0.0.1';
    final targetPort = arguments['target_port'];
    final localText = local is int && local > 0
        ? '127.0.0.1:$local'
        : '127.0.0.1:自动分配';
    return '本地端口转发：$localText → 服务器侧 $targetHost:'
        '${targetPort is int ? targetPort : '?'}';
  }

  static String _argumentPreview(Map<String, dynamic> arguments) {
    try {
      final text = jsonEncode(arguments);
      return text.length <= 300 ? text : '${text.substring(0, 300)}…';
    } catch (_) {
      return '（参数无法显示）';
    }
  }

  static AiForwardRequest _forwardRequest(Map<String, dynamic> arguments) {
    final name = arguments['name'];
    final local = arguments['local_port'];
    final targetHost = arguments['target_host'];
    final targetPort = arguments['target_port'];
    final reason = arguments['reason'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('缺少转发名称');
    }
    if (local is! int || local < 0 || local > 65535) {
      throw const FormatException('本机端口须为 0–65535');
    }
    if (targetPort is! int || targetPort < 1 || targetPort > 65535) {
      throw const FormatException('目标端口须为 1–65535');
    }
    if (reason is! String || reason.trim().isEmpty) {
      throw const FormatException('缺少创建转发的原因');
    }
    final request = AiForwardRequest(
      name: name.trim(),
      localPort: local,
      targetHost: targetHost is String && targetHost.trim().isNotEmpty
          ? targetHost.trim()
          : '127.0.0.1',
      targetPort: targetPort,
    );
    request.validate();
    return request;
  }

  static String _toolReason(Object error) {
    final text = (error is FormatException
            ? error.message
            : error.toString().replaceFirst(
                RegExp(r'^(Bad state: |Exception: |FormatException: )'),
                '',
              ))
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), ' ');
    return text.length <= 300 ? text : '${text.substring(0, 300)}…';
  }

  void _toolNotice(String message) {
    if (_disposed) return;
    entries.add(AiTaskEntry(message, notice: true));
    _notify();
  }

  /// Builds the extra tool list for this turn and discovers MCP tools.
  ///
  /// In read-only mode no extra tool is advertised at all. A discovery
  /// failure is reported as a visible notice with the server name and reason
  /// instead of silently dropping the server.
  Future<List<AiToolSpec>> _prepareExtraTools(
    int revision,
    _AiTurn turn,
  ) async {
    turn.mcpByModelName = const {};
    if (approvalMode == AiApprovalMode.readOnly) return const [];
    final specs = <AiToolSpec>[];
    final executor = _executor;
    if (executor is AiSessionExecutor) {
      specs.add(
        const AiToolSpec(
          name: aiPortForwardToolName,
          description: aiPortForwardDescription,
          inputSchema: aiPortForwardInputSchema,
        ),
      );
    }
    if (executor is AiPrivilegeExecutor) {
      specs.add(
        const AiToolSpec(
          name: aiRootToolName,
          description: aiRootDescription,
          inputSchema: aiRootInputSchema,
        ),
      );
    }
    final servers = settings().mcpServers
        .where((server) => server.enabled)
        .toList();
    if (servers.isEmpty) return specs;
    status = '获取 MCP 工具';
    _notify();
    final seen = <String>{};
    for (final server in servers) {
      final display = server.name.trim().isEmpty ? server.id : server.name;
      if (!seen.add(server.id)) {
        _toolNotice('MCP 服务器「$display」的 ID 重复，已跳过该配置');
        continue;
      }
      try {
        server.validate();
      } catch (error) {
        _toolNotice(
          'MCP 服务器「$display」配置无效：${_toolReason(error)}。'
          '请在设置中检查地址和请求头。',
        );
        continue;
      }
      final client = McpClient(server);
      turn.mcpClients[server.id] = client;
    }
    final discovered = await Future.wait([
      for (final entry in turn.mcpClients.entries)
        () async {
          try {
            final tools = await entry.value
                .listTools()
                .timeout(const Duration(seconds: 20));
            return (entry.key, tools, null);
          } catch (error) {
            return (entry.key, const <McpTool>[], _toolReason(error));
          }
        }(),
    ]);
    if (!_current(revision)) return specs;
    final byId = {for (final server in servers) server.id: server};
    final used = <String>{
      'run_command',
      'list_directory',
      'read_file',
      'search_text',
      'system_info',
      aiPortForwardToolName,
      aiRootToolName,
    };
    final bindings = <String, _AiMcpBinding>{};
    for (final (serverId, tools, error) in discovered) {
      final server = byId[serverId]!;
      final display = server.name.trim().isEmpty ? server.id : server.name;
      if (error != null) {
        _toolNotice(
          'MCP 服务器「$display」工具列表获取失败：$error。'
          '请在设置中检查地址、鉴权头和网络后重试；本次对话已跳过该服务器。',
        );
        continue;
      }
      for (final tool in tools) {
        final modelName = _modelToolName(serverId, tool.name, used);
        final binding = _AiMcpBinding(
          serverId: serverId,
          serverName: display,
          toolName: tool.name,
        );
        bindings[modelName] = binding;
        specs.add(
          AiToolSpec(
            name: modelName,
            description: tool.description,
            inputSchema: tool.inputSchema.isEmpty
                ? const {'type': 'object', 'properties': {}}
                : Map<String, dynamic>.from(tool.inputSchema),
          ),
        );
      }
    }
    turn.mcpByModelName = bindings;
    return specs;
  }

  /// Provider tool names are limited to `[A-Za-z0-9_-]{1,64}`. Advertised
  /// names are kept verbatim when they already satisfy that; otherwise they
  /// are sanitized/namespaced and mapped back to the exact MCP name on call.
  static String _modelToolName(
    String serverId,
    String toolName,
    Set<String> used,
  ) {
    var base = toolName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (base.isEmpty) base = 'tool';
    if (base.length > 64) base = base.substring(0, 64);
    var candidate = base;
    if (used.contains(candidate)) {
      var prefix = serverId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      if (prefix.isEmpty) prefix = 'mcp';
      candidate = '${prefix}__$base';
      if (candidate.length > 64) candidate = candidate.substring(0, 64);
    }
    var serial = 2;
    while (used.contains(candidate)) {
      final suffix = '_$serial';
      candidate = candidate.length + suffix.length > 64
          ? '${candidate.substring(0, 64 - suffix.length)}$suffix'
          : '$candidate$suffix';
      serial++;
    }
    used.add(candidate);
    return candidate;
  }

  /// Stops a tool and records the failure as the tool result, so the model can
  /// recover instead of the whole turn being aborted.
  void _completeToolFailure(
    AiTaskEntry entry,
    AiToolCall call,
    List<Map<String, dynamic>> messages,
    String message, {
    bool untrusted = false,
  }) {
    entry.interruption = message;
    entry.finished = true;
    messages.add({
      'role': 'tool',
      'tool_call_id': call.id,
      'content': jsonEncode({
        'status': 'failed',
        'output': '',
        'exitCode': null,
        'error': message,
        if (untrusted) 'untrusted': true,
      }),
    });
    _unresolved.remove(call.id);
    _notify();
  }

  /// Records a user refusal as that call's tool result and keeps the turn
  /// alive. The model is told the operation did not run and must not claim
  /// success, retry without a new request, or bypass the refusal with sudo.
  void _completeUserDenied(
    AiTaskEntry entry,
    AiToolCall call,
    List<Map<String, dynamic>> messages,
  ) {
    entry.interruption = '用户拒绝，未执行';
    entry.finished = true;
    entry.started = false;
    messages.add({
      'role': 'tool',
      'tool_call_id': call.id,
      'content': jsonEncode({
        'status': 'denied',
        'output': '',
        'exitCode': null,
        'error': '用户拒绝执行，未执行',
        'note': '用户明确拒绝了该请求；不要声称已经完成，也不要换用其他工具、命令或'
            '权限方式绕过。除非用户明确重新要求，不要再次申请同一操作。',
      }),
    });
    _unresolved.remove(call.id);
    _notify();
  }

  /// Effort the next request of this conversation will ask for.
  AiReasoningEffort get reasoningEffort => _effectiveSettings().reasoningEffort;

  AiSettings _effectiveSettings() {
    final base = settings();
    final model = _modelOverride?.trim();
    final effort = _reasoningOverride;
    var effective = base;
    if (model != null && model.isNotEmpty && model != base.model) {
      effective = effective.withModel(model);
    }
    if (effort != null && effort != base.reasoningEffort) {
      effective = effective.withReasoningEffort(effort);
    }
    return effective;
  }

  void setModel(String? model) {
    if (running || _disposed) return;
    final next = model?.trim();
    _modelOverride = next == null || next.isEmpty ? null : next;
    _notify();
  }

  /// Session-scoped, exactly like [setModel]: refused while a turn is running
  /// and kept for the next conversation of this session.
  void setReasoningEffort(AiReasoningEffort effort) {
    if (running || _disposed) return;
    _reasoningOverride = effort == settings().reasoningEffort ? null : effort;
    _notify();
  }

  void setAutoApprove(bool enabled) {
    setApprovalMode(enabled ? AiApprovalMode.auto : AiApprovalMode.manual);
  }

  void setApprovalMode(AiApprovalMode mode) {
    if (_disposed) return;
    approvalMode = mode;
    final waiting = pending;
    // A mode switch may auto-approve a plain command, never an MCP call or a
    // local forward: those must keep waiting for an explicit user decision.
    if (mode == AiApprovalMode.auto &&
        waiting != null &&
        _autoApprovable(waiting)) {
      approve(true);
    }
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
      _systemContext = '';
      // The stored prompt may come from another host or an older custom
      // prompt; rebuild it now. Current-host context is added on the next turn.
      _refreshSystemPrompt('');
      _contextModel = conversation.contextModel;
      _modelOverride = _restoredModelOverride(conversation);
      _reasoningOverride = _restoredReasoningOverride(conversation);
      _activeId = conversation.id;
      _activeCreatedAt = conversation.createdAt;
      status = '';
      failure = null;
      pending = null;
      turnStartedAt = null;
      _clearRootState();
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
        _clearRootState();
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
      reasoningEffort: _effectiveSettings().reasoningEffort,
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

  AiReasoningEffort? _restoredReasoningOverride(AiConversation conversation) =>
      conversation.reasoningEffort == settings().reasoningEffort
      ? null
      : conversation.reasoningEffort;

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
    final turn = _turn;
    _turn = null;
    turn?.close();
    _systemContext = '';
    entries.clear();
    failure = null;
    status = '';
    turnStartedAt = null;
    _clearRootState();
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

  void approve(
    bool allowed, {
    bool saveForward = false,
    String? expectedCallId,
  }) {
    // A detached or delayed UI click names the call it was rendered for.
    // Never let a stale approval grant a later, different call.
    if (expectedCallId != null && pending?.id != expectedCallId) return;
    // request_root is granted only through [authorizeRoot]; a generic approve
    // (including the approval-mode switch) must never bypass that flow.
    if (allowed && pending?.name == aiRootToolName) return;
    if (allowed) {
      final turn = _turn;
      if (turn != null) turn.saveForward = saveForward;
      if (_approval?.isCompleted == false) {
        _approval!.complete(_ApprovalDecision.approved);
      }
      pending = null;
      _notify();
    } else {
      final current = pending;
      // A root or forward card is a single-call decision: rejecting it leaves
      // the turn running so the model can report the refusal and continue.
      // Plain commands and MCP calls keep the existing stop semantics.
      if (current != null &&
          (current.name == aiRootToolName ||
              current.name == aiPortForwardToolName)) {
        _denyCall(current);
        return;
      }
      stop();
    }
  }

  /// Rejects exactly [call] without stopping the turn.
  ///
  /// The turn loop writes a `denied` tool result for this call id and asks the
  /// model for the next step. A root rejection also invalidates an in-flight
  /// verification and closes only this attempt's privileged channel: the
  /// conversation, the human terminal and later unprivileged commands keep
  /// working, and a new authorization can start immediately.
  void _denyCall(AiToolCall call) {
    if (pending?.id != call.id) return;
    if (call.name == aiRootToolName) {
      // Invalidate before completing the approval: a late elevate() result
      // from this attempt must not touch a newer attempt's flags or channel.
      _rootAttempt++;
      _authorizingRoot = false;
      _privilegeError = null;
      _rootActive = false;
      final executor = _executor;
      if (executor is AiPrivilegeExecutor) executor.revokePrivilege();
    }
    pending = null;
    status = '整理结果';
    if (_approval?.isCompleted == false) {
      _approval!.complete(_ApprovalDecision.denied);
    }
    _notify();
  }

  /// Verifies the root password for the exact pending `request_root` call.
  ///
  /// The password lives only in this call's stack frame: it is passed straight
  /// to [AiPrivilegeExecutor.elevate] and never stored on the controller, the
  /// turn, an entry, the model history or a saved conversation. An empty
  /// password is passed through unchanged so configured NOPASSWD sudo can be
  /// authorized by submitting an empty field. Failures keep the request
  /// pending so the user can retry, and report a fixed message instead of raw
  /// SSH output.
  Future<void> authorizeRoot(
    String password, {
    required String expectedCallId,
  }) async {
    if (_disposed || !running) return;
    if (approvalMode == AiApprovalMode.readOnly) return;
    // A second submission while verifying is ignored; the privileged UI
    // disables its own action, this is the authoritative guard.
    if (_authorizingRoot) return;
    final turn = _turn;
    final current = pending;
    if (turn == null || current == null) return;
    if (current.id != expectedCallId || current.name != aiRootToolName) return;
    final executor = _executor;
    if (executor is! AiPrivilegeExecutor) return;
    if (!connected()) {
      _privilegeError = 'SSH 已断开，请重新连接后再提权';
      _notify();
      return;
    }
    _authorizingRoot = true;
    _privilegeError = null;
    status = '正在提权';
    _notify();
    final revision = _revision;
    final attempt = ++_rootAttempt;
    try {
      await executor.elevate(password);
    } catch (_) {
      // A denial (which advances the attempt) or a turn that was stopped or
      // replaced makes this result stale. Only a dead turn still needs its
      // own executor closed here; a denied attempt was already revoked, and
      // revoking now could close a newer channel on the same executor.
      if (attempt != _rootAttempt) {
        if (!identical(_turn, turn) || revision != _revision) {
          executor.revokePrivilege();
        }
        return;
      }
      if (!identical(_turn, turn) || revision != _revision) return;
      _authorizingRoot = false;
      if (pending?.id == expectedCallId) {
        _privilegeError = _rootAuthFailure;
        status = '等待确认';
      }
      _notify();
      return;
    }
    if (attempt != _rootAttempt) {
      // The user rejected this request or a newer authorization superseded
      // it. The denial already revoked this attempt's channel; never revoke
      // the newer one from this stale callback.
      if (!identical(_turn, turn) || revision != _revision) {
        executor.revokePrivilege();
      }
      return;
    }
    if (!identical(_turn, turn) || revision != _revision) {
      // The original turn is gone: close only that executor's late elevated
      // channel, and never touch flags or listeners of a newer turn.
      executor.revokePrivilege();
      return;
    }
    if (_disposed) {
      executor.revokePrivilege();
      return;
    }
    _authorizingRoot = false;
    if (!_current(revision) || pending?.id != expectedCallId || !connected()) {
      // The turn was stopped or disconnected while the password was being
      // verified: close the elevated channel instead of leaving it usable by
      // a run that the user already cancelled.
      executor.revokePrivilege();
      if (pending?.id == expectedCallId) {
        _privilegeError = 'SSH 已断开，请重新连接后再提权';
        status = '等待确认';
      }
      _notify();
      return;
    }
    if (!executor.elevated) {
      // Never report root unless the executor confirms the channel is live.
      executor.revokePrivilege();
      _privilegeError = _rootAuthFailure;
      status = '等待确认';
      _notify();
      return;
    }
    _rootActive = true;
    _privilegeError = null;
    pending = null;
    status = '执行工具';
    if (_approval?.isCompleted == false) {
      _approval!.complete(_ApprovalDecision.approved);
    }
    _notify();
  }

  /// Ends this turn's root session. A running elevated turn is stopped, never
  /// silently downgraded and continued.
  ///
  /// [endRoot] carries no turn token, so a delayed call from an earlier root
  /// turn must not stop an unrelated newer turn: it only acts while this turn
  /// actually has root involvement.
  void endRoot() {
    if (!running) {
      if (_rootActive || _authorizingRoot || _privilegeError != null) {
        _clearRootState();
        _notify();
      }
      return;
    }
    final rootInvolved =
        _rootActive ||
        _authorizingRoot ||
        _privilegeError != null ||
        pending?.name == aiRootToolName;
    if (!rootInvolved) return;
    stop(message: '已结束提权并停止本轮任务');
  }

  void stop({String? message}) {
    if (!running) return;
    _revision++;
    _client?.cancel();
    _executor?.cancel();
    final turn = _turn;
    _turn = null;
    turn?.close();
    if (_approval?.isCompleted == false) {
      _approval!.complete(_ApprovalDecision.cancelled);
    }
    pending = null;
    _clearRootState();
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
    final turn = _AiTurn(revision);
    _turn = turn;
    final client = _client = clientFactory();
    final executor = _executor = executorFactory();
    _systemContext = executor is AiSessionExecutor
        ? executor.systemContext
        : '';
    final contextModel =
        '${config.endpoint}|${config.protocol}|${config.model}';
    if (_contextModel != null && _contextModel != contextModel) {
      // Provider-specific signed thinking cannot be replayed to another model.
      for (final message in _history) {
        message.remove('_anthropicContent');
      }
    }
    _contextModel = contextModel;
    // Always rebuilt: a resumed conversation must not reuse a stale host
    // address, and settings edits apply from the next turn.
    _refreshSystemPrompt(_systemContext);
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
    var hasToolCalls = false;
    try {
      final extraTools = await _prepareExtraTools(revision, turn);
      if (!_current(revision)) return;
      while (_current(revision)) {
        if (!connected()) throw const AiFailure('SSH 已断开，任务已停止');
        status = hasToolCalls ? '整理结果' : '思考中';
        _notify();
        AiTaskEntry? streamedReply;
        AiReply? received;
        for (var attempt = 0; received == null; attempt++) {
          try {
            received = await client.stream(
              config,
              messages,
              toolMode: approvalMode == AiApprovalMode.readOnly
                  ? AiToolMode.readOnly
                  : AiToolMode.command,
              extraTools: extraTools,
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
          } on AiFailure catch (error) {
            if (!error.retryable || !_current(revision)) rethrow;
            if (attempt >= aiRetryDelays.length) {
              throw AiFailure(
                '${error.message}（已自动重试 ${aiRetryDelays.length} 次）',
              );
            }
            // The request is resent unchanged, so text from the dropped
            // attempt would be duplicated by the next one.
            if (streamedReply != null) entries.remove(streamedReply);
            streamedReply = null;
            final delay = aiRetryDelays[attempt];
            failure = error.message;
            status =
                '连接中断，${delay.inSeconds} 秒后重试'
                '（${attempt + 1}/${aiRetryDelays.length}）';
            _notify();
            await Future<void>.delayed(delay);
            if (!_current(revision)) return;
            if (!connected()) throw const AiFailure('SSH 已断开，任务已停止');
            status = '重新请求中（${attempt + 1}/${aiRetryDelays.length}）';
            _notify();
          }
        }
        final reply = received;
        failure = null;
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
          hasToolCalls = true;
          final mcp = turn.mcpByModelName[call.name];
          final isForward = call.name == aiPortForwardToolName;
          final isRoot = call.name == aiRootToolName;
          final command = _commandForTool(call);
          final readable = isRoot
              ? _rootDescription(call.arguments)
              : isForward
              ? _forwardDescription(call.arguments)
              : mcp != null
              ? 'MCP「${mcp.serverName}」调用工具 ${mcp.toolName}\n'
                    '参数：${_argumentPreview(call.arguments)}'
              : command ?? call.command;
          final entry = AiTaskEntry(
            readable,
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
          final forwardUnavailable = isForward && executor is! AiSessionExecutor;
          final rootUnavailable = isRoot && executor is! AiPrivilegeExecutor;
          final rootInvalid = isRoot && !_rootArgumentsValid(call.arguments);
          final unknownTool =
              mcp == null && !isForward && !isRoot && command == null;
          if (blockedByReadOnly ||
              forwardUnavailable ||
              rootUnavailable ||
              rootInvalid ||
              unknownTool) {
            entry.interruption = blockedByReadOnly
                ? '只读模式不允许此工具'
                : forwardUnavailable
                ? '当前会话不支持端口转发'
                : rootUnavailable
                ? '当前会话不支持提权'
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
          // The exported flag can be stale: the executor closes the elevated
          // channel on its own (dropped sudo channel) without notifying the
          // controller. Never return a false success or skip a needed manual
          // authorization; drop the cached flag and re-enter the approval flow.
          if (isRoot &&
              _rootActive &&
              executor is AiPrivilegeExecutor &&
              !executor.elevated) {
            _rootActive = false;
            _privilegeError = 'root 权限通道已结束，请重新授权';
          }
          // Already root for this turn with a live channel: no privilege is
          // being requested, so report the scope without another password.
          if (isRoot && _rootChannelLive) {
            _completeRootSuccess(entry, call, messages);
            continue;
          }
          // MCP calls, local forwards and root requests never inherit auto
          // approval: every one of them needs an explicit user decision.
          final explicitConsent = isForward || mcp != null || isRoot;
          if (explicitConsent ||
              (aiCommandNeedsApproval(call) &&
                  approvalMode == AiApprovalMode.manual)) {
            pending = AiToolCall(
              'approval-$revision-${_approvalSerial++}',
              readable,
              call.reason.trim().isEmpty
                  ? (isForward
                        ? '创建本地端口转发'
                        : isRoot
                        ? '申请 root 权限'
                        : '调用 MCP 工具')
                  : call.reason,
              true,
              name: call.name,
              arguments: call.arguments,
            );
            turn.saveForward = false;
            status = '等待确认';
            final approval = _approval = Completer<_ApprovalDecision>();
            _notify();
            final decision = await approval.future;
            if (identical(_approval, approval)) _approval = null;
            if (!_current(revision)) return;
            if (decision == _ApprovalDecision.cancelled) return;
            if (decision == _ApprovalDecision.denied) {
              _completeUserDenied(entry, call, messages);
              continue;
            }
          }
          if (!_current(revision)) return;
          if (!connected()) throw const AiFailure('SSH 已断开，未执行操作');
          if (isRoot) {
            if (!_rootChannelLive) {
              final wasRoot = _rootActive;
              _rootActive = false;
              _completeToolFailure(
                entry,
                call,
                messages,
                wasRoot ? 'root 权限通道已关闭，请重新提权' : '未获得 root 授权，未执行',
              );
              continue;
            }
            _completeRootSuccess(entry, call, messages);
            continue;
          }
          final saveForward = isForward && turn.saveForward;
          turn.saveForward = false;
          status = isForward || mcp != null ? '执行工具' : '执行命令';
          entry.started = true;
          _notify();
          if (isForward) {
            final session = executor;
            if (session is! AiSessionExecutor) {
              _completeToolFailure(
                entry,
                call,
                messages,
                '当前会话不支持端口转发',
              );
              continue;
            }
            try {
              final request = _forwardRequest(call.arguments);
              final result = await session.createPortForward(
                request,
                save: saveForward,
              );
              if (!_current(revision)) return;
              entry.output =
                  '${result.route}\n本机浏览器地址：${result.url}\n'
                  '${result.saved ? '规则已保存到主机端口转发列表' : '未保存为规则，仅本次会话有效'}';
              entry.exitCode = 0;
              entry.finished = true;
              messages.add({
                'role': 'tool',
                'tool_call_id': call.id,
                'content': jsonEncode(result.toJson()),
              });
            } on FormatException catch (error) {
              if (!_current(revision)) return;
              _completeToolFailure(
                entry,
                call,
                messages,
                '端口转发参数无效：${_toolReason(error)}',
              );
            } on AiFailure catch (error) {
              if (!_current(revision)) return;
              _completeToolFailure(entry, call, messages, error.message);
            } catch (error) {
              if (!_current(revision)) return;
              _completeToolFailure(
                entry,
                call,
                messages,
                '端口转发失败：${_toolReason(error)}',
              );
            }
            if (!_current(revision)) return;
            _unresolved.remove(call.id);
            _notify();
            continue;
          }
          if (mcp != null) {
            final mcpClient = turn.mcpClients[mcp.serverId];
            if (mcpClient == null) {
              _completeToolFailure(
                entry,
                call,
                messages,
                'MCP 连接已关闭，请重新发起对话',
                untrusted: true,
              );
              continue;
            }
            try {
              final result = await mcpClient
                  .callTool(mcp.toolName, call.arguments)
                  .timeout(const Duration(seconds: 120));
              if (!_current(revision)) return;
              final encoded = jsonEncode(result);
              const limit = 64000;
              final truncated = encoded.length > limit;
              final raw = truncated
                  ? encoded.substring(0, limit)
                  : encoded;
              final isError = result['isError'] == true;
              entry.output = truncated ? '$raw\n…输出已截断' : raw;
              if (isError) entry.interruption = 'MCP 工具返回错误';
              entry.exitCode = isError ? 1 : 0;
              entry.finished = true;
              messages.add({
                'role': 'tool',
                'tool_call_id': call.id,
                'content': jsonEncode({
                  'status': isError ? 'tool_error' : 'ok',
                  // MCP output is untrusted data and must stay data.
                  'untrusted': true,
                  'tool': mcp.toolName,
                  if (truncated) 'truncated': true,
                  'result': truncated ? raw : result,
                }),
              });
            } on TimeoutException {
              if (!_current(revision)) return;
              mcpClient.cancel();
              _completeToolFailure(
                entry,
                call,
                messages,
                'MCP 工具调用超时（120 秒），已取消',
                untrusted: true,
              );
            } catch (error) {
              if (!_current(revision)) return;
              _completeToolFailure(
                entry,
                call,
                messages,
                'MCP 工具调用失败：${_toolReason(error)}',
                untrusted: true,
              );
            }
            if (!_current(revision)) return;
            _unresolved.remove(call.id);
            _notify();
            continue;
          }
          if (command == null) {
            _completeToolFailure(entry, call, messages, '工具参数无效，未执行');
            continue;
          }
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
      turn.close();
      if (identical(_turn, turn)) _turn = null;
      if (revision == _revision) {
        running = false;
        pending = null;
        _clearRootState();
        _notify();
        // Runs after the turn is frozen, so the snapshot is complete.
        unawaited(_persistConversation());
      }
    }
  }

  @override
  void dispose() {
    stop();
    final turn = _turn;
    _turn = null;
    turn?.close();
    _disposed = true;
    super.dispose();
  }
}

/// Per-turn MCP connections and the forward save choice.
///
/// Owned by exactly one [AiTaskController.start] run: a stopped turn can never
/// close clients or clear choices created by a newer turn.
class _AiTurn {
  _AiTurn(this.revision);
  final int revision;
  final mcpClients = <String, McpClient>{};
  var mcpByModelName = const <String, _AiMcpBinding>{};
  bool saveForward = false;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    for (final client in mcpClients.values) {
      client.cancel();
      unawaited(client.close().catchError((Object _) {}));
    }
    mcpClients.clear();
    mcpByModelName = const {};
    saveForward = false;
  }
}

/// Maps the model-visible tool name back to the exact advertised MCP tool.
class _AiMcpBinding {
  const _AiMcpBinding({
    required this.serverId,
    required this.serverName,
    required this.toolName,
  });
  final String serverId, serverName, toolName;
}
