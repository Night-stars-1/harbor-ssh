import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
  }) : clientFactory = clientFactory ?? TerminalAiClient.new;
  final AiSettings Function() settings;
  final AiCommandExecutor Function() executorFactory;
  final bool Function() connected;
  final TerminalAiClient Function() clientFactory;
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

  bool get autoApprove => approvalMode == AiApprovalMode.auto;

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

  void newConversation() {
    if (running || _disposed) return;
    _revision++;
    _history.clear();
    _unresolved.clear();
    entries.clear();
    failure = null;
    status = '';
    turnStartedAt = null;
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
  }

  Future<void> start(String goal, {List<AiImage> images = const []}) async {
    if (running || _disposed) return;
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
