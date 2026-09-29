import 'package:flutter/material.dart';

import '../data/port_forward_manager.dart';
import '../data/ssh_connection.dart';
import '../domain/port_forward.dart';
import 'port_forward_panel.dart';

class PortForwardDialog extends StatefulWidget {
  const PortForwardDialog({
    super.key,
    required this.session,
    required this.store,
  });
  final SshConnection session;
  final PortForwardStore store;
  @override
  State<PortForwardDialog> createState() => _PortForwardDialogState();
}

class _PortForwardDialogState extends State<PortForwardDialog> {
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: SizedBox(
      width: 720,
      height: 620,
      child: PortForwardRules(
        hostName: widget.session.host.name,
        session: widget.session,
        store: widget.store,
        onClose: () => Navigator.pop(context),
      ),
    ),
  );
}

/// Shared rule editor for the home tab and the optional dialog presentation.
class PortForwardRules extends StatefulWidget {
  const PortForwardRules({
    super.key,
    required this.hostName,
    required this.store,
    this.session,
    this.onClose,
    this.showHeader = true,
  });
  final String hostName;
  final PortForwardStore store;
  final SshConnection? session;
  final VoidCallback? onClose;
  final bool showHeader;
  @override
  State<PortForwardRules> createState() => _PortForwardRulesState();
}

class _PortForwardRulesState extends State<PortForwardRules> {
  List<PortForwardRule> _rules = [];
  bool _loading = true, _saving = false, _loadFailed = false;
  String? _error;
  // Another session of this host may edit or delete a saved rule. Keep the
  // actual running configuration visible here, including its Stop action.
  List<PortForwardRule> get _visibleRules => {
    for (final rule in _rules) rule.id: rule,
    for (final rule
        in widget.session?.portForwards.activeRules ?? <PortForwardRule>[])
      rule.id: rule,
  }.values.toList();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await widget.store.load();
      if (mounted) {
        setState(() {
          _rules = rules;
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _error = '无法读取转发规则，请重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(List<PortForwardRule> rules) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(rules);
      if (mounted) setState(() => _rules = rules);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，规则尚未更改，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([PortForwardRule? current]) async {
    final result = await showDialog<PortForwardRule>(
      context: context,
      builder: (_) => PortForwardEditor(rule: current),
    );
    if (result == null || !mounted) return;
    await _save(
      current == null
          ? [..._rules, result]
          : [
              for (final rule in _rules)
                if (rule.id == current.id) result else rule,
            ],
    );
  }

  Future<void> _start(PortForwardRule rule) async {
    try {
      final session = widget.session;
      if (session == null) throw StateError('请先连接主机');
      await session.portForwards.start(rule);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      if (widget.session != null) widget.session!,
      if (widget.session != null) widget.session!.portForwards,
    ]),
    builder: (context, _) => PortForwardPanel(
      hostName: widget.hostName,
      showHeader: widget.showHeader,
      rules: _visibleRules,
      stateFor: (id) =>
          widget.session?.portForwards.state(id) ?? const PortForwardState(),
      connected: widget.session?.status == ConnectionStatus.connected,
      loading: _loading,
      saving: _saving,
      error: _error,
      onRetry: _loadFailed ? _load : null,
      onAdd: _edit,
      onEdit: _edit,
      onDelete: (rule) =>
          _save(_rules.where((item) => item.id != rule.id).toList()),
      onStart: _start,
      onStop: (rule) => widget.session?.portForwards.stop(rule.id),
      onClose: widget.onClose,
    ),
  );
}
