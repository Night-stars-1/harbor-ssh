import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/host.dart';
import '../domain/port_forward.dart';
import 'expressive_widgets.dart';
import 'theme.dart';

/// Presentation-only adapter for a single SSH session and dialog previews.
class PortForwardPanel extends StatelessWidget {
  const PortForwardPanel({
    super.key,
    required this.hostName,
    required this.rules,
    required this.stateFor,
    required this.connected,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
    required this.onStart,
    required this.onStop,
    this.onClose,
    this.showHeader = true,
    this.loading = false,
    this.saving = false,
    this.error,
    this.onRetry,
  });
  final String hostName;
  final List<PortForwardRule> rules;
  final PortForwardState Function(String id) stateFor;
  final bool connected, loading, saving, showHeader;
  final String? error;
  final VoidCallback onAdd;
  final VoidCallback? onClose, onRetry;
  final ValueChanged<PortForwardRule> onEdit, onDelete, onStart, onStop;

  @override
  Widget build(BuildContext context) => PortForwardPage(
    showTitle: showHeader,
    loading: loading,
    saving: saving,
    error: error,
    onRetry: onRetry,
    onClose: onClose,
    onAdd: loading || saving || onRetry != null ? null : onAdd,
    children: [
      for (final rule in rules)
        PortForwardRuleCard(
          rule: rule,
          state: stateFor(rule.id),
          connected: connected,
          saving: saving,
          blocked: onRetry != null,
          hostLabel: hostName,
          onEdit: onEdit,
          onDelete: onDelete,
          onStart: onStart,
          onStop: onStop,
        ),
    ],
  );
}

/// Minimal home surface: one action and the rules, or a quiet empty state.
class PortForwardPage extends StatelessWidget {
  const PortForwardPage({
    super.key,
    required this.children,
    required this.onAdd,
    this.showTitle = true,
    this.loading = false,
    this.saving = false,
    this.error,
    this.onRetry,
    this.onClose,
  });
  final List<Widget> children;
  final VoidCallback? onAdd, onRetry, onClose;
  final bool showTitle, loading, saving;
  final String? error;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final padding = constraints.maxWidth < 600 ? 20.0 : 28.0;
      final title = Text('端口转发', style: theme.textTheme.headlineSmall);
      final actions = Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            key: const ValueKey('add-forward'),
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(saving ? '正在保存…' : '添加规则'),
          ),
          if (onClose != null)
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
        ],
      );
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(padding, padding, padding, 16),
                child:
                    showTitle &&
                        (constraints.maxWidth < 360 ||
                            MediaQuery.textScalerOf(context).scale(14) > 20)
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: actions,
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          if (showTitle)
                            Expanded(child: title)
                          else
                            const Spacer(),
                          actions,
                        ],
                      ),
              ),
              Expanded(
                child: CustomScrollView(
                  key: const ValueKey('forward-page-scroll'),
                  slivers: [
                    if (error != null)
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: padding),
                        sliver: SliverToBoxAdapter(
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.errorContainer
                                  .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  error!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                                if (onRetry != null)
                                  TextButton(
                                    onPressed: onRetry,
                                    child: const Text('重新加载'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (loading)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (children.isEmpty && error == null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Padding(
                          padding: EdgeInsets.all(padding),
                          child: const Center(child: _ForwardEmptyState()),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          padding,
                          0,
                          padding,
                          padding,
                        ),
                        sliver: SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final available = constraints.crossAxisExtent;
                            final grid =
                                available + padding * 2 >= 680 &&
                                MediaQuery.textScalerOf(context).scale(16) <=
                                    20;
                            final columns = grid && available >= 760 ? 2 : 1;
                            final gap = grid ? 16.0 : HarborShapes.listGap;
                            final width = grid
                                ? ((available - gap * (columns - 1)) / columns)
                                      .clamp(0.0, 480.0)
                                : available;
                            return SliverList.separated(
                              itemCount: (children.length / columns).ceil(),
                              separatorBuilder: (_, _) => SizedBox(height: gap),
                              itemBuilder: (context, row) {
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (
                                      var column = 0;
                                      column < columns &&
                                          row * columns + column <
                                              children.length;
                                      column++
                                    ) ...[
                                      if (column > 0) SizedBox(width: gap),
                                      SizedBox(
                                        width: width,
                                        child: _ForwardItemLayout(
                                          slot: grid
                                              ? HarborListSlot.single
                                              : HarborShapes.listSlot(
                                                  row,
                                                  children.length,
                                                ),
                                          asCard: grid,
                                          child:
                                              children[row * columns + column],
                                        ),
                                      ),
                                    ],
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class PortForwardRuleCard extends StatelessWidget {
  const PortForwardRuleCard({
    super.key,
    required this.rule,
    required this.state,
    required this.connected,
    required this.onEdit,
    required this.onDelete,
    required this.onStart,
    required this.onStop,
    this.hostLabel,
    this.saving = false,
    this.blocked = false,
    this.connecting = false,
    this.openBrowser,
  });
  final PortForwardRule rule;
  final PortForwardState state;
  final bool connected, saving, blocked, connecting;
  final String? hostLabel;
  final Future<bool> Function(Uri)? openBrowser;
  final ValueChanged<PortForwardRule> onEdit, onDelete, onStart, onStop;

  Future<void> _openInBrowser(BuildContext context, Uri uri) async {
    try {
      final opened =
          await (openBrowser?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (opened) return;
    } catch (_) {
      // The same notice also covers a missing browser or launcher failure.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开浏览器，请检查默认浏览器设置')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final layout = context
        .dependOnInheritedWidgetOfExactType<_ForwardItemLayout>();
    final active = state.status == PortForwardStatus.running;
    final browserUri = active ? rule.browserUri(actualPort: state.port) : null;
    final failed = state.status == PortForwardStatus.failed;
    final editable = !saving && !connecting && !state.active && !blocked;
    final toggleLabel = connecting
        ? '正在连接…'
        : state.status == PortForwardStatus.starting
        ? '取消启动'
        : state.status == PortForwardStatus.stopping
        ? '正在停止'
        : state.active
        ? '停止'
        : '启动';
    final route = rule.route(actualPort: state.port);
    final routeTip = [
      rule.description,
      route,
      if (rule.bindPort == 0 && state.port == null) '启动时自动分配监听端口',
    ].join('\n');
    final statusBadge = ForwardStatusBadge(
      label: connecting ? '正在连接' : state.label,
      color: failed
          ? colors.onErrorContainer
          : active
          ? colors.onPrimaryContainer
          : colors.onSurfaceVariant,
      backgroundColor: failed
          ? colors.errorContainer
          : active
          ? colors.primaryContainer
          : colors.surfaceContainerHigh,
    );
    final VoidCallback? onToggle =
        saving || connecting || state.status == PortForwardStatus.stopping
        ? null
        : state.active
        ? () => onStop(rule)
        : connected
        ? () => onStart(rule)
        : null;
    final toggleIcon = state.busy || connecting
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            state.active ? Icons.stop_rounded : Icons.play_arrow_rounded,
            size: 20,
          );
    if (layout?.asCard ?? MediaQuery.sizeOf(context).width >= 680) {
      return _desktopCard(
        context,
        editable: editable,
        status: statusBadge,
        onToggle: onToggle,
        toggleLabel: toggleLabel,
        toggleIcon: toggleIcon,
        browserUri: browserUri,
      );
    }
    return ExpressiveActionTile(
      title: rule.name,
      subtitle: hostLabel ?? rule.type.label,
      icon: _forwardIcon(rule.type),
      badges: [rule.type.label],
      slot: layout?.slot ?? HarborListSlot.single,
      asCard: layout?.asCard ?? false,
      onOpen: editable ? () => onEdit(rule) : null,
      menuLabel: '管理转发规则',
      onAction: (action) {
        if (action == 'browser') {
          if (browserUri case final uri?) _openInBrowser(context, uri);
          return;
        }
        if (!editable) return;
        if (action == 'edit') onEdit(rule);
        if (action == 'delete') onDelete(rule);
      },
      menuItems: [
        if (rule.type == PortForwardType.local)
          HarborPopupMenuItem(
            key: ValueKey('browser-forward-${rule.id}'),
            value: 'browser',
            enabled: browserUri != null,
            child: const Text('浏览器打开'),
          ),
        HarborPopupMenuItem(
          key: ValueKey('edit-forward-${rule.id}'),
          value: 'edit',
          enabled: editable,
          child: const Text('编辑规则'),
        ),
        HarborPopupMenuItem(
          key: ValueKey('delete-forward-${rule.id}'),
          value: 'delete',
          enabled: editable,
          child: const Text('删除规则'),
        ),
      ],
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: routeTip,
            child: Text(
              route,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (state.error case final error?) ...[
            const SizedBox(height: 10),
            _ForwardInlineAlert(message: error),
          ],
        ],
      ),
      extraBadges: [statusBadge],
      trailing: IconButton.filledTonal(
        key: ValueKey('toggle-forward-${rule.id}'),
        tooltip: toggleLabel,
        onPressed: onToggle,
        icon: toggleIcon,
      ),
    );
  }

  Widget _desktopCard(
    BuildContext context, {
    required bool editable,
    required Widget status,
    required VoidCallback? onToggle,
    required String toggleLabel,
    required Widget toggleIcon,
    required Uri? browserUri,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final type = theme.textTheme;
    final actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (rule.type == PortForwardType.local)
          IconButton(
            key: ValueKey('browser-forward-${rule.id}'),
            tooltip: '浏览器打开',
            onPressed: browserUri == null
                ? null
                : () => _openInBrowser(context, browserUri),
            icon: const Icon(Icons.open_in_browser_rounded, size: 20),
          ),
        IconButton(
          key: ValueKey('edit-forward-${rule.id}'),
          tooltip: '编辑规则',
          onPressed: editable ? () => onEdit(rule) : null,
          icon: const Icon(Icons.edit_outlined, size: 20),
        ),
        IconButton(
          key: ValueKey('delete-forward-${rule.id}'),
          tooltip: '删除规则',
          onPressed: editable ? () => onDelete(rule) : null,
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
        ),
        Tooltip(
          message: toggleLabel,
          child: FilledButton.tonalIcon(
            key: ValueKey('toggle-forward-${rule.id}'),
            onPressed: onToggle,
            icon: toggleIcon,
            label: Text(toggleLabel),
          ),
        ),
      ],
    );
    final kind = Tooltip(
      message: rule.description,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: ShapeDecoration(
          color: colors.secondaryContainer,
          shape: HarborShapes.pill,
        ),
        child: Text(
          rule.type.label,
          style: type.labelMedium?.copyWith(color: colors.onSecondaryContainer),
        ),
      ),
    );
    return _ForwardCardSurface(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 340 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExpressiveMark(size: 36, icon: _forwardIcon(rule.type)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Tooltip(
                            message: rule.name,
                            child: Text(
                              rule.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: type.titleMedium,
                            ),
                          ),
                          if (hostLabel != null) ...[
                            const SizedBox(height: 2),
                            Tooltip(
                              message: hostLabel!,
                              child: Text(
                                hostLabel!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: type.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                          if (compact) ...[const SizedBox(height: 6), status],
                        ],
                      ),
                    ),
                    if (!compact) ...[const SizedBox(width: 12), status],
                  ],
                ),
                const SizedBox(height: 18),
                _ForwardRoute(rule: rule, state: state, stacked: compact),
                if (state.error case final error?) ...[
                  const SizedBox(height: 12),
                  _ForwardInlineAlert(message: error),
                ],
                const SizedBox(height: 14),
                if (compact)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      kind,
                      const SizedBox(height: 8),
                      Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  )
                else
                  Row(children: [kind, const Spacer(), actions]),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Inline notice: the fill is a translucent wash of the same color as the bar.
class _ForwardInlineAlert extends StatelessWidget {
  const _ForwardInlineAlert({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.brightness == Brightness.dark
        ? const Color(0xFFB6B2DC)
        : const Color(0xFF585B86);
    return Material(
      key: const ValueKey('forward-inline-alert'),
      color: accent.withValues(alpha: 0.11),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 5,
            child: ColoredBox(color: accent),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selects independent desktop cards or the shared compact grouped list.
class _ForwardItemLayout extends InheritedWidget {
  const _ForwardItemLayout({
    required this.slot,
    required this.asCard,
    required super.child,
  });
  final HarborListSlot slot;
  final bool asCard;

  @override
  bool updateShouldNotify(_ForwardItemLayout oldWidget) =>
      slot != oldWidget.slot || asCard != oldWidget.asCard;
}

class _ForwardRoute extends StatelessWidget {
  const _ForwardRoute({
    required this.rule,
    required this.state,
    required this.stacked,
  });
  final PortForwardRule rule;
  final PortForwardState state;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final remote = rule.type == PortForwardType.remote;
    final dynamic = rule.type == PortForwardType.dynamic;
    final source = _endpoint(
      context,
      label: remote ? '服务器监听' : '本机监听',
      address: PortForwardRule.endpoint(
        rule.bindHost,
        state.port ?? rule.bindPort,
      ),
      tip: rule.bindPort == 0 && state.port == null ? '启动时自动分配监听端口' : null,
    );
    final target = _endpoint(
      context,
      label: dynamic
          ? '代理出口'
          : remote
          ? '本机目标'
          : '服务器目标',
      address: dynamic
          ? 'SOCKS5'
          : PortForwardRule.endpoint(rule.targetHost, rule.targetPort),
    );
    return stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [source, const SizedBox(height: 12), target],
          )
        : Row(
            children: [
              Expanded(child: source),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Expanded(child: target),
            ],
          );
  }

  Widget _endpoint(
    BuildContext context, {
    required String label,
    required String address,
    String? tip,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (tip != null) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: tip,
                child: Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        SelectableText(
          address,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

/// Desktop card surface; narrow layouts keep the shared connection list tile.
class _ForwardCardSurface extends StatefulWidget {
  const _ForwardCardSurface({required this.child});
  final Widget child;
  @override
  State<_ForwardCardSurface> createState() => _ForwardCardSurfaceState();
}

class _ForwardCardSurfaceState extends State<_ForwardCardSurface> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Material(
          color: _hovered
              ? colors.surfaceContainerHigh
              : colors.surfaceContainerLow,
          animationDuration: HarborMotion.effects(context),
          shape: RoundedRectangleBorder(
            borderRadius: HostCardShape.border,
            side: _focused
                ? BorderSide(color: colors.primary, width: 2)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: widget.child,
        ),
      ),
    );
  }
}

IconData _forwardIcon(PortForwardType type) => switch (type) {
  PortForwardType.local => Icons.arrow_outward_rounded,
  PortForwardType.remote => Icons.south_west_rounded,
  PortForwardType.dynamic => Icons.public_rounded,
};

class ForwardStatusBadge extends StatelessWidget {
  const ForwardStatusBadge({
    super.key,
    required this.label,
    required this.color,
    this.backgroundColor,
  });
  final String label;
  final Color color;
  final Color? backgroundColor;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: ShapeDecoration(
      color: backgroundColor ?? color.withValues(alpha: 0.1),
      shape: HarborShapes.pill,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _ForwardEmptyState extends StatelessWidget {
  const _ForwardEmptyState();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _node(context, Icons.laptop_rounded),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 16,
                color: colors.outline,
              ),
            ),
            _node(context, Icons.lock_outline_rounded, accent: true),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 16,
                color: colors.outline,
              ),
            ),
            _node(context, Icons.dns_outlined),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          '尚未添加转发规则',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ],
    );
  }

  Widget _node(BuildContext context, IconData icon, {bool accent = false}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent ? colors.primaryContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        icon,
        size: 24,
        color: accent ? colors.onPrimaryContainer : colors.onSurfaceVariant,
      ),
    );
  }
}

class PortForwardEditor extends StatefulWidget {
  const PortForwardEditor({
    super.key,
    this.rule,
    this.hosts = const [],
    this.initialHostId,
    this.onSaveForHost,
  });
  final PortForwardRule? rule;
  final List<Host> hosts;
  final String? initialHostId;
  final void Function(PortForwardRule rule, String hostId)? onSaveForHost;
  @override
  State<PortForwardEditor> createState() => _PortForwardEditorState();
}

class _PortForwardEditorState extends State<PortForwardEditor> {
  final _form = GlobalKey<FormState>();
  final _directionTip = GlobalKey<TooltipState>();
  final _bindPortTip = GlobalKey<TooltipState>();
  late String? _hostId =
      widget.hosts.where((h) => h.id == widget.initialHostId).firstOrNull?.id ??
      widget.hosts.firstOrNull?.id;
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late final _bindHost = TextEditingController(
    text: widget.rule?.bindHost ?? '127.0.0.1',
  );
  late final _bindPort = TextEditingController(
    text: widget.rule?.bindPort.toString() ?? '0',
  );
  late final _targetHost = TextEditingController(
    text: widget.rule?.targetHost ?? '127.0.0.1',
  );
  late final _targetPort = TextEditingController(
    text: widget.rule == null ? '' : widget.rule!.targetPort.toString(),
  );
  late PortForwardType _type = widget.rule?.type ?? PortForwardType.local;
  @override
  void dispose() {
    for (final controller in [
      _name,
      _bindHost,
      _bindPort,
      _targetHost,
      _targetPort,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _host(String? value, {bool bind = false}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty || RegExp(r'\s|/|\[|\]').hasMatch(text)) {
      return '填写主机名或 IP 地址（IPv6 不加方括号）';
    }
    if (bind &&
        _type == PortForwardType.dynamic &&
        !['127.0.0.1', '::1', 'localhost'].contains(text)) {
      return '无认证代理只允许本机回环地址';
    }
    return null;
  }

  String? _port(String? value, {bool bind = false}) {
    final port = int.tryParse(value?.trim() ?? '');
    return port == null || port < (bind ? 0 : 1) || port > 65535
        ? bind
              ? '输入 0–65535'
              : '输入 1–65535'
        : null;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final result = PortForwardRule(
      id: widget.rule?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim(),
      type: _type,
      bindHost: _bindHost.text.trim(),
      bindPort: int.parse(_bindPort.text.trim()),
      targetHost: _targetHost.text.trim(),
      targetPort: _type == PortForwardType.dynamic
          ? 0
          : int.parse(_targetPort.text.trim()),
    );
    if (widget.onSaveForHost != null) {
      if (_hostId != null) widget.onSaveForHost!(result, _hostId!);
    } else {
      Navigator.pop(context, result);
    }
  }

  Widget _selection<T>({
    required Key key,
    required String label,
    required T? value,
    required Map<T, String> options,
    required ValueChanged<T> onSelected,
    FormFieldValidator<T>? validator,
    Widget? leadingIcon,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => DropdownMenuFormField<T>(
        key: key,
        initialSelection: value,
        width: constraints.maxWidth,
        menuHeight: 320,
        selectOnly: true,
        requestFocusOnTap: true,
        enableSearch: false,
        textStyle: theme.textTheme.bodyLarge,
        inputDecorationTheme: theme.inputDecorationTheme,
        label: Text(label),
        leadingIcon: leadingIcon,
        trailingIcon: const Icon(Icons.expand_more_rounded),
        selectedTrailingIcon: const Icon(Icons.expand_less_rounded),
        alignmentOffset: const Offset(0, 4),
        dropdownMenuEntries: [
          for (final entry in options.entries)
            DropdownMenuEntry<T>(
              value: entry.key,
              label: entry.value,
              trailingIcon: entry.key == value
                  ? const Icon(Icons.check_rounded, size: 20)
                  : null,
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: HarborShapes.superellipse(
                  const BorderRadius.all(HarborShapes.sm),
                ),
                backgroundColor: entry.key == value
                    ? colors.secondaryContainer
                    : null,
                foregroundColor: entry.key == value
                    ? colors.onSecondaryContainer
                    : colors.onSurface,
                textStyle: theme.textTheme.bodyLarge,
              ),
            ),
        ],
        onSelected: (next) {
          if (next != null) onSelected(next);
        },
        validator: validator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: Text(widget.rule == null ? '添加转发规则' : '编辑转发规则'),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const ValueKey('forward-name'),
                controller: _name,
                autofocus: widget.hosts.isEmpty,
                decoration: const InputDecoration(labelText: '规则名称'),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请填写规则名称' : null,
              ),
              const SizedBox(height: 16),
              if (widget.hosts.isNotEmpty) ...[
                _selection<String>(
                  key: const ValueKey('forward-host'),
                  value: _hostId,
                  label: 'SSH 主机',
                  leadingIcon: const Icon(Icons.dns_outlined),
                  options: {
                    for (final host in widget.hosts) host.id: host.name,
                  },
                  onSelected: (value) => setState(() => _hostId = value),
                  validator: (value) => value == null ? '请选择 SSH 主机' : null,
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Expanded(
                    child: _selection<PortForwardType>(
                      key: const ValueKey('forward-type'),
                      value: _type,
                      label: '转发类型',
                      options: {
                        for (final type in PortForwardType.values)
                          type: type.label,
                      },
                      onSelected: (value) => setState(() => _type = value),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    key: _directionTip,
                    message: switch (_type) {
                      PortForwardType.remote => '服务器监听 → 本机侧目标',
                      PortForwardType.local => '本机监听 → 服务器侧目标',
                      PortForwardType.dynamic => '本机 SOCKS5 → 经服务器访问目标',
                    },
                    child: IconButton(
                      key: const ValueKey('forward-direction-tip'),
                      onPressed: () =>
                          _directionTip.currentState?.ensureTooltipVisible(),
                      icon: const Icon(Icons.info_outline_rounded, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('forward-bind-host'),
                controller: _bindHost,
                decoration: InputDecoration(
                  labelText: _type == PortForwardType.remote
                      ? '服务器监听地址'
                      : '本机监听地址',
                ),
                validator: (value) => _host(value, bind: true),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('forward-bind-port'),
                      controller: _bindPort,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '监听端口'),
                      validator: (value) => _port(value, bind: true),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    key: _bindPortTip,
                    message: '0 表示自动分配端口',
                    child: IconButton(
                      key: const ValueKey('forward-bind-port-tip'),
                      onPressed: () =>
                          _bindPortTip.currentState?.ensureTooltipVisible(),
                      icon: const Icon(Icons.info_outline_rounded, size: 20),
                    ),
                  ),
                ],
              ),
              if (_type != PortForwardType.dynamic) ...[
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('forward-target-host'),
                  controller: _targetHost,
                  decoration: InputDecoration(
                    labelText: _type == PortForwardType.remote
                        ? '本机侧目标地址'
                        : '服务器侧目标地址',
                  ),
                  validator: _host,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('forward-target-port'),
                  controller: _targetPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '目标端口'),
                  validator: _port,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存规则')),
    ],
  );
}
