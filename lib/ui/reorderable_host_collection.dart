import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:reorderable_grid/reorderable_grid.dart';

import '../domain/host.dart';
import 'expressive_widgets.dart';
import 'theme.dart';

/// Builds one host card for a reorder collection.
///
/// [menu] is non-null exactly while the collection owns the long press — that
/// is, while reordering is enabled. The card must then leave
/// `InkWell.onLongPress` to the collection, which opens the very same menu
/// through that controller when a long press never moved.
typedef HostCardBuilder = Widget Function(
  BuildContext context,
  int index,
  HostCardMenuController? menu,
);

/// Host collection that reorders by long-press drag.
///
/// Cards stay pure visuals: this widget owns the delayed drag recognizer, the
/// slot the neighbours open while dragging, the long-press menu hand-off and
/// the rollback rules. Neighbours slide into the source slot while the dragged
/// card follows the pointer, and the target slot stays empty until the drop,
/// which is the slot the card then lands in.
///
/// Every cell gets the same height, measured from the tallest card so no tag is
/// ever clipped. A narrow width leaves a single column, so a phone running
/// large text keeps the room its labels need.
///
/// It is a sliver — put it in a [CustomScrollView].
class ReorderableHostGridSliver extends StatefulWidget {
  const ReorderableHostGridSliver({
    super.key,
    required this.hosts,
    required this.cardBuilder,
    required this.onReorder,
    required this.width,
    this.enabled = true,
    this.gap = 8,
    this.minCardHeight = 112,
    this.columnWidth = 380,
  });

  /// Visible hosts, in grid order.
  final List<Host> hosts;
  final HostCardBuilder cardBuilder;

  /// Called once per drop with the dragged host and the host whose slot it
  /// takes. Never called for a long press that did not move.
  final void Function(Host source, Host target) onReorder;

  /// Cross-axis space the grid may use, page insets already removed.
  final double width;

  /// False while the order cannot change (loading, saving): no drag may start
  /// and the cards keep their own long-press menu.
  final bool enabled;

  /// Space between two cells, both axes.
  final double gap;

  /// Shortest a cell may be, so a card keeps the usual card size.
  final double minCardHeight;

  /// Widest a column may get before the grid adds another one.
  final double columnWidth;

  @override
  State<ReorderableHostGridSliver> createState() =>
      _ReorderableHostGridSliverState();
}

class _ReorderableHostGridSliverState extends State<ReorderableHostGridSliver>
    with _HostReorderMixin {
  final _sliver = GlobalKey<SliverReorderableGridState>();

  @override
  List<Host> get hosts => widget.hosts;

  @override
  bool get reorderEnabled => widget.enabled;

  @override
  void Function(Host source, Host target) get onReorderHosts =>
      widget.onReorder;

  @override
  HostCardBuilder get cardBuilder => widget.cardBuilder;

  @override
  void cancelReorder() => _sliver.currentState?.cancelReorder();

  @override
  Widget build(BuildContext context) {
    final columns = (widget.width / (widget.columnWidth + widget.gap)).ceil();
    final count = columns < 1 ? 1 : columns;
    final cardWidth = (widget.width - widget.gap * (count - 1)) / count;
    return SliverReorderableGrid(
      key: _sliver,
      itemCount: widget.hosts.length,
      // The grid reports the slot the dragged card ends up in, which is the
      // index the model moves it to.
      onReorder: commitDrop,
      onReorderStart: onDragStart,
      proxyDecorator: reorderProxyDecorator,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        crossAxisSpacing: widget.gap,
        mainAxisSpacing: widget.gap,
        // As tall as the tallest card needs, so one card's tags are never cut
        // off and a short card does not leave its row uneven.
        mainAxisExtent: hostCardGridExtent(
          context,
          width: cardWidth,
          hosts: widget.hosts,
          minHeight: widget.minCardHeight,
        ),
      ),
      itemBuilder: (context, index) => KeyedSubtree(
        key: keyFor(index),
        child: draggableCard(context, index),
      ),
    );
  }
}

/// Single-column host list with natural card heights and animated drop gaps.
class ReorderableHostSliver extends StatefulWidget {
  const ReorderableHostSliver({
    super.key,
    required this.hosts,
    required this.cardBuilder,
    required this.onReorder,
    this.enabled = true,
    this.gap = HarborShapes.listGap,
  });

  final List<Host> hosts;
  final HostCardBuilder cardBuilder;
  final void Function(Host source, Host target) onReorder;
  final bool enabled;
  final double gap;

  @override
  State<ReorderableHostSliver> createState() => _ReorderableHostSliverState();
}

class _ReorderableHostSliverState extends State<ReorderableHostSliver>
    with _HostReorderMixin {
  final _sliver = GlobalKey<SliverReorderableListState>();

  @override
  List<Host> get hosts => widget.hosts;
  @override
  bool get reorderEnabled => widget.enabled;
  @override
  void Function(Host source, Host target) get onReorderHosts =>
      widget.onReorder;
  @override
  HostCardBuilder get cardBuilder => widget.cardBuilder;
  @override
  void cancelReorder() => _sliver.currentState?.cancelReorder();

  @override
  Widget draggableCard(BuildContext context, int index) => _ListDragListener(
    index: index,
    enabled: reorderEnabled,
    observer: _observer,
    child: cardBuilder(
      context,
      index,
      reorderEnabled ? _menuOf(hosts[index].id) : null,
    ),
  );

  @override
  Widget build(BuildContext context) => SliverReorderableList(
    key: _sliver,
    itemCount: hosts.length,
    onReorderStart: onDragStart,
    onReorderItem: commitDrop,
    proxyDecorator: reorderProxyDecorator,
    itemBuilder: (context, index) => Padding(
      key: keyFor(index),
      padding: EdgeInsets.only(bottom: widget.gap),
      child: draggableCard(context, index),
    ),
  );
}

/// What every reorder collection needs: it snapshots the visible hosts for the
/// duration of one drag, decides whether a release is a drop or a long press,
/// and keeps one menu controller per card.
mixin _HostReorderMixin<W extends StatefulWidget> on State<W> {
  final Map<String, HostCardMenuController> _menus = {};
  late final _DragObserver _observer = _DragObserver(
    onMove: _trackDrag,
    onRelease: _releaseDrag,
    onCancel: endDrag,
  );
  _DragSession? _session;
  ScrollableState? _scrollable;

  List<Host> get hosts;
  bool get reorderEnabled;
  void Function(Host source, Host target) get onReorderHosts;
  HostCardBuilder get cardBuilder;

  /// Asks the reorderable sliver to drop the drag in progress without saving.
  void cancelReorder();

  /// Stable identity of the item at [index], so rebuilds and tests can follow a
  /// host across a reorder.
  Key keyFor(int index) => ValueKey('host-${hosts[index].id}');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollable = Scrollable.maybeOf(context);
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    final session = _session;
    if (session != null) {
      // Filtering, saving rollbacks and bulk edits renumber the visible list;
      // the indices this drag captured would then point at other hosts.
      if (!reorderEnabled || !_sameHosts(session.hosts, hosts)) {
        cancelReorder();
        _session = null;
      }
      return;
    }
    _menus.removeWhere((id, _) => !hosts.any((host) => host.id == id));
  }

  bool _sameHosts(List<Host> a, List<Host> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  HostCardMenuController _menuOf(String hostId) =>
      _menus.putIfAbsent(hostId, HostCardMenuController.new);

  /// The card at [index] with its drag listener and menu handle.
  Widget draggableCard(BuildContext context, int index) => _GridDragListener(
    index: index,
    enabled: reorderEnabled,
    observer: _observer,
    child: cardBuilder(
      context,
      index,
      reorderEnabled ? _menuOf(hosts[index].id) : null,
    ),
  );

  /// Called by the reorderable sliver as the drag begins.
  void onDragStart(int index) {
    _session = index >= 0 && index < hosts.length
        ? _DragSession(List.of(hosts), hosts[index].id)
        : null;
  }

  void _trackDrag(Offset position, Offset delta) {
    final session = _session;
    if (session == null) return;
    session.position = position;
    session.travel += delta.distance;
  }

  /// Decides what a release means: a long press that never moved reopens the
  /// card's own menu, a release outside the list is dropped, and anything else
  /// is a drop the reorderable sliver commits and reports through [commitDrop].
  bool _releaseDrag() {
    final session = _session;
    if (session == null) return true;
    if (session.travel <= kTouchSlop) {
      final menu = _menuOf(session.sourceId);
      final at = session.position;
      _session = null;
      // The sliver puts the card back first, then the card shows its menu.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) menu.show(at);
      });
      return false;
    }
    if (_outsideList(session.position)) {
      _session = null;
      return false;
    }
    return true;
  }

  /// A release outside the list the hosts are shown in is not a drop.
  bool _outsideList(Offset position) {
    final box = _scrollable?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || position == Offset.zero) {
      return false;
    }
    return !(box.localToGlobal(Offset.zero) & box.size).contains(position);
  }

  /// Commits the drop of the card at [oldIndex] onto [newIndex] of the list the
  /// drag started from, once.
  void commitDrop(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final session = _session;
    final snapshot = session?.hosts;
    if (snapshot == null) return;
    if (oldIndex < 0 || oldIndex >= snapshot.length) return;
    if (newIndex < 0 || newIndex >= snapshot.length) return;
    final source = snapshot[oldIndex];
    final target = snapshot[newIndex];
    _session = null;
    if (source.id == target.id || source.id != session!.sourceId) return;
    onReorderHosts(source, target);
  }

  /// Forgets the drag in progress; the visible order stays untouched.
  void endDrag() => _session = null;

  /// Plain floating copy of a card: the card's own outline under a plain
  /// Material shadow, following the pointer from where it was grabbed.
  Widget reorderProxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) => Material(
    color: Colors.transparent,
    elevation: 6,
    shadowColor: Theme.of(context).colorScheme.shadow,
    shape: const RoundedRectangleBorder(borderRadius: HostCardShape.border),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// One long-press drag: the hosts it started from and where the pointer is.
class _DragSession {
  _DragSession(this.hosts, this.sourceId);

  /// Visible hosts when the drag started. The indices reported on drop refer to
  /// this list, whatever rebuilds happen while the finger is down.
  final List<Host> hosts;
  final String sourceId;
  Offset position = Offset.zero;
  double travel = 0;
}

class _GridDragListener extends ReorderableGridDelayedDragStartListener {
  const _GridDragListener({
    required super.index,
    required super.enabled,
    required this.observer,
    required super.child,
  });

  final _DragObserver observer;

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      _HostDragRecognizer(observer: observer, debugOwner: this);
}

class _ListDragListener extends ReorderableDelayedDragStartListener {
  const _ListDragListener({
    required super.index,
    required super.enabled,
    required this.observer,
    required super.child,
  });

  final _DragObserver observer;

  @override
  MultiDragGestureRecognizer createRecognizer() =>
      _HostDragRecognizer(observer: observer, debugOwner: this);
}

/// Long-press recognizer that lets the collection watch the drag the
/// reorderable grid starts from it.
///
/// The grid takes ownership of the [Drag] the recognizer returns from
/// `onStart` and only reports the end of a drop, never a cancellation; the only
/// place to see both is the drag itself. The grid sets `onStart` just before
/// adding the pointer and reads it back when the long press is accepted, so
/// swapping it here wraps exactly that drag.
class _HostDragRecognizer extends DelayedMultiDragGestureRecognizer {
  _HostDragRecognizer({required this.observer, super.debugOwner});

  final _DragObserver observer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // The default button filter stays: only the primary button starts a
    // reorder, so the right-click menu stays with the card.
    final start = onStart;
    if (start != null) {
      onStart = (position) {
        final drag = start(position);
        if (drag != null) observer.onMove(position, Offset.zero);
        return drag == null ? null : _ObservedDrag(drag, observer);
      };
    }
    super.addAllowedPointer(event);
  }
}

/// What the collection wants to know about a drag it does not own.
class _DragObserver {
  _DragObserver({
    required this.onMove,
    required this.onRelease,
    required this.onCancel,
  });

  final void Function(Offset position, Offset delta) onMove;

  /// Whether the release should be committed; false rolls the drag back.
  final bool Function() onRelease;

  /// The drag is over without a drop.
  final VoidCallback onCancel;
}

class _ObservedDrag extends Drag {
  _ObservedDrag(this._inner, this._observer);

  final Drag _inner;
  final _DragObserver _observer;

  @override
  void update(DragUpdateDetails details) {
    _observer.onMove(details.globalPosition, details.delta);
    _inner.update(details);
  }

  @override
  void end(DragEndDetails details) {
    if (_observer.onRelease()) {
      _inner.end(details);
      return;
    }
    // Roll back through cancel: ending after the grid already reset the drag
    // would animate a disposed proxy. This is also how a release outside the
    // list and a long press that never moved stay out of the model.
    _observer.onCancel();
    _inner.cancel();
  }

  @override
  void cancel() {
    _observer.onCancel();
    _inner.cancel();
  }
}
