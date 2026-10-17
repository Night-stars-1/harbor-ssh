import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../data/ssh_connection.dart';
import '../domain/host.dart';
import '../domain/remote_file.dart';
import 'expressive_widgets.dart';
import 'file_workspace_model.dart';
import 'remote_text_editor_dialog.dart';
import 'theme.dart';

class FileWorkspace extends StatefulWidget {
  const FileWorkspace({
    super.key,
    required this.model,
    required this.hosts,
    required this.sessions,
    required this.onConnect,
    this.showTitle = false,
    this.initializeLocal = true,
    this.onSetBookmark,
    this.localBookmarks = const [],
    this.onSetLocalBookmark,
    this.sameLocalPath = _samePath,
    this.acceptExternalDrops = true,
  });
  final FileWorkspaceModel model;
  final List<Host> hosts;
  final List<SshConnection> sessions;
  final Future<SshConnection?> Function(Host) onConnect;
  final bool showTitle;
  final bool initializeLocal;

  /// Disabled while the files page is kept mounted behind another page.
  final bool acceptExternalDrops;

  /// 设置单个 SFTP 目录的书签状态；为空时不显示书签按钮。
  final Future<void> Function(
    String hostId,
    String path, {
    required bool saved,
  })?
  onSetBookmark;

  /// 本机文件夹书签；只保存在本机，与主机的 SFTP 书签分开。
  final List<String> localBookmarks;

  /// 设置单个本地目录的书签状态；为空时本地标签页不显示书签按钮。
  final Future<void> Function(String path, {required bool saved})?
  onSetLocalBookmark;

  /// 本地路径比较；Windows 上应忽略大小写。
  final bool Function(String a, String b) sameLocalPath;
  static bool _samePath(String a, String b) => a == b;
  @override
  State<FileWorkspace> createState() => _FileWorkspaceState();
}

class _FileWorkspaceState extends State<FileWorkspace> {
  bool _adding = false;
  bool _editing = false;
  bool _naming = false;
  bool _permissionsBusy = false;
  bool _externalDropBusy = false;
  String? _externalDragTabId;
  final _reconnecting = <String>{};
  final _searching = <String>{};
  final _tabKeys = <String, GlobalKey>{};
  final _activeStrips = <int, String?>{};
  FileWorkspaceModel get model => widget.model;

  Widget _tabs(int side, {bool unified = false}) {
    final pane = model.panes[side];
    final tabs = unified ? model.tabs : pane.tabs;
    final activeId = unified ? model.activeTab?.id : pane.activeId;
    final strip = unified ? 2 : side;
    if (_activeStrips[strip] != activeId) {
      _activeStrips[strip] = activeId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final selectedContext = _tabKeys[activeId]?.currentContext;
        if (selectedContext != null) {
          Scrollable.ensureVisible(
            selectedContext,
            duration: HarborMotion.effects(context),
          );
        }
      });
    }
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            for (final item in tabs)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: SizedBox(
                  key: _tabKeys.putIfAbsent(item.id, GlobalKey.new),
                  child: Semantics(
                    selected: item.id == activeId,
                    child: Material(
                      color: item.id == activeId
                          ? colors.secondaryContainer
                          : colors.surfaceContainerHigh,
                      shape: HarborShapes.pill,
                      child: InkWell(
                        key: ValueKey('file-tab-${item.id}'),
                        customBorder: HarborShapes.pill,
                        onTap: () =>
                            model.activate(model.sideOf(item), item.id),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                item.isLocal
                                    ? Icons.computer_rounded
                                    : Icons.dns_outlined,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 132,
                                ),
                                child: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                key: ValueKey('close-file-tab-${item.id}'),
                                onPressed: !model.canClose(item)
                                    ? null
                                    : () =>
                                          model.close(model.sideOf(item), item),
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  semanticLabel: '关闭 ${item.name}',
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 40,
                                  minHeight: 40,
                                ),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(40, 40),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _addMenu(int side, {bool expanded = false}) => PopupMenuButton<Object>(
    key: ValueKey(expanded ? 'empty-add-file-tab-$side' : 'add-file-tab-$side'),
    enabled: !_adding,
    tooltip: '',
    popUpAnimationStyle: HarborMotion.popup(context),
    position: PopupMenuPosition.under,
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
    borderRadius: HarborShapes.tile,
    icon: expanded
        ? null
        : const Icon(Icons.add_rounded, semanticLabel: '添加文件标签'),
    onSelected: (chosen) => _add(side, chosen),
    itemBuilder: (context) {
      final connected = <String, SshConnection>{
        for (final session in widget.sessions)
          if (session.status == ConnectionStatus.connected)
            session.host.id: session,
      };
      final hosts = <String, Host>{
        for (final session in connected.values) session.host.id: session.host,
        for (final host in widget.hosts) host.id: host,
      };
      return [
        const HarborPopupMenuItem<Object>(
          value: 'local',
          child: Row(
            children: [
              Icon(Icons.computer_rounded, size: 20),
              SizedBox(width: 12),
              Text('本地文件'),
            ],
          ),
        ),
        for (final host in hosts.values)
          HarborPopupMenuItem<Object>(
            key: ValueKey('add-file-host-$side-${host.id}'),
            value: connected[host.id] ?? host,
            child: Row(
              children: [
                const Icon(Icons.dns_outlined, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (connected.containsKey(host.id)) ...[
                              const HostOnlineDot(),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                host.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          'SSH · ${host.endpoint}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ];
    },
    child: expanded
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              '添加标签',
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          )
        : null,
  );

  Future<void> _add(int side, Object chosen) async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      if (chosen == 'local') {
        await model.addLocal(side);
      } else {
        final session = chosen is SshConnection
            ? chosen
            : await widget.onConnect(chosen as Host);
        if (session == null) return;
        if (!mounted) {
          if (chosen is Host) session.dispose();
          return;
        }
        model.add(
          side,
          name: session.host.name,
          files: session.files,
          initialPath: session.host.sftpStartPath,
          session: session,
          ownsSession: chosen is Host,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(fileError(e))));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _retry(FileLocationTab tab) async {
    if (_reconnecting.contains(tab.id) ||
        tab.loading ||
        model.locked(tab) ||
        !model.tabs.contains(tab)) {
      return;
    }
    if (tab.connected) {
      await tab.browse();
      return;
    }
    final previous = tab.session;
    if (previous == null || previous.status == ConnectionStatus.connecting) {
      return;
    }
    setState(() => _reconnecting.add(tab.id));
    SshConnection? ownedSession;
    try {
      final host =
          widget.hosts
              .where((host) => host.id == previous.host.id)
              .firstOrNull ??
          previous.host;
      final reusable = widget.sessions
          .where(
            (session) =>
                session.host.id == host.id &&
                session.status == ConnectionStatus.connected,
          )
          .lastOrNull;
      if (reusable == null) ownedSession = await widget.onConnect(host);
      final session = reusable ?? ownedSession;
      if (!mounted || session == null) return;
      if (model.replaceConnection(
        tab,
        session,
        ownsSession: reusable == null,
      )) {
        ownedSession = null;
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(fileError(error))));
      }
    } finally {
      ownedSession?.dispose();
      if (mounted) setState(() => _reconnecting.remove(tab.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return Column(
        children: [
          if (widget.showTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.folder_copy_outlined, color: colors.primary),
                  const SizedBox(width: 12),
                  Text('SFTP', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
          if (_adding || _editing) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final horizontal = constraints.maxWidth >= 600;
                if (horizontal &&
                    widget.initializeLocal &&
                    !model.defaultLocalInitialized) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && widget.initializeLocal) {
                      model.initializeDefaultLocal();
                    }
                  });
                }
                final available = constraints.maxWidth - 12;
                final leftWidth = (available * model.split).clamp(
                  260.0,
                  (available - 260).clamp(260.0, double.infinity),
                );
                if (!horizontal) {
                  return _panel(0, unified: true);
                }
                final panels = [
                  for (var side = 0; side < 2; side++) _panel(side),
                ];
                return Row(
                  children: [
                    SizedBox(width: leftWidth, child: panels[0]),
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: GestureDetector(
                        key: const ValueKey('sftp-split-handle'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (_) =>
                            model.resize(leftWidth / available),
                        onHorizontalDragUpdate: (event) => model.resize(
                          model.split + event.delta.dx / available,
                        ),
                        onDoubleTap: () => model.resize(.5),
                        child: SizedBox(
                          width: 12,
                          child: Center(
                            child: Container(
                              width: 3,
                              height: 32,
                              decoration: BoxDecoration(
                                color: colors.outlineVariant,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: panels[1]),
                  ],
                );
              },
            ),
          ),
          if (model.busy || model.message != null) _statusBar(),
        ],
      );
    },
  );

  Widget _panel(int side, {bool unified = false}) {
    final pane = model.panes[side];
    final tab = unified ? model.activeTab : pane.active;
    final colors = Theme.of(context).colorScheme;
    final externalEnabled = _canAcceptExternalDrop(tab);
    final externalHover = externalEnabled && _externalDragTabId == tab?.id;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        side == 0 ? 8 : 0,
        8,
        side == 1 || unified ? 8 : 0,
        8,
      ),
      child: DropTarget(
        key: ValueKey('file-external-drop-panel-$side'),
        enable: externalEnabled,
        onDragEntered: (_) => setState(() => _externalDragTabId = tab!.id),
        onDragExited: (_) {
          final hovered = _externalDragTabId;
          // desktop_drop also calls this while didUpdateWidget disables a
          // hovered target. Its ancestor cannot rebuild in the same frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _externalDragTabId == hovered) {
              setState(() => _externalDragTabId = null);
            }
          });
          WidgetsBinding.instance.ensureVisualUpdate();
        },
        onDragDone: (details) {
          setState(() => _externalDragTabId = null);
          if (tab != null) unawaited(_dropExternalFiles(details.files, tab));
        },
        child: DragTarget<FileDragData>(
          key: ValueKey('file-drop-panel-$side'),
          onWillAcceptWithDetails: (details) =>
              model.canDrop(details.data, tab),
          onAcceptWithDetails: (details) {
            if (tab != null) {
              unawaited(_dropWithConfirmation(details.data, tab));
            }
          },
          builder: (context, candidates, rejected) => Material(
            key: ValueKey('file-panel-$side'),
            color: candidates.isNotEmpty || externalHover
                ? colors.secondaryContainer.withValues(alpha: .4)
                : colors.surfaceContainerLow,
            shape: HarborShapes.superellipse().copyWith(
              side: BorderSide(
                color: candidates.isNotEmpty || externalHover
                    ? colors.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SizedBox(
                  key: ValueKey('file-tab-header-$side'),
                  height: 48,
                  child: Row(
                    children: [
                      Expanded(
                        child: (unified ? model.tabs : pane.tabs).isEmpty
                            ? Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Text(
                                  '添加标签',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              )
                            : _tabs(side, unified: unified),
                      ),
                      _addMenu(side),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                Expanded(
                  child: tab == null
                      ? _emptyPanel(side)
                      : _browser(side, tab, clipboardMode: unified),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _canAcceptExternalDrop(FileLocationTab? tab) =>
      widget.acceptExternalDrops &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      !_externalDropBusy &&
      !_editing &&
      !_naming &&
      !_permissionsBusy &&
      tab != null &&
      !tab.isLocal &&
      model.canAcceptExternalDrop(tab);

  Future<void> _dropExternalFiles(
    List<DropItem> items,
    FileLocationTab target,
  ) async {
    if (!_canAcceptExternalDrop(target) || items.isEmpty) return;
    final owner = model;
    final directory = target.path;
    final scopes = <Uint8List>[];
    FileDragData? data;
    // The transfer owns these permissions while paused; only a terminal
    // success/discard releases them. Preparation failures release immediately.
    Future<void> releaseScopes() async {
      final held = List<Uint8List>.of(scopes);
      scopes.clear();
      await Future.wait([
        for (final bookmark in held.reversed)
          DesktopDrop.instance.stopAccessingSecurityScopedResource(
            bookmark: bookmark,
          ),
      ]);
    }

    setState(() => _externalDropBusy = true);
    try {
      for (final item in items) {
        final bookmark = item.extraAppleBookmark;
        if (bookmark != null && bookmark.isNotEmpty) {
          final granted = await DesktopDrop.instance
              .startAccessingSecurityScopedResource(bookmark: bookmark);
          if (!granted) throw StateError('无法读取拖入的本地项目：${item.name}');
          scopes.add(bookmark);
        }
      }
      final prepared = await owner.prepareExternalDrop([
        for (final item in items) item.path,
      ], release: releaseScopes);
      data = prepared;
      // Do not redirect a drop if navigation/connection changed while local
      // metadata or macOS permissions were being read.
      if (!mounted ||
          !identical(model, owner) ||
          !widget.acceptExternalDrops ||
          target.path != directory ||
          !owner.canDrop(prepared, target)) {
        return;
      }
      final overwriteConflicts = await _confirmOverwrite(prepared, target);
      if (overwriteConflicts == null ||
          !mounted ||
          !identical(model, owner) ||
          !widget.acceptExternalDrops ||
          target.path != directory) {
        return;
      }
      await owner.drop(
        prepared,
        target,
        overwriteConflicts: overwriteConflicts,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(fileError(error))));
      }
    } finally {
      try {
        if (data == null) {
          await releaseScopes();
        } else {
          owner.releaseExternalDrop(data);
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(fileError(error))));
        }
      } finally {
        if (mounted) setState(() => _externalDropBusy = false);
      }
    }
  }

  Future<List<RemoteFile>?> _confirmOverwrite(
    FileDragData data,
    FileLocationTab target,
  ) async {
    final targetPath = target.path;
    final conflicts = model.conflicts(data, target);
    if (conflicts.isEmpty) return const [];
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('覆盖 ${conflicts.length} 个同名项目？'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('目标中的同名文件或文件夹将被永久替换，此操作无法撤销。'),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in conflicts)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Icon(
                                item.isDirectory
                                    ? Icons.folder_outlined
                                    : Icons.insert_drive_file_outlined,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel-overwrite-files'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-overwrite-files'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    if (!mounted ||
        target.path != targetPath ||
        !model.canDrop(data, target) ||
        !model.conflictsMatch(data, target, conflicts)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('目标目录内容已变化，请重新操作')));
      }
      return null;
    }
    return conflicts;
  }

  Future<void> _dropWithConfirmation(
    FileDragData data,
    FileLocationTab target,
  ) async {
    if (!model.canDrop(data, target)) return;
    final overwriteConflicts = await _confirmOverwrite(data, target);
    if (overwriteConflicts == null || !mounted) return;
    await model.drop(data, target, overwriteConflicts: overwriteConflicts);
  }

  Future<void> _pasteWithConfirmation(FileLocationTab target) async {
    final data = model.clipboard;
    if (data == null || !model.canPaste(target)) return;
    final overwriteConflicts = await _confirmOverwrite(data, target);
    if (overwriteConflicts == null || !mounted) return;
    await model.paste(target, overwriteConflicts: overwriteConflicts);
  }

  Widget _emptyPanel(int side) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 36,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '添加 SFTP 或本地文件夹',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            _addMenu(side, expanded: true),
          ],
        ),
      ),
    ),
  );

  bool get _touchPlatform => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };

  /// 工具条高度（触屏更高）；浏览器布局按它算固定高度还剩多少。
  double get _toolbarExtent => _touchPlatform ? 48 : 40;

  /// 计数行的固定高度：内边距（6 + 8）加一行 labelSmall。
  static const _countRowExtent = 30.0;

  /// 列表至少要留出的高度（略小于一行条目），否则让出计数行。
  static const _minimumListExtent = 44.0;

  Widget _browserToolbar(FileLocationTab tab, bool enabled) {
    final searching = _searching.contains(tab.id) || tab.query.isNotEmpty;
    final extent = _toolbarExtent;
    Widget button(
      IconData icon,
      String label,
      VoidCallback? onPressed, {
      bool? selected,
    }) => IconButton(
      onPressed: onPressed,
      isSelected: selected,
      icon: Icon(icon, size: 20, semanticLabel: label),
      style: IconButton.styleFrom(
        minimumSize: Size.square(extent),
        maximumSize: Size.square(extent),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: SizedBox(
        key: ValueKey('file-toolbar-${tab.id}'),
        height: extent,
        child: Row(
          children: [
            button(
              Icons.arrow_upward_rounded,
              '上级目录',
              enabled && tab.parent != null
                  ? () => tab.browse(tab.parent)
                  : null,
            ),
            Expanded(
              child: TextFormField(
                key: ValueKey(
                  '${searching ? 'query' : 'path'}-${tab.id}-${tab.path}',
                ),
                initialValue: searching ? tab.query : tab.path,
                enabled: searching || enabled,
                autofocus: searching,
                style: Theme.of(context).textTheme.bodySmall,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: searching
                      ? '筛选文件'
                      : (tab.isLocal ? '本地路径' : '远程路径'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                ),
                onChanged: searching ? tab.filter : null,
                onFieldSubmitted: searching
                    ? null
                    : (value) {
                        if (value.isNotEmpty) tab.browse(value);
                      },
              ),
            ),
            button(
              searching ? Icons.close_rounded : Icons.search_rounded,
              searching ? '关闭筛选' : '筛选文件',
              () {
                setState(() {
                  if (searching) {
                    _searching.remove(tab.id);
                    tab.filter('');
                  } else {
                    _searching.add(tab.id);
                  }
                });
              },
            ),
            if (tab.isLocal
                ? widget.onSetLocalBookmark != null
                : tab.session != null && widget.onSetBookmark != null)
              _bookmarkMenu(tab, enabled, extent),
            button(
              Icons.refresh_rounded,
              '刷新目录',
              enabled ? () => tab.browse() : null,
            ),
            button(
              tab.showHidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              tab.showHidden ? '隐藏隐藏文件' : '显示隐藏文件',
              tab.toggleHidden,
              selected: tab.showHidden,
            ),
          ],
        ),
      ),
    );
  }

  Widget _browser(int side, FileLocationTab tab, {bool clipboardMode = false}) {
    final loading =
        tab.loading ||
        _reconnecting.contains(tab.id) ||
        tab.session?.status == ConnectionStatus.connecting;
    final enabled = !loading && tab.connected && !model.locked(tab);
    final entries = tab.visibleEntries;
    final touch = _touchPlatform;
    final copying = tab.selected.isNotEmpty;
    final showAction = clipboardMode && (copying || model.clipboard != null);
    final listArea = loading
        ? const Center(child: CircularProgressIndicator())
        : tab.error != null
        ? Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tab.error!, textAlign: TextAlign.center),
                    TextButton(
                      key: ValueKey('retry-file-tab-${tab.id}'),
                      onPressed: !model.locked(tab) ? () => _retry(tab) : null,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (details) =>
                _blankMenu(tab, details.globalPosition),
            // 移动端没有右键，空目录和空白区用长按打开同一份创建菜单；
            // 桌面保持右键，避免按住条目时误开菜单。
            onLongPressStart: touch
                ? (details) => _blankMenu(tab, details.globalPosition)
                : null,
            child: entries.isEmpty
                ? const Center(child: Text('没有可显示的文件'))
                : ListView.builder(
                    key: PageStorageKey('directory-${tab.id}-${tab.path}'),
                    padding: EdgeInsets.fromLTRB(8, 0, 8, showAction ? 72 : 0),
                    itemCount: entries.length,
                    itemBuilder: (_, index) => _entry(
                      tab,
                      entries[index],
                      enabled,
                      index,
                      entries.length,
                      clipboardMode: clipboardMode,
                    ),
                  ),
          );
    final countRow = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          Text(
            '${entries.length} 项',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const Spacer(),
          if (!clipboardMode && tab.selected.isNotEmpty)
            Text(
              '已选 ${tab.selected.length} 个文件',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
    final content = LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          _browserToolbar(tab, enabled),
          Expanded(child: listArea),
          // 工具条和计数行都是固定高度：视口被状态栏或软键盘压到连一行条目都
          // 放不下时让出计数行，列表最多被压成 0，不会再溢出。
          if (constraints.maxHeight >=
              _toolbarExtent + 4 + _countRowExtent + _minimumListExtent)
            countRow,
        ],
      ),
    );
    if (!clipboardMode) return content;
    return Stack(
      children: [
        Positioned.fill(child: content),
        if (showAction)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              key: ValueKey(copying ? 'copy-files' : 'paste-files'),
              heroTag: null,
              elevation: 0,
              focusElevation: 0,
              hoverElevation: 0,
              highlightElevation: 0,
              disabledElevation: 0,
              onPressed: copying
                  ? (enabled && !model.busy
                        ? () => model.copySelection(tab)
                        : null)
                  : (model.canPaste(tab)
                        ? () => _pasteWithConfirmation(tab)
                        : null),
              icon: Icon(
                copying ? Icons.copy_rounded : Icons.content_paste_rounded,
                size: 20,
              ),
              label: Text(
                copying
                    ? '复制 ${tab.selected.length} 项'
                    : '粘贴 ${model.clipboard!.files.length} 项',
              ),
            ),
          ),
      ],
    );
  }

  List<String> _bookmarks(FileLocationTab tab) {
    if (tab.isLocal) return widget.localBookmarks;
    final id = tab.session!.host.id;
    return (widget.hosts.where((host) => host.id == id).firstOrNull ??
            tab.session!.host)
        .sftpBookmarks;
  }

  bool _samePath(FileLocationTab tab, String a, String b) =>
      tab.isLocal ? widget.sameLocalPath(a, b) : a == b;

  Future<void> _setBookmark(
    FileLocationTab tab,
    String path, {
    required bool saved,
  }) async {
    try {
      if (tab.isLocal) {
        await widget.onSetLocalBookmark!(path, saved: saved);
      } else {
        await widget.onSetBookmark!(tab.session!.host.id, path, saved: saved);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('书签保存失败：${fileError(e)}')));
      }
    }
  }

  Widget _bookmarkMenu(FileLocationTab tab, bool enabled, double extent) {
    final bookmarks = _bookmarks(tab);
    final marked = bookmarks.any((path) => _samePath(tab, path, tab.path));
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<(String, String)>(
      key: ValueKey('file-bookmarks-${tab.id}'),
      enabled: enabled,
      tooltip: '目录书签',
      iconColor: colors.onSurfaceVariant,
      popUpAnimationStyle: HarborMotion.popup(context),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
      style: IconButton.styleFrom(
        minimumSize: Size.square(extent),
        maximumSize: Size.square(extent),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        marked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        size: 20,
        semanticLabel: '目录书签',
      ),
      onSelected: (choice) {
        final (action, path) = choice;
        switch (action) {
          case 'open':
            tab.browse(path);
          case 'add':
            unawaited(_setBookmark(tab, path, saved: true));
          case 'remove':
            unawaited(_setBookmark(tab, path, saved: false));
        }
      },
      itemBuilder: (menuContext) => [
        HarborPopupMenuItem(
          key: ValueKey('file-bookmark-toggle-${tab.id}'),
          value: (marked ? 'remove' : 'add', tab.path),
          child: Row(
            children: [
              Icon(
                marked
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined,
                size: 20,
              ),
              const SizedBox(width: 12),
              Text(marked ? '移除当前目录书签' : '收藏当前目录'),
            ],
          ),
        ),
        if (bookmarks.isNotEmpty) const PopupMenuDivider(),
        for (final path in bookmarks)
          HarborPopupMenuItem(
            key: ValueKey('file-bookmark-$path'),
            value: ('open', path),
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(
                  _samePath(tab, path, tab.path)
                      ? Icons.folder_rounded
                      : Icons.folder_outlined,
                  size: 20,
                  color: _samePath(tab, path, tab.path) ? colors.primary : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: path,
                    child: Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('file-bookmark-remove-$path'),
                  tooltip: '移除书签',
                  onPressed: () =>
                      Navigator.of(menuContext).pop(('remove', path)),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
          ),
      ],
    );
  }

  bool _canEditRemoteText(FileLocationTab tab, RemoteFile file) =>
      !tab.isLocal && !file.isDirectory && !file.isLink;

  Future<void> _editFile(FileLocationTab tab, RemoteFile file) async {
    if (_editing ||
        !mounted ||
        !model.tabs.contains(tab) ||
        model.busy ||
        tab.loading ||
        tab.error != null ||
        !tab.connected) {
      return;
    }
    setState(() => _editing = true);
    try {
      final saved = await showRemoteTextEditor(
        context,
        files: tab.files,
        file: file,
      );
      if (!saved || !mounted || !model.tabs.contains(tab)) return;
      await tab.browse();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(fileError(e))));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _entryMenu(
    FileLocationTab tab,
    RemoteFile file,
    Offset position,
  ) async {
    if (_editing || _naming || _permissionsBusy) return;
    if (!tab.selected.contains(file.path)) tab.select(file);
    final data = model.dragData(tab, file);
    final deletable = model.canDelete(data);
    final editable =
        deletable && data.files.length == 1 && _canEditRemoteText(tab, file);
    final creatable = model.canCreate(tab);
    final renamable = model.canRename(tab, file);
    final permissions = model.canSetPermissions(tab, file);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final anchorX = point.dx + 4;
    final colors = Theme.of(context).colorScheme;
    final action = await showMenu<Object>(
      context: context,
      popUpAnimationStyle: HarborMotion.popup(context),
      // 相等的左右锚距让菜单按阅读方向从鼠标右侧展开；
      // 空间不足时 Flutter 仍会将自适应宽度的菜单限制在屏幕内。
      position: RelativeRect.fromLTRB(anchorX, point.dy, anchorX, 0),
      items: [
        if (creatable) ...[
          HarborPopupMenuItem<Object>(
            key: const ValueKey('create-directory-entry'),
            value: 'create-directory',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.create_new_folder_outlined,
                  size: 20,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                const Text('创建文件夹'),
              ],
            ),
          ),
          HarborPopupMenuItem<Object>(
            key: const ValueKey('create-file-entry'),
            value: 'create-file',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.note_add_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 10),
                const Text('创建文件'),
              ],
            ),
          ),
        ],
        if (editable)
          HarborPopupMenuItem<Object>(
            key: const ValueKey('edit-remote-file'),
            value: 'edit',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 10),
                const Text('编辑文件'),
              ],
            ),
          ),
        HarborPopupMenuItem<Object>(
          key: const ValueKey('copy-entry-path'),
          value: 'copy-path',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.content_copy_rounded, size: 20, color: colors.primary),
              const SizedBox(width: 10),
              const Text('复制路径'),
            ],
          ),
        ),
        if (renamable)
          HarborPopupMenuItem<Object>(
            key: const ValueKey('rename-entry'),
            value: 'rename',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.drive_file_rename_outline_rounded,
                  size: 20,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                const Text('重命名'),
              ],
            ),
          ),
        if (permissions) ...[
          HarborPopupMenuItem<Object>(
            key: const ValueKey('set-entry-permissions'),
            value: 'permissions',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 20,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                const Text('设置权限'),
              ],
            ),
          ),
          HarborPopupMenuItem<Object>(
            key: const ValueKey('set-entry-owner'),
            value: 'owner',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.badge_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 10),
                const Text('权限组'),
              ],
            ),
          ),
        ],
        if (deletable)
          HarborPopupMenuItem<Object>(
            key: const ValueKey('delete-selected-files'),
            value: 'delete',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: colors.error,
                ),
                const SizedBox(width: 10),
                Text(
                  '删除 ${data.files.length} 个文件',
                  style: TextStyle(color: colors.error),
                ),
              ],
            ),
          ),
      ],
    );
    switch (action) {
      case 'create-directory':
        await _createEntry(tab, directory: true);
        return;
      case 'create-file':
        await _createEntry(tab, directory: false);
        return;
      case 'copy-path':
        await _copyPath(tab, file);
        return;
      case 'rename':
        await _renameEntry(tab, file);
        return;
      case 'permissions':
        await _openPermissions(tab, file, _PermissionSection.mode);
        return;
      case 'owner':
        await _openPermissions(tab, file, _PermissionSection.owner);
        return;
      case 'edit':
        await _editFile(tab, file);
        return;
    }
    if (action != 'delete' || !mounted || !model.canDelete(data)) return;
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${data.files.length} 个文件？'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('文件将永久删除，无法撤销。'),
                const SizedBox(height: 12),
                for (final file in data.files)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(file.name),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-files'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await model.deleteFiles(data);
  }

  List<String> _copyPaths(FileLocationTab tab, RemoteFile file) =>
      tab.selected.contains(file.path)
      ? [
          for (final entry in tab.entries)
            if (tab.selected.contains(entry.path)) entry.path,
        ]
      : [file.path];

  /// 复制使用真实完整路径，多选按列表顺序换行分隔；只读取选区，不做任何改动。
  Future<void> _copyPath(FileLocationTab tab, RemoteFile file) async {
    final paths = _copyPaths(tab, file);
    if (paths.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: paths.join('\n')));
  }

  Future<void> _createEntry(
    FileLocationTab tab, {
    required bool directory,
  }) async {
    if (_naming || _editing || _permissionsBusy || model.busy) return;
    if (!model.canCreate(tab)) return;
    final tabId = tab.id;
    final files = tab.files;
    final directoryPath = tab.path;
    final name = await showExpressiveDialog<String>(
      context: context,
      builder: (context) => _EntryNameDialog(
        directory: directory,
        directoryPath: directoryPath,
        childPath: files.childPath,
      ),
    );
    if (name == null || !mounted) return;
    if (!model.tabs.contains(tab) ||
        tab.id != tabId ||
        !identical(tab.files, files)) {
      return;
    }
    setState(() => _naming = true);
    try {
      await model.createEntry(tab, name, directory: directory);
    } finally {
      if (mounted) setState(() => _naming = false);
    }
  }

  /// 只在条目所在的当前目录内改名；对话框期间标签页、连接或条目变化时放弃提交。
  Future<void> _renameEntry(FileLocationTab tab, RemoteFile file) async {
    if (_naming || _editing || _permissionsBusy || model.busy) return;
    if (!model.canRename(tab, file)) return;
    final tabId = tab.id;
    final files = tab.files;
    final directoryPath = tab.path;
    final name = await showExpressiveDialog<String>(
      context: context,
      builder: (context) => _EntryNameDialog(
        directory: file.isDirectory,
        directoryPath: directoryPath,
        childPath: files.childPath,
        renaming: file,
      ),
    );
    if (name == null || !mounted) return;
    if (!_sameTarget(tab, tabId, files, file.path) ||
        tab.path != directoryPath) {
      return;
    }
    setState(() => _naming = true);
    try {
      await model.renameEntry(tab, file, name);
    } finally {
      if (mounted) setState(() => _naming = false);
    }
  }

  /// 空白区域（含空目录）只在当前目录创建，不指向任何条目。
  Future<void> _blankMenu(FileLocationTab tab, Offset position) async {
    if (_editing || _naming || _permissionsBusy || model.busy) return;
    if (!model.canCreate(tab)) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final anchorX = point.dx + 4;
    final colors = Theme.of(context).colorScheme;
    final action = await showMenu<Object>(
      context: context,
      popUpAnimationStyle: HarborMotion.popup(context),
      position: RelativeRect.fromLTRB(anchorX, point.dy, anchorX, 0),
      items: [
        HarborPopupMenuItem<Object>(
          key: const ValueKey('blank-create-directory'),
          value: 'create-directory',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.create_new_folder_outlined,
                size: 20,
                color: colors.primary,
              ),
              const SizedBox(width: 10),
              const Text('创建文件夹'),
            ],
          ),
        ),
        HarborPopupMenuItem<Object>(
          key: const ValueKey('blank-create-file'),
          value: 'create-file',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.note_add_outlined, size: 20, color: colors.primary),
              const SizedBox(width: 10),
              const Text('创建文件'),
            ],
          ),
        ),
      ],
    );
    if (action == 'create-directory') await _createEntry(tab, directory: true);
    if (action == 'create-file') await _createEntry(tab, directory: false);
  }

  /// 读取期间禁止重入；读取或对话框期间标签页或连接变化时不再提交到错误目标。
  Future<void> _openPermissions(
    FileLocationTab tab,
    RemoteFile file,
    _PermissionSection section,
  ) async {
    if (_permissionsBusy || _editing || _naming || !mounted) return;
    if (!model.canSetPermissions(tab, file)) return;
    final files = tab.files;
    if (files is! RemoteFilePermissions) return;
    final tabId = tab.id;
    final path = file.path;
    setState(() => _permissionsBusy = true);
    try {
      final FilePermissions current;
      try {
        current = await files.readPermissions(path);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(fileError(error))));
        }
        return;
      }
      if (!mounted || !_sameTarget(tab, tabId, files, path)) return;
      final edit = await showExpressiveDialog<_PermissionEdit>(
        context: context,
        builder: (context) =>
            _PermissionsDialog(file: file, current: current, section: section),
      );
      if (edit == null || !mounted) return;
      if (!_sameTarget(tab, tabId, files, path)) return;
      await model.updatePermissions(
        tab,
        file,
        mode: edit.mode,
        userId: edit.userId,
        groupId: edit.groupId,
      );
    } finally {
      if (mounted) setState(() => _permissionsBusy = false);
    }
  }

  bool _sameTarget(
    FileLocationTab tab,
    String tabId,
    RemoteFileSystem files,
    String path,
  ) =>
      model.tabs.contains(tab) &&
      tab.id == tabId &&
      identical(tab.files, files) &&
      tab.connected &&
      tab.entries.any((entry) => entry.path == path);

  Widget _entry(
    FileLocationTab tab,
    RemoteFile file,
    bool enabled,
    int index,
    int count, {
    bool clipboardMode = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected = tab.selected.contains(file.path);
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final shape = HarborShapes.superellipse(
      HarborShapes.listItem(HarborShapes.listSlot(index, count)),
    );
    final canOpenMenu =
        enabled && !model.busy && !_editing && !_naming && !_permissionsBusy;
    void action() {
      if (file.isDirectory) {
        tab.browse(file.path);
      } else {
        if (mobile) {
          tab.selectOnMobile(file);
        } else {
          final keyboard = HardwareKeyboard.instance;
          tab.select(
            file,
            toggleSelection:
                keyboard.isControlPressed || keyboard.isMetaPressed,
            range: keyboard.isShiftPressed,
          );
        }
      }
    }

    final row = Semantics(
      selected: selected,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected ? colors.secondaryContainer : colors.surface,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('entry-${tab.id}-${file.path}'),
            onTap: enabled ? action : null,
            onSecondaryTapUp: canOpenMenu
                ? (details) => _entryMenu(tab, file, details.globalPosition)
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Icon(
                      file.isDirectory
                          ? Icons.folder_rounded
                          : Icons.insert_drive_file_outlined,
                      size: 22,
                      color: file.isDirectory
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: file.isDirectory
                        ? const Icon(Icons.chevron_right_rounded, size: 18)
                        : Text(
                            fileSizeLabel(file.size),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!enabled || model.busy) return row;
    if (clipboardMode || mobile) {
      return GestureDetector(
        onLongPressStart: canOpenMenu
            ? (details) => _entryMenu(tab, file, details.globalPosition)
            : null,
        child: _SwipeSelect(
          key: ValueKey('swipe-${tab.id}-${file.path}'),
          shape: shape,
          deselect: tab.willDeselectOnMobile(file),
          onSelect: () => tab.selectOnMobile(file),
          child: row,
        ),
      );
    }
    final data = model.dragData(tab, file);
    final feedback = Transform.translate(
      offset: const Offset(12, 12),
      child: Material(
        color: colors.primaryContainer,
        shape: HarborShapes.pill,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                file.isDirectory
                    ? Icons.folder_copy_outlined
                    : Icons.file_copy_outlined,
                size: 20,
                color: colors.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  data.files.length == 1
                      ? file.name
                      : '${data.files.length} 个项目',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.onPrimaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<FileDragData>(
        data: data,
        feedback: feedback,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
        maxSimultaneousDrags: 1,
        childWhenDragging: Opacity(opacity: .45, child: row),
        child: row,
      ),
    );
  }

  Widget _statusBar() {
    final colors = Theme.of(context).colorScheme;
    final transferring = model.transfer != null;
    final progress = transferring && model.total != null && model.total! > 0
        ? (model.transferred / model.total!).clamp(0.0, 1.0)
        : null;
    final text = transferring
        ? '${model.transfer!.cancelled ? (model.resumable ? '正在暂停 · ' : '正在取消 · ') : ''}${model.transferName}'
        : model.message ?? '就绪';
    final icon = model.deleting
        ? Icons.delete_outline_rounded
        : transferring
        ? Icons.sync_rounded
        : model.failed
        ? Icons.error_outline_rounded
        : model.message != null
        ? Icons.check_circle_outline_rounded
        : Icons.info_outline_rounded;
    return SizedBox(
      key: const ValueKey('file-status-bar'),
      height: 64,
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Material(
          color: colors.surfaceContainerLow,
          shape: HarborShapes.superellipse(),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4, bottom: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: ShapeDecoration(
                          color: model.failed
                              ? colors.errorContainer
                              : model.busy
                              ? colors.primaryContainer
                              : colors.secondaryContainer,
                          shape: HarborShapes.superellipse(
                            const BorderRadius.all(HarborShapes.sm),
                          ),
                        ),
                        child: Icon(
                          icon,
                          size: 18,
                          color: model.failed
                              ? colors.onErrorContainer
                              : model.busy
                              ? colors.onPrimaryContainer
                              : colors.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              text,
                              maxLines: transferring ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: model.failed
                                        ? colors.error
                                        : colors.onSurface,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                            if (transferring || model.canResume)
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${fileSizeLabel(model.transferred)}${model.total != null ? ' / ${fileSizeLabel(model.total)}' : ''}${progress != null ? ' · ${(progress * 100).round()}%' : ''}',
                                      key: const ValueKey(
                                        'file-transfer-progress',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    model.transferSpeed.label,
                                    key: const ValueKey('file-transfer-speed'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      if (transferring)
                        IconButton(
                          key: const ValueKey('cancel-file-transfer'),
                          onPressed: model.transfer!.cancelled
                              ? null
                              : model.cancel,
                          tooltip: model.resumable ? '暂停传输' : '取消传输',
                          icon: Icon(
                            model.resumable
                                ? Icons.pause_rounded
                                : Icons.close_rounded,
                            size: 18,
                            semanticLabel: model.resumable ? '暂停传输' : '取消传输',
                          ),
                        )
                      else if (model.canResume) ...[
                        IconButton(
                          key: const ValueKey('resume-file-transfer'),
                          tooltip: '继续传输',
                          onPressed: model.canContinue ? model.resume : null,
                          icon: const Icon(
                            Icons.play_arrow_rounded,
                            semanticLabel: '继续传输',
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('discard-file-transfer'),
                          tooltip: '放弃传输并清理缓存',
                          onPressed: model.discardTransfer,
                          icon: const Icon(
                            Icons.close_rounded,
                            semanticLabel: '放弃传输',
                          ),
                        ),
                      ] else if (!model.busy && model.message != null)
                        IconButton(
                          key: const ValueKey('dismiss-file-result'),
                          onPressed: model.dismissMessage,
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            semanticLabel: '清除提示',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (model.busy)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 4,
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    borderRadius: const BorderRadius.all(HarborShapes.xs),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwipeSelect extends StatefulWidget {
  const _SwipeSelect({
    super.key,
    required this.onSelect,
    required this.shape,
    required this.deselect,
    required this.child,
  });

  final VoidCallback onSelect;
  final ShapeBorder shape;
  final bool deselect;
  final Widget child;

  @override
  State<_SwipeSelect> createState() => _SwipeSelectState();
}

class _SwipeSelectState extends State<_SwipeSelect> {
  double _distance = 0;
  bool _dragging = false;
  bool _deselecting = false;

  void _reset() => setState(() {
    _dragging = false;
    _distance = 0;
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    dragStartBehavior: DragStartBehavior.down,
    onHorizontalDragStart: (_) => setState(() {
      _dragging = true;
      _distance = 0;
      _deselecting = widget.deselect;
    }),
    onHorizontalDragUpdate: (details) {
      final wasReady = _distance.abs() >= 32;
      setState(() => _distance = (_distance + details.delta.dx).clamp(-80, 80));
      if (!wasReady && _distance.abs() >= 32) HapticFeedback.selectionClick();
    },
    onHorizontalDragEnd: (_) {
      if (_distance.abs() >= 32) widget.onSelect();
      _reset();
    },
    onHorizontalDragCancel: _reset,
    child: ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _distance),
        duration: _dragging ? Duration.zero : HarborMotion.effects(context),
        curve: Curves.easeOutCubic,
        child: widget.child,
        builder: (context, offset, child) {
          final colors = Theme.of(context).colorScheme;
          final ready = _distance.abs() >= 32;
          final actionColor = _deselecting
              ? colors.tertiaryContainer
              : colors.primaryContainer;
          final onActionColor = _deselecting
              ? colors.onTertiaryContainer
              : colors.onPrimaryContainer;
          return Stack(
            children: [
              if (offset.abs() > .1)
                Positioned.fill(
                  bottom: 2,
                  child: Material(
                    shape: widget.shape,
                    color: ready ? actionColor : colors.surfaceContainerHighest,
                    child: Align(
                      alignment: offset < 0
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Icon(
                          _deselecting
                              ? (ready
                                    ? Icons.remove_circle_rounded
                                    : Icons.remove_circle_outline_rounded)
                              : (ready
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded),
                          semanticLabel: _deselecting ? '取消选择' : '选择',
                          size: 20,
                          color: ready
                              ? onActionColor
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              Transform.translate(offset: Offset(offset, 0), child: child),
            ],
          );
        },
      ),
    ),
  );
}

enum _PermissionSection { mode, owner }

/// 权限对话框的提交结果：设置权限只带 mode，权限组同时带 uid 和 gid。
class _PermissionEdit {
  const _PermissionEdit({this.mode, this.userId, this.groupId});
  final int? mode, userId, groupId;
}

/// 八进制展示：3 位是普通权限，4 位含 setuid/setgid/粘滞位；未知保持空白。
String _octalLabel(int? mode) =>
    mode == null ? '' : mode.toRadixString(8).padLeft(3, '0');

/// 创建与重命名共用的名称输入；[renaming] 非空时预填原名并选中主名部分。
class _EntryNameDialog extends StatefulWidget {
  const _EntryNameDialog({
    required this.directory,
    required this.directoryPath,
    required this.childPath,
    this.renaming,
  });
  final bool directory;
  final String directoryPath;
  final String Function(String directory, String name) childPath;
  final RemoteFile? renaming;

  @override
  State<_EntryNameDialog> createState() => _EntryNameDialogState();
}

class _EntryNameDialogState extends State<_EntryNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    final name = widget.renaming?.name ?? '';
    // 文件只选中扩展名前的部分，隐藏文件（.bashrc）和目录选中全名。
    final dot = widget.directory ? -1 : name.lastIndexOf('.');
    _controller = TextEditingController(text: name)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: dot > 0 ? dot : name.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 与数据层同一套校验：名称先经 childPath 解析，空名、./..、斜杠和 NUL
  /// 都在这里被拒绝，回车与按钮走同一条路径。
  void _submit() {
    final name = _controller.text.trim();
    String? error;
    if (name.isEmpty) {
      error = '请输入名称';
    } else {
      try {
        widget.childPath(widget.directoryPath, name);
      } on FormatException catch (e) {
        error = e.message;
      } catch (_) {
        error = '无效的名称';
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    // 名称未变等同于取消，不发起任何写入。
    Navigator.pop(context, name == widget.renaming?.name ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final renaming = widget.renaming != null;
    return AlertDialog(
      key: ValueKey(
        renaming
            ? 'rename-entry-dialog'
            : widget.directory
            ? 'create-directory-dialog'
            : 'create-file-dialog',
      ),
      title: Text(
        renaming
            ? '重命名'
            : widget.directory
            ? '创建文件夹'
            : '创建文件',
      ),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '位置：${widget.directoryPath}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('create-entry-name'),
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: widget.directory ? '文件夹名称' : '文件名称',
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancel-create-entry'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-create-entry'),
          onPressed: _submit,
          child: Text(renaming ? '重命名' : '创建'),
        ),
      ],
    );
  }
}

/// 权限与权限组的编辑面；两个入口共用同一套八进制、勾选与数字身份控件。
class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({
    required this.file,
    required this.current,
    required this.section,
  });
  final RemoteFile file;
  final FilePermissions current;
  final _PermissionSection section;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  static const _setUserId = 0x800; // 4000
  static const _setGroupId = 0x400; // 2000
  static const _sticky = 0x200; // 1000
  static const _maxMode = 0xFFF; // 07777
  static const _maxId = 4294967295;

  late final TextEditingController _octal;
  late final TextEditingController _uid;
  late final TextEditingController _gid;
  var _bits = 0;
  String? _octalError, _ownerError;

  @override
  void initState() {
    super.initState();
    _bits = widget.current.mode ?? 0;
    _octal = TextEditingController(text: _octalLabel(widget.current.mode));
    // 服务器没有报告的身份保持空白，绝不回填 0。
    _uid = TextEditingController(text: widget.current.userId?.toString() ?? '');
    _gid = TextEditingController(
      text: widget.current.groupId?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _octal.dispose();
    _uid.dispose();
    _gid.dispose();
    super.dispose();
  }

  int? _parseOctal(String text) {
    final value = text.trim();
    if (!RegExp(r'^[0-7]{3,4}$').hasMatch(value)) return null;
    final parsed = int.parse(value, radix: 8);
    return parsed > _maxMode ? null : parsed;
  }

  int? _parseId(String text) {
    final value = text.trim();
    if (!RegExp(r'^\d{1,10}$').hasMatch(value)) return null;
    final parsed = int.tryParse(value);
    return parsed == null || parsed > _maxId ? null : parsed;
  }

  void _onOctalChanged(String text) {
    final value = _parseOctal(text);
    setState(() {
      if (value == null) {
        _octalError = text.trim().isEmpty ? null : '请输入 3 到 4 位八进制数（0-7）';
      } else {
        _bits = value;
        _octalError = null;
      }
    });
  }

  void _toggle(int bit, bool on) {
    setState(() {
      _bits = on ? (_bits | bit) : (_bits & ~bit);
      _octal.text = _octalLabel(_bits);
      _octalError = null;
    });
  }

  void _submitMode() {
    final value = _parseOctal(_octal.text);
    if (value == null) {
      setState(() => _octalError = '请输入 3 到 4 位八进制数（0-7）');
      return;
    }
    Navigator.pop(context, _PermissionEdit(mode: value));
  }

  void _submitOwner() {
    final uid = _parseId(_uid.text);
    final gid = _parseId(_gid.text);
    if (uid == null || gid == null) {
      setState(() => _ownerError = '请填写 0 到 4294967295 之间的 UID 和 GID');
      return;
    }
    // UID 与 GID 必须同时提交，单个值会被服务器静默忽略。
    Navigator.pop(context, _PermissionEdit(userId: uid, groupId: gid));
  }

  Widget _check(String id, String label, int bit) {
    final checked = _bits & bit != 0;
    return InkWell(
      onTap: () => _toggle(bit, !checked),
      borderRadius: const BorderRadius.all(HarborShapes.xs),
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              key: ValueKey('permission-$id'),
              value: checked,
              onChanged: (value) => _toggle(bit, value ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 2),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _group(String label, List<(String, String, int)> options) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 40,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
        ),
        Expanded(
          child: Wrap(
            children: [
              for (final option in options)
                _check(option.$1, option.$2, option.$3),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mode = widget.section == _PermissionSection.mode;
    return AlertDialog(
      key: ValueKey(mode ? 'entry-permissions-dialog' : 'entry-owner-dialog'),
      title: Text(mode ? '设置权限' : '权限组'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    mode ? Icons.lock_outline_rounded : Icons.badge_outlined,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (mode) ...[
                TextField(
                  key: const ValueKey('permission-octal'),
                  controller: _octal,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: '八进制权限',
                    errorText: _octalError,
                  ),
                  onChanged: _onOctalChanged,
                  onSubmitted: (_) => _submitMode(),
                ),
                const SizedBox(height: 12),
                _group('用户', [
                  ('user-read', '读', 0x100),
                  ('user-write', '写', 0x80),
                  ('user-exec', '执行', 0x40),
                ]),
                _group('组', [
                  ('group-read', '读', 0x20),
                  ('group-write', '写', 0x10),
                  ('group-exec', '执行', 0x8),
                ]),
                _group('其他', [
                  ('other-read', '读', 0x4),
                  ('other-write', '写', 0x2),
                  ('other-exec', '执行', 0x1),
                ]),
                const SizedBox(height: 4),
                Text('特殊位', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                Wrap(
                  children: [
                    _check('setuid', '设置用户 ID', _setUserId),
                    _check('setgid', '设置组 ID', _setGroupId),
                    _check('sticky', '粘滞位', _sticky),
                  ],
                ),
              ] else ...[
                TextField(
                  key: const ValueKey('permission-uid'),
                  controller: _uid,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '用户 ID (UID)',
                    hintText: '未知',
                  ),
                  onChanged: (_) {
                    if (_ownerError != null) {
                      setState(() => _ownerError = null);
                    }
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('permission-gid'),
                  controller: _gid,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '组 ID (GID)',
                    hintText: '未知',
                  ),
                  onChanged: (_) {
                    if (_ownerError != null) {
                      setState(() => _ownerError = null);
                    }
                  },
                  onSubmitted: (_) => _submitOwner(),
                ),
                if (_ownerError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _ownerError!,
                    key: const ValueKey('permission-owner-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancel-entry-permissions'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-entry-permissions'),
          onPressed: mode ? _submitMode : _submitOwner,
          child: const Text('应用'),
        ),
      ],
    );
  }
}
