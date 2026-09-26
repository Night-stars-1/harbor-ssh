import 'dart:math';

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

List<String> _hostBadges(Host host) =>
    host.tags.isEmpty ? const ['未分组'] : host.tags;

class ExpressiveHostCard extends StatelessWidget {
  const ExpressiveHostCard({
    super.key,
    required this.host,
    required this.onConnect,
    required this.onFavorite,
    required this.onAction,
    this.slot = HarborListSlot.single,
    this.asCard = false,
    this.hideAddress = false,
    this.menuController,
  });
  final Host host;
  final VoidCallback onConnect;
  final VoidCallback? onFavorite;
  final ValueChanged<String> onAction;
  final HarborListSlot slot;
  final bool asCard;

  /// Handle an outer gesture owner — the reorder宿主 — uses to open this
  /// card's menu. While one is attached the card leaves long press to that
  /// owner, so its delayed drag recognizer is never raced by the InkWell.
  final HostCardMenuController? menuController;

  /// Masks the rendered address (never the stored [Host]) so the list can be
  /// shown over a shoulder. [Host.username] and [Host.port] stay readable.
  final bool hideAddress;

  static const _addressMask = '••••••';

  @override
  Widget build(BuildContext context) => _ConnectionTile(
    title: host.name,
    subtitle: hideAddress
        ? '${host.username}@$_addressMask:${host.port}'
        : host.destination,
    badges: _hostBadges(host),
    favorite: host.favorite,
    icon: Icons.dns_rounded,
    actionLabel: '连接',
    menuLabel: '管理连接',
    showMenuButton: false,
    slot: slot,
    asCard: asCard,
    menuController: menuController,
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
    badges: [user.authMethod == AuthMethod.password ? '旧版凭证' : '私钥 / 公钥'],
    icon: Icons.vpn_key_rounded,
    actionLabel: '编辑',
    menuLabel: '管理凭证',
    slot: slot,
    asCard: asCard,
    onTap: onOpen,
    onAction: onAction,
    menuItems: [
      // 旧版密码凭证没有可引用的私钥，无法据此新建连接。
      if (user.authMethod == AuthMethod.privateKey)
        const PopupMenuItem(value: 'createHost', child: Text('用此凭证新建连接')),
      const PopupMenuItem(value: 'edit', child: Text('编辑凭证')),
      const PopupMenuItem(value: 'delete', child: Text('删除凭证')),
    ],
  );
}

/// Card surface geometry, shared by [ExpressiveHostCard], the grid height
/// measurement and the reorder drag proxy, so all three agree on the outline.
abstract final class HostCardShape {
  static const double radius = 20;
  static const double pressedRadius = 16;
  static const BorderRadius border = BorderRadius.all(Radius.circular(radius));
}

/// Handle on a card's overflow menu.
///
/// A reorder宿主 owns the long press of the cards it arranges, so it needs a
/// way to open the menu that long press used to open. The card keeps building
/// the items itself — the owner only asks it to show them — so the menu never
/// gets duplicated.
class HostCardMenuController {
  _ConnectionTileState? _tile;

  /// Opens the attached card's menu, anchored at [position] in global
  /// coordinates (the card picks its own anchor when null).
  void show([Offset? position]) => _tile?._openMenu(position);

  void _attach(_ConnectionTileState tile) => _tile = tile;

  void _detach(_ConnectionTileState tile) {
    if (identical(_tile, tile)) _tile = null;
  }
}

/// Metrics of a card's content.
///
/// The card's build and [hostCardGridExtent] both read them, so a grid cell
/// reserves exactly the room the card then asks for.
const _cardMarkSize = 36.0;
const _cardMarkGap = 10.0;
const _cardTitleGap = 2.0;
const _cardStarSize = 18.0;
const _cardPadding = EdgeInsets.fromLTRB(14, 10, 14, 10);
const _cardCompactPadding = 6.0;
const _tagPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 2);
const _tagSpacing = 6.0;
const _tagRunSpacing = 4.0;
const _tagTopPadding = 4.0;

/// Height a grid cell must reserve so no host card clips its content.
///
/// A grid hands every cell the same extent, so one card being a line taller
/// than another would otherwise be cut off. This measures the real card
/// content for [width]: theme fonts at the ambient text scale, one line of
/// title and destination, and the tag chips wrapped into as many runs as they
/// need. [minHeight] keeps short cards on the usual card size.
///
/// It is pure geometry over the given hosts, so callers run it while building
/// the sliver — never while a pointer moves.
double hostCardGridExtent(
  BuildContext context, {
  required double width,
  required Iterable<Host> hosts,
  double minHeight = 112,
}) {
  final type = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  // Text merges the ambient default under its own style, so measure the same
  // way; that keeps the reserved height identical to what the card renders.
  final ambient = DefaultTextStyle.of(context).style;
  final title = ambient.merge(type.titleMedium);
  final body = ambient.merge(type.bodyMedium);
  final label = ambient.merge(type.labelMedium);
  final textWidth =
      width - _cardPadding.horizontal - _cardMarkSize - _cardMarkGap;
  var extent = minHeight;
  for (final host in hosts) {
    final content =
        max(
          _lineSize(host.name, title, scaler).height,
          host.favorite ? _cardStarSize : 0,
        ) +
        _cardTitleGap +
        _lineSize(host.destination, body, scaler).height +
        _tagRunsHeight(_hostBadges(host), label, scaler, textWidth);
    final height = _cardPadding.vertical + max(_cardMarkSize, content);
    if (height > extent) extent = height;
  }
  // Round up: a sub-pixel line height must never clip the last tag.
  return extent.ceilToDouble();
}

/// Size of [text] laid out on a single line, unconstrained so a long label
/// reports the width a chip would need before any ellipsis.
Size _lineSize(String text, TextStyle? style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textScaler: scaler,
    textDirection: TextDirection.ltr,
  )..layout();
  final size = Size(painter.width, painter.height);
  painter.dispose();
  return size;
}

/// Height of the tag [Wrap] for [labels], mirroring its greedy run layout with
/// the same spacing, run spacing and chip padding.
double _tagRunsHeight(
  List<String> labels,
  TextStyle? style,
  TextScaler scaler,
  double width,
) {
  if (labels.isEmpty) return 0;
  var rows = 0, used = 0.0, rowHeight = 0.0;
  for (final label in labels) {
    final size = _lineSize(label, style, scaler);
    final chip = size.width + _tagPadding.horizontal;
    rowHeight = max(rowHeight, size.height + _tagPadding.vertical);
    if (rows == 0) {
      rows = 1;
      used = chip;
    } else if (used + _tagSpacing + chip <= width) {
      used += _tagSpacing + chip;
    } else {
      rows++;
      used = chip;
    }
  }
  return _tagTopPadding + rows * rowHeight + (rows - 1) * _tagRunSpacing;
}

class _ConnectionTile extends StatefulWidget {
  const _ConnectionTile({
    required this.title,
    required this.subtitle,
    required this.badges,
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
    this.menuController,
  });
  final String title, subtitle, actionLabel, menuLabel;
  final List<String> badges;
  final IconData icon;
  final bool favorite, asCard, showMenuButton;
  final HarborListSlot slot;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;
  final List<PopupMenuEntry<String>> menuItems;

  /// Owner of this tile's long press. While set, the tile never opens its menu
  /// itself — the owner asks for it through the controller — so a delayed drag
  /// recognizer outside the tile is not raced by the InkWell.
  final HostCardMenuController? menuController;
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
  void initState() {
    super.initState();
    widget.menuController?._attach(this);
  }

  @override
  void dispose() {
    widget.menuController?._detach(this);
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

  @override
  void didUpdateWidget(covariant _ConnectionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.menuController != widget.menuController) {
      oldWidget.menuController?._detach(this);
      widget.menuController?._attach(this);
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
        ? BorderRadius.circular(
            _pressed ? HostCardShape.pressedRadius : HostCardShape.radius,
          )
        : HarborShapes.listItem(widget.slot);
    final mark = ExpressiveMark(
      size: _cardMarkSize,
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
            size: _cardStarSize,
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
    final badges = widget.badges.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: _tagTopPadding),
            child: Wrap(
              spacing: _tagSpacing,
              runSpacing: _tagRunSpacing,
              children: [
                for (final label in widget.badges)
                  Container(
                    padding: _tagPadding,
                    decoration: ShapeDecoration(
                      color: colors.secondaryContainer,
                      shape: HarborShapes.pill,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.labelMedium?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          );
    final content = Padding(
      // Matches [_cardPadding]: the grid measurement reserves the room this
      // padding asks for.
      padding: EdgeInsets.fromLTRB(
        _cardPadding.left,
        _cardPadding.top,
        widget.showMenuButton ? _cardCompactPadding : _cardPadding.right,
        _cardPadding.bottom,
      ),
      child: Row(
        children: [
          mark,
          const SizedBox(width: _cardMarkGap),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: _cardTitleGap),
                subtitle,
                ?badges,
              ],
            ),
          ),
          if (widget.showMenuButton) menu,
        ],
      ),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: _focused
          ? BorderSide(color: colors.primary, width: 2)
          : BorderSide.none,
    );
    final bindings = {
      const SingleActivator(LogicalKeyboardKey.f10, shift: true): _openMenu,
      const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
    };
    return CallbackShortcuts(
      bindings: bindings,
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
              // A tile whose long press belongs to an outer reorder owner only
              // responds to the menu request that owner sends when a press
              // never moved.
              onLongPress: widget.menuController == null
                  ? () => _openMenu(_pressPosition)
                  : null,
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
