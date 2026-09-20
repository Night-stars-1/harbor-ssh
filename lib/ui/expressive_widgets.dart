import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../domain/host.dart';
import 'theme.dart';

class ExpressiveMark extends StatelessWidget {
  const ExpressiveMark({
    super.key,
    this.size = 56,
    this.icon = Icons.terminal_rounded,
    this.color,
    this.foreground,
    this.flower = false,
  });
  final double size;
  final IconData icon;
  final Color? color, foreground;
  final bool flower;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fill = color ?? colors.primaryContainer;
    final glyph = foreground ?? colors.onPrimaryContainer;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (flower)
            DecoratedBox(
              decoration: ShapeDecoration(
                color: fill,
                shape: StarBorder(
                  points: 8,
                  innerRadiusRatio: 0.72,
                  pointRounding: 0.48,
                  valleyRounding: 0.48,
                  rotation: 22.5,
                ),
              ),
              child: const SizedBox.expand(),
            )
          else
            DecoratedBox(
              decoration: ShapeDecoration(
                color: fill,
                shape: HarborShapes.superellipse(
                  BorderRadius.circular(size * 0.32),
                ),
              ),
              child: const SizedBox.expand(),
            ),
          Icon(icon, size: size * 0.44, color: glyph),
        ],
      ),
    );
  }
}

class ExpressiveHostCard extends StatelessWidget {
  const ExpressiveHostCard({
    super.key,
    required this.host,
    required this.onConnect,
    required this.onFavorite,
    required this.onAction,
    this.slot = HarborListSlot.single,
    this.asCard = false,
  });
  final Host host;
  final VoidCallback onConnect;
  final VoidCallback? onFavorite;
  final ValueChanged<String> onAction;
  final HarborListSlot slot;
  final bool asCard;

  @override
  Widget build(BuildContext context) => _ConnectionTile(
    title: host.name,
    subtitle: host.destination,
    badge: host.group.isEmpty ? '未分组' : host.group,
    favorite: host.favorite,
    icon: Icons.dns_rounded,
    actionLabel: '连接',
    menuLabel: '管理连接',
    showMenuButton: false,
    slot: slot,
    asCard: asCard,
    onTap: onConnect,
    onAction: (action) {
      if (action == 'favorite') {
        onFavorite?.call();
      } else {
        onAction(action);
      }
    },
    menuItems: [
      PopupMenuItem(
        value: 'favorite',
        enabled: onFavorite != null,
        child: Text(host.favorite ? '取消收藏' : '收藏'),
      ),
      const PopupMenuItem(value: 'edit', child: Text('编辑连接')),
      const PopupMenuItem(value: 'forget', child: Text('重置主机指纹')),
      const PopupMenuItem(value: 'delete', child: Text('删除连接')),
    ],
  );
}

class ExpressiveUserCard extends StatelessWidget {
  const ExpressiveUserCard({
    super.key,
    required this.user,
    required this.onOpen,
    required this.onAction,
    this.slot = HarborListSlot.single,
    this.asCard = false,
  });
  final SshUser user;
  final VoidCallback onOpen;
  final ValueChanged<String> onAction;
  final HarborListSlot slot;
  final bool asCard;

  @override
  Widget build(BuildContext context) => _ConnectionTile(
    title: user.name,
    subtitle: user.publicKey.isEmpty
        ? 'SSH 密钥'
        : user.publicKey.split(' ').first,
    badge: user.authMethod == AuthMethod.password ? '旧版凭证' : '私钥 / 公钥',
    icon: Icons.vpn_key_rounded,
    actionLabel: '编辑',
    menuLabel: '管理凭证',
    slot: slot,
    asCard: asCard,
    onTap: onOpen,
    onAction: onAction,
    menuItems: const [
      PopupMenuItem(value: 'edit', child: Text('编辑凭证')),
      PopupMenuItem(value: 'delete', child: Text('删除凭证')),
    ],
  );
}

class _ConnectionTile extends StatefulWidget {
  const _ConnectionTile({
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.icon,
    required this.actionLabel,
    required this.menuLabel,
    required this.onTap,
    required this.onAction,
    required this.menuItems,
    required this.slot,
    required this.asCard,
    this.favorite = false,
    this.showMenuButton = true,
  });
  final String title, subtitle, badge, actionLabel, menuLabel;
  final IconData icon;
  final bool favorite, asCard, showMenuButton;
  final HarborListSlot slot;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;
  final List<PopupMenuEntry<String>> menuItems;
  @override
  State<_ConnectionTile> createState() => _ConnectionTileState();
}

class _ConnectionTileState extends State<_ConnectionTile>
    with SingleTickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);
  final _focus = FocusNode();
  bool _hovered = false, _focused = false, _pressed = false, _menuOpen = false;
  Offset? _pressPosition;

  @override
  void dispose() {
    _scale.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _scale.stop();
      _scale.value = 1;
    }
  }

  void _highlight(bool value) {
    setState(() => _pressed = value);
    if (MediaQuery.disableAnimationsOf(context)) return;
    _scale.animateWith(
      SpringSimulation(
        HarborMotion.spatial,
        _scale.value,
        value ? 0.985 : 1,
        _scale.velocity,
      ),
    );
  }

  Future<void> _openMenu([Offset? position]) async {
    if (_menuOpen) return;
    _menuOpen = true;
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final anchor = overlay.globalToLocal(
      position ?? box.localToGlobal(Offset(box.size.width - 48, 48)),
    );
    try {
      final action = await showMenu<String>(
        context: context,
        semanticLabel: widget.menuLabel,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
          Offset.zero & overlay.size,
        ),
        items: widget.menuItems,
      );
      if (!mounted) return;
      _focus.requestFocus();
      if (action != null) widget.onAction(action);
    } finally {
      _menuOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final radius = widget.asCard
        ? BorderRadius.circular(_pressed ? 16 : 20)
        : HarborShapes.listItem(widget.slot);
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: _focused
          ? BorderSide(color: colors.primary, width: 2)
          : BorderSide.none,
    );
    final mark = ExpressiveMark(
      size: 36,
      icon: widget.icon,
      flower: widget.favorite,
      color: widget.favorite
          ? colors.tertiaryContainer
          : colors.primaryContainer,
      foreground: widget.favorite
          ? colors.onTertiaryContainer
          : colors.onPrimaryContainer,
    );
    final menu = IconButton(
      tooltip: '${widget.menuLabel}：${widget.title}',
      onPressed: _openMenu,
      icon: const Icon(Icons.more_horiz_rounded),
    );
    final title = Row(
      children: [
        Expanded(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.titleMedium,
          ),
        ),
        if (widget.favorite) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.star_rounded,
            size: 18,
            color: colors.tertiary,
            semanticLabel: '已收藏',
          ),
        ],
      ],
    );
    final subtitle = Text(
      widget.subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: type.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
    );
    final content = Padding(
      padding: EdgeInsets.fromLTRB(14, 10, widget.showMenuButton ? 6 : 14, 10),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 2),
                subtitle,
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: ShapeDecoration(
                    color: colors.secondaryContainer,
                    shape: HarborShapes.pill,
                  ),
                  child: Text(
                    widget.badge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.labelMedium?.copyWith(
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.showMenuButton) menu,
        ],
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f10, shift: true): _openMenu,
        const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
      },
      child: Semantics(
        button: true,
        hint: '${widget.actionLabel} ${widget.title}',
        child: AnimatedBuilder(
          animation: _scale,
          child: Material(
            color: _hovered
                ? colors.surfaceContainerHigh
                : colors.surfaceContainerLow,
            animationDuration: HarborMotion.effects(context),
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              focusNode: _focus,
              customBorder: shape,
              onTap: widget.onTap,
              onTapDown: (details) => _pressPosition = details.globalPosition,
              onSecondaryTapUp: (details) => _openMenu(details.globalPosition),
              onLongPress: () => _openMenu(_pressPosition),
              onHover: (value) => setState(() => _hovered = value),
              onFocusChange: (value) => setState(() => _focused = value),
              onHighlightChanged: _highlight,
              child: content,
            ),
          ),
          builder: (context, child) => Transform.scale(
            scale: _scale.value.clamp(0.96, 1.02),
            child: child,
          ),
        ),
      ),
    );
  }
}
