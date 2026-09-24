import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/file_copy.dart';
import '../data/local_files.dart';
import '../data/ssh_connection.dart';
import '../domain/remote_file.dart';

class FileLocationTab extends ChangeNotifier {
  FileLocationTab({
    required this.id,
    required this.name,
    required this.files,
    this.isLocal = false,
    this.initialPath = '~',
    this.session,
    this.ownsSession = false,
  }) {
    session?.addListener(_connectionChanged);
  }
  final String id, name, initialPath;
  final RemoteFileSystem files;
  final bool isLocal, ownsSession;
  final SshConnection? session;
  String path = '~', query = '';
  List<RemoteFile> entries = [];
  final Set<String> selected = {};
  String? _selectionAnchor;
  bool loading = false, showHidden = false, _disposed = false;
  String? error;
  int _request = 0;
  bool get connected =>
      session == null || session!.status == ConnectionStatus.connected;
  List<RemoteFile> get visibleEntries => entries
      .where(
        (entry) =>
            (showHidden || !entry.name.startsWith('.')) &&
            entry.name.toLowerCase().contains(query.toLowerCase()),
      )
      .toList();
  String? get parent {
    if (path == '~' ||
        path == '/' ||
        (isLocal && RegExp(r'^[A-Za-z]:/?$').hasMatch(path))) {
      return null;
    }
    final result = remoteParent(path);
    return isLocal && RegExp(r'^[A-Za-z]:$').hasMatch(result)
        ? '$result/'
        : result;
  }

  Future<void> browse([String? next]) async {
    if (_disposed) return;
    final request = ++_request;
    final target = next ?? (path == '~' ? initialPath : path);
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (!connected) throw StateError('连接已断开，请重新添加 SFTP 标签');
      final directory = await files.browse(target);
      if (_disposed || request != _request) return;
      if (path != directory.path) {
        query = '';
        selected.clear();
        _selectionAnchor = null;
      }
      path = directory.path;
      entries = directory.entries;
      selected.removeWhere(
        (path) => !entries.any((entry) => entry.path == path),
      );
      if (!entries.any((entry) => entry.path == _selectionAnchor)) {
        _selectionAnchor = null;
      }
    } catch (e) {
      if (!_disposed && request == _request) error = fileError(e);
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void filter(String text) {
    query = text;
    selected.clear();
    _selectionAnchor = null;
    notifyListeners();
  }

  void toggleHidden() {
    showHidden = !showHidden;
    selected.clear();
    _selectionAnchor = null;
    notifyListeners();
  }

  void toggle(RemoteFile file) {
    if (file.isDirectory) return;
    if (!selected.add(file.path)) selected.remove(file.path);
    _selectionAnchor = selected.contains(file.path) ? file.path : null;
    notifyListeners();
  }

  void select(
    RemoteFile file, {
    bool toggleSelection = false,
    bool range = false,
  }) {
    if (file.isDirectory) return;
    if (range && _selectionAnchor != null) {
      _selectRange(_selectionAnchor!, file.path, additive: toggleSelection);
      notifyListeners();
    } else if (toggleSelection) {
      toggle(file);
    } else {
      selected
        ..clear()
        ..add(file.path);
      _selectionAnchor = file.path;
      notifyListeners();
    }
  }

  bool willDeselectOnMobile(RemoteFile file) =>
      selected.contains(file.path) && selected.length != 2;

  void selectOnMobile(RemoteFile file) {
    if (file.isDirectory) return;
    if (selected.length == 2 && selected.contains(file.path)) {
      final endpoints = selected.toList();
      _selectRange(endpoints.first, endpoints.last, additive: true);
      notifyListeners();
    } else {
      toggle(file);
    }
  }

  void _selectRange(String start, String end, {required bool additive}) {
    final visible = visibleEntries;
    final first = visible.indexWhere((entry) => entry.path == start);
    final last = visible.indexWhere((entry) => entry.path == end);
    if (first < 0 || last < 0) return;
    if (!additive) selected.clear();
    for (
      var i = first < last ? first : last;
      i <= (first > last ? first : last);
      i++
    ) {
      if (!visible[i].isDirectory) selected.add(visible[i].path);
    }
  }

  void clearSelection() {
    selected.clear();
    _selectionAnchor = null;
    notifyListeners();
  }

  void _connectionChanged() {
    if (_disposed) return;
    if (!connected) {
      _request++;
      loading = false;
      error = '连接已断开，请重新添加 SFTP 标签';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    session?.removeListener(_connectionChanged);
    if (ownsSession) session?.dispose();
    super.dispose();
  }
}

class FilePaneModel {
  final List<FileLocationTab> tabs = [];
  String? activeId;
  FileLocationTab? get active =>
      tabs.where((tab) => tab.id == activeId).firstOrNull;
}

class FileDragData {
  FileDragData(this.source, Iterable<RemoteFile> files)
    : files = List.unmodifiable(files),
      sourceDirectory = source.path;
  final FileLocationTab source;
  final List<RemoteFile> files;
  final String sourceDirectory;
}

class FileWorkspaceModel extends ChangeNotifier {
  FileWorkspaceModel({this.localHome});

  final RemoteFileSystem? Function()? localHome;
  String defaultLocalPath = '';
  String get localTabName => defaultLocalPath.isEmpty
      ? '本地 · 用户目录'
      : '本地 · ${defaultLocalPath.replaceAll('\\', '/').split('/').where((part) => part.isNotEmpty).lastOrNull ?? defaultLocalPath}';

  RemoteFileSystem? _configuredLocalFiles() => defaultLocalPath.isNotEmpty
      ? LocalFiles(defaultLocalPath)
      : (localHome ?? LocalFiles.userHome)();

  Future<FileLocationTab?> addLocal(int side) async {
    final files = _configuredLocalFiles() ?? await LocalFiles.defaultHome();
    if (_disposed) return null;
    return add(side, name: localTabName, files: files, isLocal: true);
  }

  bool _defaultLocalInitialized = false;
  bool get defaultLocalInitialized => _defaultLocalInitialized;

  void initializeDefaultLocal() {
    if (_disposed || _defaultLocalInitialized) return;
    _defaultLocalInitialized = true;
    if (panes[0].tabs.isNotEmpty) return;
    final files = _configuredLocalFiles();
    if (files == null) return;
    final previousActive = _activeTabId;
    add(0, name: localTabName, files: files, isLocal: true);
    if (previousActive != null) _activeTabId = previousActive;
  }

  final panes = [FilePaneModel(), FilePaneModel()];
  String? _activeTabId;
  FileDragData? clipboard;
  List<FileLocationTab> get tabs => [for (final pane in panes) ...pane.tabs];
  FileLocationTab? get activeTab =>
      tabs.where((tab) => tab.id == _activeTabId).firstOrNull ??
      tabs.firstOrNull;
  int sideOf(FileLocationTab tab) =>
      panes.indexWhere((pane) => pane.tabs.contains(tab));
  int _sequence = 0;
  bool _disposed = false;
  double split = .5;
  TransferCancellation? transfer;
  String? transferSourceId, transferDestinationId;
  String? message;
  bool failed = false;
  String transferName = '';
  int transferred = 0;
  int? total;
  DateTime? _lastProgress;
  String? _deletingTabId;
  bool get deleting => _deletingTabId != null;
  bool get busy => transfer != null || deleting;
  bool locked(FileLocationTab tab) =>
      tab.id == _deletingTabId ||
      (busy && (tab.id == transferSourceId || tab.id == transferDestinationId));

  bool canDelete(FileDragData data) =>
      !_disposed &&
      !busy &&
      tabs.contains(data.source) &&
      data.source.connected &&
      !data.source.loading &&
      data.source.error == null &&
      data.files.isNotEmpty &&
      data.files.every((file) => !file.isDirectory);

  Future<void> deleteFiles(FileDragData data) async {
    if (!canDelete(data)) return;
    final source = data.source;
    _deletingTabId = source.id;
    failed = false;
    var completed = 0;
    message = '正在删除 0/${data.files.length} 个文件';
    _notify();
    try {
      for (final file in data.files) {
        if (_disposed) return;
        await source.files.deleteFile(file.path);
        completed++;
        source.selected.remove(file.path);
        final cached = clipboard;
        if (cached != null &&
            cached.files.any((item) => item.path == file.path) &&
            (cached.source == source ||
                identical(cached.source.files, source.files) ||
                (cached.source.isLocal && source.isLocal) ||
                (source.session != null &&
                    cached.source.session?.host.id ==
                        source.session!.host.id))) {
          clipboard = null;
        }
        message = '正在删除 $completed/${data.files.length} 个文件';
        _notify();
      }
      message = '已删除 $completed 个文件';
    } catch (error) {
      failed = true;
      message =
          '删除失败：${fileError(error)} · 已删除 $completed/${data.files.length} 个文件';
    } finally {
      if (!_disposed) await source.browse();
      _deletingTabId = null;
      _notify();
    }
  }

  FileLocationTab add(
    int side, {
    required String name,
    required RemoteFileSystem files,
    bool isLocal = false,
    String initialPath = '~',
    SshConnection? session,
    bool ownsSession = false,
  }) {
    final tab = FileLocationTab(
      id: 'files-${_sequence++}',
      name: name,
      files: files,
      isLocal: isLocal,
      initialPath: initialPath,
      session: session,
      ownsSession: ownsSession,
    );
    panes[side].tabs.add(tab);
    panes[side].activeId = tab.id;
    _activeTabId = tab.id;
    tab.addListener(_notify);
    _notify();
    unawaited(tab.browse());
    return tab;
  }

  void activate(int side, String id) {
    panes[side].activeId = id;
    _activeTabId = id;
    _notify();
  }

  void close(int side, FileLocationTab tab) {
    if (locked(tab)) return;
    final pane = panes[side];
    final index = pane.tabs.indexOf(tab);
    if (index < 0) return;
    pane.tabs.removeAt(index);
    if (clipboard?.source == tab) clipboard = null;
    if (pane.activeId == tab.id) {
      pane.activeId = pane.tabs.isEmpty
          ? null
          : pane.tabs[index.clamp(0, pane.tabs.length - 1)].id;
    }
    tab.removeListener(_notify);
    if (_activeTabId == tab.id) {
      _activeTabId = pane.activeId ?? tabs.firstOrNull?.id;
    }
    tab.dispose();
    _notify();
  }

  void resize(double value) {
    split = value.clamp(.25, .75);
    _notify();
  }

  void cancel() {
    transfer?.cancel();
    _notify();
  }

  void dismissMessage() {
    if (busy) return;
    message = null;
    failed = false;
    _notify();
  }

  bool canCopy(int side) {
    final source = panes[side].active, target = panes[1 - side].active;
    return !busy &&
        source != null &&
        target != null &&
        !source.loading &&
        !target.loading &&
        source.connected &&
        target.connected &&
        source.error == null &&
        target.error == null &&
        source.selected.isNotEmpty;
  }

  FileDragData dragData(FileLocationTab source, RemoteFile file) =>
      FileDragData(
        source,
        source.selected.contains(file.path)
            ? source.entries.where(
                (entry) =>
                    source.selected.contains(entry.path) && !entry.isDirectory,
              )
            : [file],
      );

  List<RemoteFile> conflicts(FileDragData data, FileLocationTab target) => [
    for (final existing in target.entries)
      if (data.files.any(
        (source) => _sameName(source.name, existing.name, target.isLocal),
      ))
        existing,
  ];

  bool _sameName(String left, String right, bool local) =>
      local && Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;

  bool conflictsMatch(
    FileDragData data,
    FileLocationTab target,
    List<RemoteFile> expected,
  ) {
    final current = conflicts(data, target);
    if (current.length != expected.length) return false;
    return expected.every(
      (approved) => current.any((item) => _sameEntry(item, approved)),
    );
  }

  bool _sameEntry(RemoteFile left, RemoteFile right) =>
      left.path == right.path &&
      left.name == right.name &&
      left.isDirectory == right.isDirectory &&
      left.isLink == right.isLink &&
      left.size == right.size &&
      left.modified == right.modified;

  String _temporaryName(String kind) {
    final random = Random.secure();
    final token = List.generate(
      4,
      (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '.harbor-$kind-$token';
  }

  bool canDrop(FileDragData data, FileLocationTab? target) {
    bool contains(FileLocationTab tab) =>
        panes.any((pane) => pane.tabs.contains(tab));
    return !_disposed &&
        !busy &&
        target != null &&
        !_sameDirectory(data.source, data.sourceDirectory, target) &&
        contains(data.source) &&
        contains(target) &&
        data.source.connected &&
        target.connected &&
        !data.source.loading &&
        !target.loading &&
        data.source.error == null &&
        target.error == null &&
        data.files.isNotEmpty &&
        data.files.every((file) => !file.isLink) &&
        !_copiesIntoItself(data, target);
  }

  bool _sameFileSystem(FileLocationTab source, FileLocationTab target) =>
      identical(source.files, target.files) ||
      (source.isLocal && target.isLocal) ||
      (_sftpIdentity(source) != null &&
          _sftpIdentity(source) == _sftpIdentity(target));

  String? _sftpIdentity(FileLocationTab tab) {
    final host = tab.session?.host;
    if (host == null) return null;
    return '${host.address.toLowerCase()}:${host.port}\x00${host.username}';
  }

  bool _sameDirectory(
    FileLocationTab source,
    String sourceDirectory,
    FileLocationTab target,
  ) =>
      _sameFileSystem(source, target) &&
      _normalizedPath(sourceDirectory, source.isLocal) ==
          _normalizedPath(target.path, target.isLocal);

  bool _copiesIntoItself(FileDragData data, FileLocationTab target) {
    if (!_sameFileSystem(data.source, target)) return false;
    for (final file in data.files.where((item) => item.isDirectory)) {
      final destination = target.files.childPath(target.path, file.name);
      final sourcePath = _normalizedPath(file.path, data.source.isLocal);
      final destinationPath = _normalizedPath(destination, target.isLocal);
      if (destinationPath == sourcePath ||
          destinationPath.startsWith('$sourcePath/')) {
        return true;
      }
    }
    return false;
  }

  String _normalizedPath(String path, bool local) {
    var normalized = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/(?:\.)?$'), '');
    if (normalized.isEmpty) normalized = '/';
    return local && Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<void> copy(int side) async {
    if (!canCopy(side)) return;
    final source = panes[side].active!, target = panes[1 - side].active!;
    final selected = source.entries
        .where(
          (file) => source.selected.contains(file.path) && !file.isDirectory,
        )
        .toList();
    await drop(FileDragData(source, selected), target);
  }

  void copySelection(FileLocationTab source) {
    if (busy || source.loading || !source.connected || source.error != null) {
      return;
    }
    final files = source.entries
        .where(
          (file) => source.selected.contains(file.path) && !file.isDirectory,
        )
        .toList();
    if (files.isEmpty) return;
    clipboard = FileDragData(source, files);
    source.clearSelection();
    _notify();
  }

  bool canPaste(FileLocationTab? target) =>
      clipboard != null && canDrop(clipboard!, target);

  Future<void> paste(
    FileLocationTab target, {
    List<RemoteFile> overwriteConflicts = const [],
  }) async {
    final data = clipboard;
    if (data == null) return;
    if (await drop(data, target, overwriteConflicts: overwriteConflicts)) {
      if (identical(clipboard, data)) clipboard = null;
      _notify();
    }
  }

  Future<bool> drop(
    FileDragData data,
    FileLocationTab target, {
    List<RemoteFile> overwriteConflicts = const [],
  }) async {
    if (!canDrop(data, target)) return false;
    final existingConflicts = conflicts(data, target);
    if (existingConflicts.isNotEmpty && overwriteConflicts.isEmpty) {
      failed = true;
      message = '目标目录存在同名项目';
      _notify();
      return false;
    }
    if (!conflictsMatch(data, target, overwriteConflicts)) {
      failed = true;
      message = '目标目录内容已变化，请重新操作';
      _notify();
      return false;
    }
    final source = data.source;
    final selected = data.files;
    final destinationDirectory = target.path;
    final cancellation = TransferCancellation();
    transfer = cancellation;
    transferSourceId = source.id;
    transferDestinationId = target.id;
    transferName = '准备传输 ${selected.length} 个项目';
    transferred = 0;
    total = null;
    message = null;
    failed = false;
    _notify();
    var completed = 0;
    var success = false;
    var cleanupFailed = false;
    final conflictsByName = {
      for (final conflict in existingConflicts)
        (target.isLocal && Platform.isWindows
                ? conflict.name.toLowerCase()
                : conflict.name):
            conflict,
    };
    try {
      for (final file in selected) {
        cancellation.check();
        transferName = '${file.name} · ${completed + 1}/${selected.length}';
        transferred = 0;
        total = file.isDirectory ? null : file.size;
        _lastProgress = null;
        _notify();
        void progress(int bytes) {
          transferred = bytes;
          final now = DateTime.now();
          if (_lastProgress == null ||
              now.difference(_lastProgress!).inMilliseconds >= 80) {
            _lastProgress = now;
            _notify();
          }
        }

        Future<void> copyTo(String path) async {
          if (file.isDirectory) {
            await copyDirectoryBetween(
              source: source.files,
              destination: target.files,
              sourcePath: file.path,
              destinationPath: path,
              cancellation: cancellation,
              onPrepared: (result) {
                total = result.totalBytes;
                transferName =
                    '${file.name} · ${result.files} 个文件 / ${result.directories} 个目录';
                _notify();
              },
              onProgress: progress,
            );
          } else {
            await copyFileBetween(
              source: source.files,
              destination: target.files,
              sourcePath: file.path,
              destinationPath: path,
              cancellation: cancellation,
              onProgress: progress,
            );
          }
        }

        Future<void> remove(String path, RemoteFile item) =>
            item.isDirectory && !item.isLink
            ? target.files.deleteDirectory(path, recursive: true)
            : target.files.deleteFile(path);

        final destinationPath = target.files.childPath(
          destinationDirectory,
          file.name,
        );
        final key = target.isLocal && Platform.isWindows
            ? file.name.toLowerCase()
            : file.name;
        final conflict = conflictsByName[key];
        if (conflict == null) {
          await copyTo(destinationPath);
        } else {
          final stagedPath = target.files.childPath(
            destinationDirectory,
            _temporaryName('incoming'),
          );
          final backupPath = target.files.childPath(
            destinationDirectory,
            _temporaryName('backup'),
          );
          var backupMoveAttempted = false,
              backupMoved = false,
              published = false;
          try {
            transferName = '准备覆盖 ${file.name}';
            _notify();
            await copyTo(stagedPath);
            cancellation.check();
            final latest = await target.files.browse(destinationDirectory);
            final current = latest.entries
                .where(
                  (entry) => _sameName(entry.name, file.name, target.isLocal),
                )
                .firstOrNull;
            if (current == null || !_sameEntry(current, conflict)) {
              throw StateError('目标目录内容已变化，请重新操作');
            }
            backupMoveAttempted = true;
            await target.files.renameExclusive(conflict.path, backupPath);
            backupMoved = true;
            cancellation.check();
            await target.files.renameExclusive(stagedPath, destinationPath);
            published = true;
            try {
              await remove(backupPath, conflict);
            } catch (_) {
              cleanupFailed = true;
            }
          } catch (error, stack) {
            var restoreFailed = false;
            if (backupMoveAttempted && !published) {
              try {
                await target.files.renameExclusive(backupPath, conflict.path);
              } catch (_) {
                if (backupMoved) restoreFailed = true;
              }
            }
            var stageCleanupFailed = false;
            if (!published) {
              try {
                await remove(stagedPath, file);
              } catch (_) {
                try {
                  final remaining = await target.files.browse(
                    destinationDirectory,
                  );
                  stageCleanupFailed = remaining.entries.any(
                    (entry) => entry.path == stagedPath,
                  );
                } catch (_) {
                  stageCleanupFailed = true;
                }
              }
            }
            if (restoreFailed) {
              throw StateError('覆盖失败，原项目保留在临时备份中');
            }
            if (stageCleanupFailed) {
              throw StateError('传输失败，临时项目清理失败');
            }
            Error.throwWithStackTrace(error, stack);
          }
        }
        completed++;
      }
      message = cleanupFailed
          ? '已传输 $completed 个项目 · 旧版本清理失败'
          : '已传输 $completed 个项目';
      failed = cleanupFailed;
      source.clearSelection();
      success = true;
    } catch (e) {
      failed = e is! TransferCancelled;
      message =
          '${fileError(e)}${completed > 0 ? ' · 已完成 $completed 个项目' : ''}';
    } finally {
      transfer = null;
      transferSourceId = null;
      transferDestinationId = null;
      if (!_disposed) {
        await target.browse();
        _notify();
      }
    }
    return success;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    transfer?.cancel();
    for (final pane in panes) {
      for (final tab in pane.tabs) {
        tab.removeListener(_notify);
        tab.dispose();
      }
    }
    super.dispose();
  }
}

String fileError(Object error) {
  if (error is TransferCancelled) return '传输已取消';
  if (error is TimeoutException) return '服务器响应超时，请重试';
  return error.toString().replaceFirst(
    RegExp(r'^(Exception|Bad state|FileSystemException):\s*'),
    '',
  );
}
