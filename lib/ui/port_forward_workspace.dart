import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/host_repository.dart';
import '../data/port_forward_manager.dart';
import '../data/ssh_connection.dart';
import '../domain/host.dart';
import '../domain/port_forward.dart';
import 'port_forward_panel.dart';

class PortForwardWorkspace extends StatefulWidget {
  const PortForwardWorkspace({
    super.key,
    required this.hosts,
    required this.sessions,
    required this.preferences,
    required this.onConnect,
    required this.onHosts,
    this.requestedSessionId,
    this.request = 0,
    this.showTitle = true,
  });
  final List<Host> hosts;
  final List<SshConnection> sessions;
  final KeyValueStore preferences;
  final Future<SshConnection?> Function(Host) onConnect;
  final VoidCallback onHosts;
  final String? requestedSessionId;
  final int request;
  final bool showTitle;
  @override
  State<PortForwardWorkspace> createState() => _PortForwardWorkspaceState();
}

class _PortForwardWorkspaceState extends State<PortForwardWorkspace> {
  String? _hostId;
  final _preferredSessions = <String, String>{};
  final _saved = <String, List<PortForwardRule>>{};
  final _failedHosts = <String>{};
  final _starting = <(String, String)>{};
  final _operationErrors = <(String, String), String>{};
  final _disposed = Completer<void>();
  Set<String> _knownHostIds = {};
  int _loadVersion = 0;
  bool _loading = true, _saving = false;
  String? _error;

  List<Host> get _hosts => {
    for (final session in widget.sessions) session.host.id: session.host,
    for (final host in widget.hosts) host.id: host,
  }.values.toList();
  PortForwardStore _store(String hostId) =>
      PortForwardStore(widget.preferences, hostId);

  @override
  void initState() {
    super.initState();
    _useRequestedSession();
    unawaited(_load());
  }

  @override
  void reassemble() {
    super.reassemble();
    _useRequestedSession();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PortForwardWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request ||
        oldWidget.requestedSessionId != widget.requestedSessionId) {
      _useRequestedSession();
    }
    if (!setEquals(_knownHostIds, _hosts.map((h) => h.id).toSet())) {
      unawaited(_load());
    }
  }

  void _useRequestedSession() {
    final session = widget.sessions
        .where((s) => s.id == widget.requestedSessionId)
        .firstOrNull;
    if (session != null) {
      _hostId = session.host.id;
      _preferredSessions[session.host.id] = session.id;
    }
  }

  @override
  void dispose() {
    _disposed.complete();
    super.dispose();
  }

  Future<void> _load({bool clearError = true}) async {
    final version = ++_loadVersion;
    final hosts = _hosts;
    _knownHostIds = hosts.map((h) => h.id).toSet();
    setState(() {
      _loading = true;
      if (clearError) _error = null;
    });
    final results = await Future.wait(
      hosts.map((host) async {
        try {
          return (host.id, await _store(host.id).load());
        } catch (_) {
          return (host.id, null);
        }
      }),
    );
    if (!mounted || version != _loadVersion) return;
    setState(() {
      _failedHosts.clear();
      for (final (id, rules) in results) {
        if (rules == null) {
          _failedHosts.add(id);
        } else {
          _saved[id] = rules;
        }
      }
      _saved.removeWhere((id, _) => !_knownHostIds.contains(id));
      _loading = false;
    });
  }

  List<SshConnection> _sessions(Host host) =>
      widget.sessions.where((s) => s.host.id == host.id).toList();
  SshConnection? _session(Host host) {
    final sessions = _sessions(host)
        .where(
          (s) =>
              s.host.address == host.address &&
              s.host.port == host.port &&
              s.host.username == host.username,
        )
        .toList();
    return sessions
            .where(
              (s) =>
                  s.id == _preferredSessions[host.id] &&
                  s.status == ConnectionStatus.connected,
            )
            .firstOrNull ??
        sessions
            .where((s) => s.status == ConnectionStatus.connected)
            .firstOrNull ??
        sessions
            .where((s) => s.status == ConnectionStatus.connecting)
            .firstOrNull ??
        sessions
            .where((s) => s.id == _preferredSessions[host.id])
            .firstOrNull ??
        sessions.lastOrNull;
  }

  bool _active(String hostId, String id) => widget.sessions.any(
    (s) => s.host.id == hostId && s.portForwards.state(id).active,
  );

  List<_RuleEntry> get _entries {
    final entries = <_RuleEntry>[];
    for (final host in _hosts) {
      final sessions = _sessions(host);
      final active = <String>{};
      for (final session in sessions) {
        for (final rule in session.portForwards.activeRules) {
          active.add(rule.id);
          entries.add(_RuleEntry(host, rule, session));
        }
      }
      for (final rule in _saved[host.id] ?? <PortForwardRule>[]) {
        if (!active.contains(rule.id)) {
          entries.add(_RuleEntry(host, rule, _session(host)));
        }
      }
    }
    return entries;
  }

  Future<void> _edit([_RuleEntry? current]) async {
    final hosts = _hosts;
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('请先添加 SSH 主机'),
          action: SnackBarAction(label: '管理连接', onPressed: widget.onHosts),
        ),
      );
      return;
    }
    final result = await showDialog<_RuleDraft>(
      context: context,
      builder: (dialogContext) => PortForwardEditor(
        rule: current?.rule,
        hosts: hosts,
        initialHostId: current?.host.id ?? _hostId,
        onSaveForHost: (rule, hostId) =>
            Navigator.pop(dialogContext, _RuleDraft(hostId, rule)),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!_hosts.any((h) => h.id == result.hostId)) {
        throw StateError('SSH 主机已移除，请重新选择。');
      }
      if (current != null && _active(current.host.id, current.rule.id)) {
        throw StateError('请先停止运行中的规则。');
      }
      final target = _store(result.hostId);
      final previousTarget = await target.load();
      final moving = current != null && current.host.id != result.hostId;
      var rule = result.rule;
      if (moving && previousTarget.any((r) => r.id == rule.id)) {
        rule = PortForwardRule.fromJson({
          ...rule.toJson(),
          'id': DateTime.now().microsecondsSinceEpoch.toString(),
        });
      }
      if (current != null && !moving) {
        if (!previousTarget.any((r) => r.id == current.rule.id)) {
          throw StateError('规则已被移除，请重新添加。');
        }
        await target.save([
          for (final r in previousTarget)
            if (r.id == current.rule.id) rule else r,
        ]);
      } else {
        final source = moving ? _store(current.host.id) : null;
        final previousSource = source == null ? null : await source.load();
        await target.save([...previousTarget, rule]);
        if (source != null) {
          try {
            await source.save(
              previousSource!.where((r) => r.id != current!.rule.id).toList(),
            );
          } catch (_) {
            // Preserve both configurations if rollback also fails; never drop a rule.
            try {
              await target.save(previousTarget);
            } catch (_) {
              throw StateError('主机切换未完成，两台主机均保留了规则，请检查后重试。');
            }
            rethrow;
          }
        }
      }
      _hostId = result.hostId;
      if (current != null) {
        _operationErrors.remove((current.host.id, current.rule.id));
      }
    } catch (error) {
      if (mounted) _error = '保存失败：${_message(error)}';
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        await _load(clearError: false);
      }
    }
  }

  Future<void> _delete(_RuleEntry entry) async {
    if (_active(entry.host.id, entry.rule.id)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final store = _store(entry.host.id);
      final rules = await store.load();
      await store.save(rules.where((r) => r.id != entry.rule.id).toList());
      _operationErrors.remove((entry.host.id, entry.rule.id));
    } catch (error) {
      if (mounted) _error = '删除失败：${_message(error)}';
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        await _load(clearError: false);
      }
    }
  }

  Future<void> _waitConnected(SshConnection session) async {
    final ready = Completer<void>();
    void changed() {
      if (session.status != ConnectionStatus.connecting && !ready.isCompleted) {
        ready.complete();
      }
    }

    session.addListener(changed);
    changed();
    try {
      await Future.any([ready.future, _disposed.future]);
    } finally {
      session.removeListener(changed);
    }
  }

  Future<void> _start(_RuleEntry entry) async {
    final key = (entry.host.id, entry.rule.id);
    if (_starting.isNotEmpty) return;
    setState(() {
      _starting.add(key);
      _operationErrors.remove(key);
    });
    try {
      var session = _session(entry.host);
      if (session == null ||
          session.status == ConnectionStatus.failed ||
          session.status == ConnectionStatus.closed) {
        session = await widget.onConnect(entry.host);
      }
      if (session == null || !mounted) return;
      _preferredSessions[entry.host.id] = session.id;
      if (session.status == ConnectionStatus.connecting) {
        await _waitConnected(session);
      }
      if (!mounted) return;
      if (session.status != ConnectionStatus.connected) {
        throw StateError(session.error ?? 'SSH 连接未建立，请重试。');
      }
      // The manager now owns startup, so its Cancel/Stop action remains usable.
      setState(() => _starting.remove(key));
      await session.portForwards.start(entry.rule);
    } catch (error) {
      if (mounted) setState(() => _operationErrors[key] = _message(error));
    } finally {
      if (mounted) setState(() => _starting.remove(key));
    }
  }

  static String _message(Object error) =>
      error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), '');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      for (final session in widget.sessions) ...[session, session.portForwards],
    ]),
    builder: (context, _) => PortForwardPage(
      showTitle: widget.showTitle,
      loading: _loading,
      saving: _saving,
      error: _error ?? (_failedHosts.isEmpty ? null : '部分主机的转发规则读取失败，请重新加载。'),
      onRetry: _failedHosts.isEmpty ? null : _load,
      onAdd: _loading || _saving ? null : _edit,
      children: [for (final entry in _entries) _card(entry)],
    ),
  );

  Widget _card(_RuleEntry entry) {
    final key = (entry.host.id, entry.rule.id);
    final state =
        entry.session?.portForwards.state(entry.rule.id) ??
        const PortForwardState();
    final error = _operationErrors[key];
    final sessions = _sessions(entry.host);
    final sessionLabel = sessions.length > 1 && entry.session != null
        ? ' · 会话 ${sessions.indexOf(entry.session!) + 1}'
        : '';
    return PortForwardRuleCard(
      key: ValueKey(
        'forward-rule-${entry.host.id}-${entry.rule.id}-${entry.session?.id}',
      ),
      hostLabel: '${entry.host.name}$sessionLabel',
      rule: entry.rule,
      state: error == null
          ? state
          : PortForwardState(
              status: state.active ? state.status : PortForwardStatus.failed,
              port: state.port,
              error: error,
            ),
      connected: _starting.isEmpty && !_failedHosts.contains(entry.host.id),
      connecting: _starting.contains(key),
      saving: _saving,
      blocked: _failedHosts.contains(entry.host.id),
      onEdit: (_) => _edit(entry),
      onDelete: (_) => _delete(entry),
      onStart: (_) => _start(entry),
      onStop: (_) => entry.session?.portForwards.stop(entry.rule.id),
    );
  }
}

class _RuleEntry {
  const _RuleEntry(this.host, this.rule, this.session);
  final Host host;
  final PortForwardRule rule;
  final SshConnection? session;
}

class _RuleDraft {
  const _RuleDraft(this.hostId, this.rule);
  final String hostId;
  final PortForwardRule rule;
}
