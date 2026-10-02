import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/port_forward.dart';
import 'host_repository.dart';

abstract interface class PortForwardHandle {
  int get port;
  Future<void> close();
}

typedef StartPortForward = Future<PortForwardHandle> Function(
  PortForwardRule rule,
);

/// One manager per SSH session; a late bind cannot survive session shutdown.
class PortForwardManager extends ChangeNotifier {
  PortForwardManager(this._start);
  final StartPortForward _start;
  final _runs = <String, _ForwardRun>{};
  bool _closed = false, _disposed = false;
  PortForwardState state(String id) =>
      _runs[id]?.state ?? const PortForwardState();
  int get activeCount => _runs.values.where((run) => run.state.active).length;
  List<PortForwardRule> get activeRules => [
    for (final run in _runs.values)
      if (run.state.active) run.rule,
  ];

  void reportConnectionError(String id, Object error) {
    final run = _runs[id];
    if (_closed ||
        run == null ||
        run.state.status != PortForwardStatus.running) {
      return;
    }
    run.state = PortForwardState(
      status: PortForwardStatus.running,
      port: run.handle?.port,
      error: '目标连接失败：${_message(error)}',
    );
    _notify();
  }

  Future<void> start(PortForwardRule rule) async {
    if (_closed) throw StateError('SSH 会话已断开，请重新连接');
    rule.validate();
    if (state(rule.id).active) return;
    final run = _ForwardRun(rule);
    _runs[rule.id] = run;
    _notify();
    try {
      final handle = await _start(rule);
      run.handle = handle;
      if (_closed || run.cancelled) {
        await handle.close();
        run.handle = null;
        run.state = const PortForwardState();
      } else {
        run.state = PortForwardState(
          status: PortForwardStatus.running,
          port: handle.port,
        );
      }
    } catch (error) {
      run.state = PortForwardState(
        status: run.handle != null
            ? PortForwardStatus.running
            : run.cancelled
            ? PortForwardStatus.stopped
            : PortForwardStatus.failed,
        port: run.handle?.port,
        error: run.cancelled && run.handle == null ? null : _message(error),
      );
    } finally {
      run.ready.complete();
      _notify();
    }
  }

  Future<void> stop(String id) async {
    final run = _runs[id];
    if (run == null || !run.state.active) return;
    if (run.stopping != null) return run.stopping;
    run.cancelled = true;
    run.state = PortForwardState(
      status: PortForwardStatus.stopping,
      port: run.handle?.port,
    );
    _notify();
    final operation = _stop(run);
    run.stopping = operation;
    await operation;
  }

  Future<void> _stop(_ForwardRun run) async {
    try {
      await run.ready.future;
      await run.handle?.close();
      run.handle = null;
      run.state = const PortForwardState();
    } catch (error) {
      run.state = PortForwardState(
        status: PortForwardStatus.running,
        port: run.handle?.port,
        error: '停止失败：${_message(error)}。可重试或断开 SSH 会话。',
      );
    } finally {
      run.stopping = null;
      _notify();
    }
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(_runs.keys.toList().map(stop));
  }

  /// Wait for the previous transport's listeners to stop before accepting runs.
  Future<void> reopen() async {
    await close();
    if (!_disposed) _closed = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _message(Object error) => error is FormatException
      ? error.message
      : error.toString().replaceFirst(
          RegExp(r'^(Bad state: |Exception: )'),
          '',
        );
  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

class _ForwardRun {
  _ForwardRun(this.rule);
  final PortForwardRule rule;
  PortForwardState state = const PortForwardState(
    status: PortForwardStatus.starting,
  );
  PortForwardHandle? handle;
  final ready = Completer<void>();
  Future<void>? stopping;
  bool cancelled = false;
}

/// Listener addresses are device-specific, so rules stay in local preferences.
class PortForwardStore {
  PortForwardStore(this.preferences, this.hostId);
  final KeyValueStore preferences;
  final String hostId;
  String get _key => 'harbor.port-forwards.v1.$hostId';
  Future<List<PortForwardRule>> load() async {
    final raw = await preferences.read(_key);
    if (raw == null) return [];
    final values = (jsonDecode(raw) as List)
        .map((v) => PortForwardRule.fromJson(v as Map<String, dynamic>))
        .toList();
    if (values.map((v) => v.id).toSet().length != values.length) {
      throw const FormatException('端口转发规则 ID 重复');
    }
    return values;
  }

  Future<void> save(List<PortForwardRule> rules) async {
    for (final rule in rules) {
      rule.validate();
    }
    if (rules.map((v) => v.id).toSet().length != rules.length) {
      throw const FormatException('端口转发规则 ID 重复');
    }
    await preferences.write(
      _key,
      jsonEncode(rules.map((r) => r.toJson()).toList()),
    );
  }
}
