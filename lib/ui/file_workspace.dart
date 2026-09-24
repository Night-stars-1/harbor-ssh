import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../data/ssh_connection.dart';
import '../domain/host.dart';
import '../domain/remote_file.dart';
import 'file_workspace_model.dart';
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
  });
  final FileWorkspaceModel model;
  final List<Host> hosts;
  final List<SshConnection> sessions;
  final Future<SshConnection?> Function(Host) onConnect;
  final bool showTitle;
  final bool initializeLocal;
  @override
  State<FileWorkspace> createState() => _FileWorkspaceState();
}

class _FileWorkspaceState extends State<FileWorkspace> {
  bool _adding = false;
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
                                onPressed: model.locked(item)
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
    position: PopupMenuPosition.under,
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    shape: HarborShapes.superellipse(),
    constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
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
        const _FileMenuItem(
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
          _FileMenuItem(
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
                        Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
          if (_adding) const LinearProgressIndicator(minHeight: 2),
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
    return Padding(
      padding: EdgeInsets.fromLTRB(
        side == 0 ? 8 : 0,
        8,
        side == 1 || unified ? 8 : 0,
        8,
      ),
      child: DragTarget<FileDragData>(
        key: ValueKey('file-drop-panel-$side'),
        onWillAcceptWithDetails: (details) => model.canDrop(details.data, tab),
        onAcceptWithDetails: (details) {
          if (tab != null) {
            unawaited(_dropWithConfirmation(details.data, tab));
          }
        },
        builder: (context, candidates, rejected) => Material(
          key: ValueKey('file-panel-$side'),
          color: candidates.isNotEmpty
              ? colors.secondaryContainer.withValues(alpha: .4)
              : colors.surfaceContainerLow,
          shape: HarborShapes.superellipse().copyWith(
            side: BorderSide(
              color: candidates.isNotEmpty
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
    );
  }

  Future<List<RemoteFile>?> _confirmOverwrite(
    FileDragData data,
    FileLocationTab target,
  ) async {
    final targetPath = target.path;
    final conflicts = model.conflicts(data, target);
    if (conflicts.isEmpty) return const [];
    final confirmed = await showDialog<bool>(
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

  Widget _browserToolbar(FileLocationTab tab, bool enabled) {
    final searching = _searching.contains(tab.id) || tab.query.isNotEmpty;
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final extent = touch ? 48.0 : 40.0;
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
    final enabled = !tab.loading && tab.connected && !model.locked(tab);
    final entries = tab.visibleEntries;
    final copying = tab.selected.isNotEmpty;
    final showAction = clipboardMode && (copying || model.clipboard != null);
    final content = Column(
      children: [
        _browserToolbar(tab, enabled),
        Expanded(
          child: tab.loading
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
                            onPressed: tab.connected && !model.locked(tab)
                                ? () => tab.browse()
                                : null,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : entries.isEmpty
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
        ),
        Padding(
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
        ),
      ],
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

  Future<void> _fileMenu(
    FileLocationTab tab,
    RemoteFile file,
    Offset position,
  ) async {
    if (!tab.selected.contains(file.path)) tab.select(file);
    final data = model.dragData(tab, file);
    if (!model.canDelete(data)) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final menuWidth = (overlay.size.width - 16).clamp(0.0, 240.0);
    final menuLeft = (point.dx + 4).clamp(
      8.0,
      overlay.size.width - menuWidth - 8,
    );
    final colors = Theme.of(context).colorScheme;
    final action = await showMenu<Object>(
      context: context,
      constraints: BoxConstraints.tightFor(width: menuWidth),
      position: RelativeRect.fromLTRB(
        menuLeft,
        point.dy,
        overlay.size.width - menuLeft - menuWidth,
        0,
      ),
      color: colors.surfaceContainerHigh,
      elevation: 0,
      shape: HarborShapes.superellipse(),
      items: [
        _FileMenuItem(
          key: const ValueKey('delete-selected-files'),
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 20, color: colors.error),
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
    if (action != 'delete' || !mounted || !model.canDelete(data)) return;
    final confirmed = await showDialog<bool>(
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
            onSecondaryTapUp: enabled && !model.busy && !file.isDirectory
                ? (details) => _fileMenu(tab, file, details.globalPosition)
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
      if (file.isDirectory) return row;
      return GestureDetector(
        onLongPressStart: (details) =>
            _fileMenu(tab, file, details.globalPosition),
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
        ? '${model.transfer!.cancelled ? '正在取消 · ' : ''}${model.transferName}'
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
                            if (transferring)
                              Text(
                                '${fileSizeLabel(model.transferred)}${model.total != null ? ' / ${fileSizeLabel(model.total)}' : ''}${progress != null ? ' · ${(progress * 100).round()}%' : ''}',
                                key: const ValueKey('file-transfer-progress'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
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
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            semanticLabel: '取消传输',
                          ),
                        )
                      else if (!model.busy && model.message != null)
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

class _FileMenuItem extends PopupMenuItem<Object> {
  const _FileMenuItem({super.key, required super.value, required super.child});

  @override
  PopupMenuItemState<Object, _FileMenuItem> createState() =>
      _FileMenuItemState();
}

class _FileMenuItemState extends PopupMenuItemState<Object, _FileMenuItem> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = _hovered || _focused;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: handleTap,
        onHover: (value) => setState(() => _hovered = value),
        onFocusChange: (value) => setState(() => _focused = value),
        borderRadius: const BorderRadius.all(HarborShapes.sm),
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    colors.primary.withValues(alpha: .12),
                    colors.surfaceContainerHigh,
                  )
                : Colors.transparent,
            borderRadius: const BorderRadius.all(HarborShapes.sm),
          ),
          child: IconTheme.merge(
            data: IconThemeData(
              color: selected ? colors.primary : colors.onSurfaceVariant,
            ),
            child: DefaultTextStyle(
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w500,
              ),
              child: widget.child!,
            ),
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
