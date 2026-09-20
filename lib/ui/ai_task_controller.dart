import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/terminal_ai.dart';

class AiTaskEntry {
  AiTaskEntry(this.text, {this.command = false});
  final String text;
  final bool command;
  String output = '';
  String? reason;
  int? exitCode;
  bool finished = false;
}

/// A conservative extra check, in addition to the model's explicit approval flag.
bool aiCommandNeedsApproval(AiToolCall call) =>
    call.requiresApproval ||
    RegExp(
      r'(^|[\s;&|/])(sudo|su|rm|rmdir|mv|dd|mkfs\S*|wipefs|shred|truncate|chmod|chown|reboot|shutdown|poweroff|kill|killall|pkill|tee)(\s|$)|(^|[^>])>(?!>)|\b(apt|apt-get|yum|dnf|pip|npm)\s|\bsystemctl\s+(stop|restart|reload|disable|enable|mask)|\bgit\s+(push|reset|clean|checkout|restore|rebase)|\b(docker|kubectl)\s+(rm|rmi|stop|kill|restart|delete|apply|replace|rollout)|\bservice\s+\S+\s+(stop|restart|reload)',
      caseSensitive: false,
    ).hasMatch(call.command);

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
    status = message ?? '任务已停止；已请求终止正在运行的命令';
    _notify();
  }

  Future<void> start(String goal) async {
    if (running || _disposed) return;
    failure = null;
    try {
      settings().endpoint;
      if (!connected()) throw const AiFailure('请先连接 SSH');
      if (goal.trim().isEmpty || goal.length > 16000) {
        throw const AiFailure('请输入不超过 16000 字符的任务目标');
      }
    } on AiFailure catch (error) {
      failure = error.message;
      _notify();
      return;
    }
    final config = settings();
    final revision = ++_revision;
    final client = _client = clientFactory();
    final executor = _executor = executorFactory();
    entries.clear();
    entries.add(AiTaskEntry(goal.trim()));
    running = true;
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': aiSystemPrompt},
      {'role': 'user', 'content': goal.trim()},
    ];
    var commands = 0;
    try {
      while (_current(revision)) {
        if (!connected()) throw const AiFailure('SSH 已断开，任务已停止');
        status = 'AI 正在分析';
        _notify();
        final reply = await client.complete(config, messages);
        if (!_current(revision)) return;
        messages.add(reply.message);
        if (reply.text.trim().isNotEmpty) {
          entries.add(AiTaskEntry(reply.text.trim()));
        }
        if (reply.calls.isEmpty) {
          status = '任务已结束';
          return;
        }
        for (final call in reply.calls) {
          if (!_current(revision)) return;
          if (++commands > 24) {
            throw const AiFailure('已达到本次任务 24 条命令的上限，请查看结果后发起下一步任务');
          }
          final entry = AiTaskEntry(call.command, command: true)
            ..reason = call.reason;
          entries.add(entry);
          if (aiCommandNeedsApproval(call)) {
            pending = call;
            status = '等待确认';
            final approval = _approval = Completer<bool>();
            _notify();
            if (!await approval.future || !_current(revision)) return;
          }
          if (!_current(revision)) return;
          if (!connected()) throw const AiFailure('SSH 已断开，未执行命令');
          status = '正在执行第 $commands 条命令';
          _notify();
          final result = await executor.execute(call.command, (output) {
            if (!_current(revision)) return;
            entry.output += output;
            _notify();
          });
          if (!_current(revision)) return;
          entry.output = result.output;
          if (result.truncated) entry.output += '\n…输出超过 16000 字符，已截断';
          entry.exitCode = result.exitCode;
          entry.finished = true;
          messages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'content': jsonEncode(result.toJson()),
          });
          _notify();
        }
      }
    } catch (error) {
      if (_current(revision)) {
        failure = error is AiFailure ? error.message : 'AI 任务中断，请检查配置后重试';
        status = '任务中断';
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
