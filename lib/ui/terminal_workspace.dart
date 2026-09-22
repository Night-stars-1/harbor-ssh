import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/ssh_connection.dart';
import '../data/terminal_ai.dart';
import '../domain/host.dart';
import 'terminal_pane.dart';
import 'theme.dart';

/// Keeps each terminal view attached to its session while panes move or resize.
class TerminalWorkspace extends StatefulWidget {
  const TerminalWorkspace({
    super.key,
    required this.sessions,
    required this.activeSession,
    required this.hosts,
    required this.desktop,
    required this.visible,
    required this.mobileController,
    required this.onSelect,
    required this.onConnect,
    required this.onClose,
    required this.onFiles,
    this.aiSettings,
    this.onAiSettings,
    this.fontSize = 14,
    this.terminalWrap = true,
  });

  final List<SshConnection> sessions;
  final SshConnection? activeSession;
  final List<Host> hosts;
  final bool desktop, visible;
  final TerminalPaneController mobileController;
  final ValueChanged<String> onSelect;
  final Future<void> Function(Host) onConnect;
  final ValueChanged<SshConnection> onClose, onFiles;
  final AiSettings Function()? aiSettings;
  final VoidCallback? onAiSettings;
  final double fontSize;
  final bool terminalWrap;

  @override
  State<TerminalWorkspace> createState() => _TerminalWorkspaceState();
}

class _TerminalWorkspaceState extends State<TerminalWorkspace> {
  final _slots = <String?>[null];
  final _keys = <String, GlobalKey>{};
  final _paneKeys = <int, GlobalKey>{};
  final _controllers = <String, TerminalPaneController>{};
  _TerminalLayout? _root;
  int _nextSplit = 0;
  int _focused = 0;
  int? _pendingConnectionSide;
  String? _lastActiveId;

  // Also retains any occupied slots when hot reloading from the two-pane layout.
  _TerminalLayout get _layout {
    if (_root == null) {
      final occupied = [
        for (var i = 0; i < _slots.length; i++)
          if (_slots[i] != null || i == _focused) i,
      ];
      _root = _TerminalLeaf(occupied.first);
      for (final side in occupied.skip(1)) {
        _root = _TerminalSplit(
          _nextSplit++,
          Axis.horizontal,
          _root!,
          _TerminalLeaf(side),
        );
      }
    }
    return _root!;
  }

  Map<String, SshConnection> get _sessions => {
    for (final session in widget.sessions) session.id: session,
    if (widget.activeSession != null)
      widget.activeSession!.id: widget.activeSession!,
  };

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TerminalWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
    if (widget.visible &&
        (!oldWidget.visible || oldWidget.desktop != widget.desktop)) {
      _requestFocus(_slots[_focused]);
    }
  }

  void _sync() {
    final sessions = _sessions;
    for (final side in _layout.panes.toList()) {
      final id = _slots[side];
      if (id != null && !sessions.containsKey(id)) {
        _removePane(side);
      }
    }
    _keys.removeWhere((id, _) => !sessions.containsKey(id));
    _controllers.removeWhere((id, _) => !sessions.containsKey(id));
    final active = widget.activeSession?.id;
    if (active != null &&
        (active != _lastActiveId || !_slots.contains(active))) {
      final existing = _slots.indexOf(active);
      if (existing >= 0) {
        _focused = existing;
      } else {
        if (_layout.panes.contains(_pendingConnectionSide)) {
          _focused = _pendingConnectionSide!;
        }
        _slots[_focused] = active;
      }
      _pendingConnectionSide = null;
      _requestFocus(active);
    }
    _lastActiveId = active;
  }

  void _requestFocus(String? id) {
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.visible || _slots[_focused] != id) return;
      (widget.desktop ? _controllers[id] : widget.mobileController)
          ?.requestFocus();
      _revealPane(_focused);
    });
  }

  void _revealPane(int side) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.visible || side != _focused) return;
      final context = _paneKeys[side]?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(context, alignment: .5);
      }
    });
  }

  void _removePane(int side) {
    _root = _layout.without(side) ?? _TerminalLeaf(side);
    _slots[side] = null;
    if (!_layout.panes.contains(_focused)) _focused = _layout.panes.first;
    if (_pendingConnectionSide == side) _pendingConnectionSide = null;
    _paneKeys.remove(side);
  }

  void _activate(int side, {bool requestFocus = true}) {
    final id = _slots[side];
    if (_focused != side) setState(() => _focused = side);
    if (id != null && widget.activeSession?.id != id) widget.onSelect(id);
    if (requestFocus) _requestFocus(id);
  }

  void _assign(int side, String id) {
    setState(() {
      final other = _slots.indexOf(id);
      if (other >= 0 && other != side) _slots[other] = _slots[side];
      _slots[side] = id;
      _focused = side;
    });
    widget.onSelect(id);
    _requestFocus(id);
  }

  void _split(int side, String action) {
    setState(() {
      if (action == 'single') {
        for (final other in _layout.panes) {
          if (other != side) _slots[other] = null;
        }
        _root = _TerminalLeaf(side);
        _focused = side;
        _pendingConnectionSide = null;
      } else if (action == 'remove') {
        _removePane(side);
      } else {
        final next = _slots.length;
        _slots.add(
          _sessions.keys.where((id) => !_slots.contains(id)).firstOrNull,
        );
        _root = _layout.replace(
          side,
          _TerminalSplit(
            _nextSplit++,
            action == 'horizontal' ? Axis.horizontal : Axis.vertical,
            _TerminalLeaf(side),
            _TerminalLeaf(next),
          ),
        );
        _focused = next;
      }
    });
    final target = _slots[_focused];
    if (target != null) {
      widget.onSelect(target);
      _requestFocus(target);
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
      _revealPane(_focused);
    }
  }

  Widget _splitButton(int side) => PopupMenuButton<String>(
    key: ValueKey('terminal-split-menu-$side'),
    tooltip: '',
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: HarborShapes.superellipse(),
    icon: const Icon(
      Icons.splitscreen_rounded,
      size: 20,
      semanticLabel: '终端分屏',
    ),
    onSelected: (value) => _split(side, value),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'horizontal', child: Text('左右分屏')),
      const PopupMenuItem(value: 'vertical', child: Text('上下分屏')),
      if (_layout is _TerminalSplit) ...[
        const PopupMenuItem(value: 'remove', child: Text('关闭此分屏')),
        const PopupMenuItem(value: 'single', child: Text('取消分屏')),
      ],
    ],
  );

  Widget _sessionPicker(int side, String title) => PopupMenuButton<Object>(
    key: ValueKey('terminal-session-picker-$side'),
    tooltip: '',
    elevation: 0,
    position: PopupMenuPosition.under,
    shape: HarborShapes.superellipse(),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    onSelected: (value) {
      if (value is SshConnection) {
        _assign(side, value.id);
      } else if (value is Host) {
        setState(() => _focused = side);
        _connectInPane(side, value);
      }
    },
    itemBuilder: (_) => [
      for (final session in _sessions.values)
        PopupMenuItem(
          value: session,
          child: Row(
            children: [
              const Icon(Icons.terminal_rounded, size: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  session.host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      for (final host in widget.hosts)
        PopupMenuItem(
          value: host,
          child: Row(
            children: [
              const Icon(Icons.add_rounded, size: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  '新建 · ${host.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const Icon(Icons.expand_more_rounded, size: 18),
        ],
      ),
    ),
  );

  Future<void> _connectInPane(int side, Host host) async {
    _pendingConnectionSide = side;
    await widget.onConnect(host);
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pendingConnectionSide = null;
    });
  }

  Widget _pane(int side, {required bool split, required double height}) {
    final session = _sessions[_slots[side]];
    final colors = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (_) => _activate(side, requestFocus: false),
      child: Material(
        key: ValueKey('terminal-region-$side'),
        color: colors.surfaceContainerLow,
        shape: HarborShapes.superellipse().copyWith(
          side: BorderSide(
            color: split && _focused == side
                ? colors.primary.withValues(alpha: .5)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.all(split ? 2 : 0),
          child: session == null
              ? Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(child: _sessionPicker(side, '选择会话')),
                          _splitButton(side),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '选择已有会话或新建 SSH 连接',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ],
                )
              : TerminalPane(
                  key: _keys.putIfAbsent(session.id, GlobalKey.new),
                  session: session,
                  aiSettings: widget.aiSettings,
                  onAiSettings: widget.onAiSettings,
                  controller: !widget.desktop && _focused == side
                      ? widget.mobileController
                      : _controllers.putIfAbsent(
                          session.id,
                          TerminalPaneController.new,
                        ),
                  showHeader: widget.desktop,
                  maxErrorHeight: (height - 160).clamp(0, 180),
                  fontSize: widget.fontSize,
                  terminalWrap: widget.terminalWrap,
                  onFocused: () {
                    final assignedSide = _slots.indexOf(session.id);
                    if (widget.visible &&
                        _layout.panes.contains(assignedSide) &&
                        (widget.desktop || assignedSide == _focused) &&
                        (_pendingConnectionSide == null ||
                            _pendingConnectionSide == assignedSide)) {
                      _activate(assignedSide, requestFocus: false);
                    }
                  },
                  headerActions: widget.desktop
                      ? [_splitButton(side)]
                      : const [],
                  onReconnect: () {
                    _activate(side);
                    widget.onConnect(session.host);
                  },
                  onClose: () => widget.onClose(session),
                  onFiles: () => widget.onFiles(session),
                ),
        ),
      ),
    );
  }

  Widget _divider(_TerminalSplit split, Rect rect) {
    final horizontal = split.axis == Axis.horizontal;
    final available = (horizontal ? rect.width : rect.height) - 12;
    final firstMin = horizontal
        ? split.first.minimum.width
        : split.first.minimum.height;
    final secondMin = horizontal
        ? split.second.minimum.width
        : split.second.minimum.height;
    final extent = (available * split.ratio).clamp(
      firstMin,
      available - secondMin,
    );
    void drag(double delta) => setState(() {
      final current = (available * split.ratio).clamp(
        firstMin,
        available - secondMin,
      );
      split.ratio = ((current + delta) / available).clamp(
        firstMin / available,
        1 - secondMin / available,
      );
    });
    return Positioned.fromRect(
      key: ValueKey('terminal-divider-${split.id}'),
      rect: horizontal
          ? Rect.fromLTWH(rect.left + extent, rect.top, 12, rect.height)
          : Rect.fromLTWH(rect.left, rect.top + extent, rect.width, 12),
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeLeftRight
            : SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          key: ValueKey('terminal-split-handle-${split.id}'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: horizontal
              ? (event) => drag(event.delta.dx)
              : null,
          onVerticalDragUpdate: horizontal
              ? null
              : (event) => drag(event.delta.dy),
          onDoubleTap: () => setState(() => split.ratio = .5),
          child: Center(
            child: Container(
              width: horizontal ? 3 : 32,
              height: horizontal ? 32 : 3,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(widget.desktop ? 8 : 0),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final layout = _layout;
        final minimum = layout.minimum;
        final size = widget.desktop
            ? Size(
                math.max(constraints.maxWidth, minimum.width),
                math.max(constraints.maxHeight, minimum.height),
              )
            : constraints.biggest;
        final panes = <int, Rect>{};
        final dividers = <Widget>[];
        void place(_TerminalLayout node, Rect rect) {
          if (node is _TerminalLeaf) {
            panes[node.side] = rect;
          } else if (node is _TerminalSplit) {
            final horizontal = node.axis == Axis.horizontal;
            final available = (horizontal ? rect.width : rect.height) - 12;
            final firstMin = horizontal
                ? node.first.minimum.width
                : node.first.minimum.height;
            final secondMin = horizontal
                ? node.second.minimum.width
                : node.second.minimum.height;
            final extent = (available * node.ratio).clamp(
              firstMin,
              available - secondMin,
            );
            place(
              node.first,
              horizontal
                  ? Rect.fromLTWH(rect.left, rect.top, extent, rect.height)
                  : Rect.fromLTWH(rect.left, rect.top, rect.width, extent),
            );
            place(
              node.second,
              horizontal
                  ? Rect.fromLTWH(
                      rect.left + extent + 12,
                      rect.top,
                      available - extent,
                      rect.height,
                    )
                  : Rect.fromLTWH(
                      rect.left,
                      rect.top + extent + 12,
                      rect.width,
                      available - extent,
                    ),
            );
            dividers.add(_divider(node, rect));
          }
        }

        if (widget.desktop) {
          place(layout, Offset.zero & size);
        } else {
          for (final side in layout.panes) {
            panes[side] = Offset.zero & size;
          }
        }
        // Keep a flat, keyed stack so splitting an existing leaf does not
        // recreate its terminal, selection, scroll position or input state.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: size.width,
            height: constraints.maxHeight,
            child: SingleChildScrollView(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  children: [
                    for (final entry in panes.entries)
                      Positioned.fromRect(
                        key: ValueKey('terminal-position-${entry.key}'),
                        rect: entry.value,
                        child: Offstage(
                          offstage: !widget.desktop && entry.key != _focused,
                          child: ExcludeFocus(
                            excluding:
                                !widget.visible ||
                                (!widget.desktop && entry.key != _focused),
                            child: KeyedSubtree(
                              key: _paneKeys.putIfAbsent(
                                entry.key,
                                GlobalKey.new,
                              ),
                              child: _pane(
                                entry.key,
                                split: widget.desktop && panes.length > 1,
                                height: entry.value.height,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ...dividers,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

sealed class _TerminalLayout {
  Iterable<int> get panes;
  Size get minimum;
  _TerminalLayout replace(int side, _TerminalLayout replacement);
  _TerminalLayout? without(int side);
}

class _TerminalLeaf extends _TerminalLayout {
  _TerminalLeaf(this.side);
  final int side;
  @override
  Iterable<int> get panes => [side];
  @override
  Size get minimum => const Size(240, 160);
  @override
  _TerminalLayout replace(int side, _TerminalLayout replacement) =>
      this.side == side ? replacement : this;
  @override
  _TerminalLayout? without(int side) => this.side == side ? null : this;
}

class _TerminalSplit extends _TerminalLayout {
  _TerminalSplit(this.id, this.axis, this.first, this.second);
  final int id;
  final Axis axis;
  _TerminalLayout first, second;
  double ratio = .5;
  @override
  Iterable<int> get panes sync* {
    yield* first.panes;
    yield* second.panes;
  }

  @override
  Size get minimum {
    final a = first.minimum, b = second.minimum;
    return axis == Axis.horizontal
        ? Size(a.width + 12 + b.width, math.max(a.height, b.height))
        : Size(math.max(a.width, b.width), a.height + 12 + b.height);
  }

  @override
  _TerminalLayout replace(int side, _TerminalLayout replacement) {
    first = first.replace(side, replacement);
    second = second.replace(side, replacement);
    return this;
  }

  @override
  _TerminalLayout? without(int side) {
    final a = first.without(side), b = second.without(side);
    if (a == null) return b;
    if (b == null) return a;
    first = a;
    second = b;
    return this;
  }
}
