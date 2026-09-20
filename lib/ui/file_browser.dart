import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../data/local_transfer.dart';
import '../data/ssh_connection.dart';
import '../domain/remote_file.dart';
import 'remote_file_tile.dart';
import 'theme.dart';

class FileBrowser extends StatefulWidget {
  const FileBrowser({
    super.key,
    required this.session,
    this.local = const NativeLocalTransfer(),
  });
  final SshConnection session;
  final LocalTransfer local;
  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  late final RemoteFileSystem _files = widget.session.files;
  final _pathInput = TextEditingController(text: '~');
  String _path = '~', _requestedPath = '~', _query = '';
  List<RemoteFile> _entries = [];
  bool _loading = true, _showHidden = false, _busy = false;
  bool _leaveAfterTransfer = false;
  String? _error, _message;
  bool _messageError = false;
  int _generation = 0, _transferred = 0;
  int? _total;
  String _transferName = '';
  TransferCancellation? _cancellation;
  DateTime? _lastProgress;
  bool get _connected => widget.session.status == ConnectionStatus.connected;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
    unawaited(_browse('~'));
  }

  void _sessionChanged() {
    if (!_connected) {
      _cancellation?.cancel();
      _generation++;
      _loading = false;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _generation++;
    _cancellation?.cancel();
    widget.session.removeListener(_sessionChanged);
    _pathInput.dispose();
    super.dispose();
  }

  Future<void> _browse(String path) async {
    if (!_connected) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _requestedPath = path;
    });
    try {
      final directory = await _files.browse(path);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (_path != directory.path) _query = '';
        _path = directory.path;
        _pathInput.text = _path;
        _entries = directory.entries;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = _errorLabel(error);
          _pathInput.text = _path;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _errorLabel(Object error) {
    if (!_connected) return 'SSH 已断开，请返回终端重新连接';
    if (error is TransferCancelled) return '传输已取消';
    if (error is TimeoutException) return '服务器响应超时，请重试';
    if (error is SftpStatusError) {
      if (error.code == 2) return '文件或目录不存在';
      if (error.code == 3) return '没有访问权限';
      if (error.code == 8) return '服务器不支持此 SFTP 操作';
      return '文件操作失败，请检查权限或是否存在同名文件';
    }
    if (error is SftpError) return '无法访问 SFTP，请检查服务器是否启用文件传输';
    return error.toString().replaceFirst(
      RegExp(r'^(Exception|Bad state|FileSystemException):\s*'),
      '',
    );
  }

  void _progress(int bytes) {
    if (!mounted) return;
    _transferred = bytes;
    final now = DateTime.now();
    if (_lastProgress == null ||
        now.difference(_lastProgress!).inMilliseconds >= 80) {
      _lastProgress = now;
      setState(() {});
    }
  }

  Future<void> _transfer(
    Future<String?> Function(TransferCancellation) action,
  ) async {
    if (_busy || !_connected) return;
    final cancellation = TransferCancellation();
    setState(() {
      _busy = true;
      _cancellation = cancellation;
      _transferName = '选择文件';
      _transferred = 0;
      _total = null;
      _message = null;
      _lastProgress = null;
    });
    try {
      final message = await action(cancellation);
      if (mounted) {
        setState(() {
          _message = message;
          _messageError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _errorLabel(error);
          _messageError = error is! TransferCancelled;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancellation = null;
        });
        if (_leaveAfterTransfer) {
          Navigator.of(context).pop();
        } else if (_connected) {
          await _browse(_path);
        }
      }
    }
  }

  Future<void> _upload() => _transfer((cancellation) async {
    final directory = _path;
    final uploads = await widget.local.pickUploads();
    cancellation.check();
    var completed = 0;
    for (final upload in uploads) {
      cancellation.check();
      final target = remoteChild(directory, upload.name);
      // Give a clear conflict message before opening a local file. The SFTP
      // exclusive create remains the final protection against a stale listing.
      if (_entries.any((entry) => entry.name == upload.name)) {
        throw StateError(
          '「${upload.name}」已存在，请重命名本地文件后上传${completed > 0 ? '（已完成 $completed 个文件）' : ''}',
        );
      }
      if (!mounted) throw TransferCancelled();
      setState(() {
        _transferName = '上传 ${upload.name}';
        _total = upload.size;
        _transferred = 0;
      });
      try {
        await _files.upload(
          target,
          upload.openRead(),
          cancellation: cancellation,
          onProgress: _progress,
        );
      } catch (error) {
        if (error is TransferCancelled) rethrow;
        throw StateError(
          '${_errorLabel(error)}${completed > 0 ? '（已完成 $completed 个文件）' : ''}',
        );
      }
      completed++;
    }
    return completed == 0 ? null : '已上传 $completed 个文件';
  });

  Future<void> _download(RemoteFile file) => _transfer((cancellation) async {
    final target = await widget.local.pickDownload(file.name);
    if (target == null) return null;
    var complete = false;
    try {
      cancellation.check();
      if (!mounted) throw TransferCancelled();
      setState(() {
        _transferName = '下载 ${file.name}';
        _total = file.size;
        _transferred = 0;
      });
      await _files.download(
        file.path,
        target.write,
        cancellation: cancellation,
        onProgress: _progress,
      );
      cancellation.check();
      await target.finish();
      complete = true;
      return '已下载 ${file.name}';
    } finally {
      if (!complete) {
        try {
          await target.abort();
        } catch (_) {}
      }
    }
  });

  Future<void> _leave() async {
    if (!_busy) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消传输并返回？'),
        content: const Text('当前文件尚未传输完成'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续传输'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消传输'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      if (!_busy) {
        Navigator.of(context).pop();
        return;
      }
      _leaveAfterTransfer = true;
      _cancellation?.cancel();
      // Keep the route alive until file handles have been cleaned up.
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final usable = _connected && !_busy && !_loading;
    final entries = _entries
        .where(
          (entry) =>
              (_showHidden || !entry.name.startsWith('.')) &&
              entry.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: colors.surface,
        appBar: AppBar(
          leading: IconButton(
            onPressed: _leave,
            icon: const Icon(Icons.arrow_back_rounded, semanticLabel: '返回终端'),
          ),
          title: Text(
            '文件 · ${widget.session.host.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonalIcon(
                onPressed: usable && _error == null ? _upload : null,
                icon: const Icon(Icons.upload_rounded, size: 20),
                label: const Text('上传'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: usable && _path != '/'
                          ? () => _browse(remoteParent(_path))
                          : null,
                      icon: const Icon(
                        Icons.arrow_upward_rounded,
                        semanticLabel: '上级目录',
                      ),
                    ),
                    IconButton(
                      onPressed: usable ? () => _browse('~') : null,
                      icon: const Icon(
                        Icons.home_outlined,
                        semanticLabel: '主目录',
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _pathInput,
                        enabled: !_busy && _connected,
                        textInputAction: TextInputAction.go,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '远程路径',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: (value) {
                          if (value.trim().isNotEmpty) _browse(value);
                        },
                      ),
                    ),
                    IconButton(
                      onPressed: usable ? () => _browse(_path) : null,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        semanticLabel: '刷新目录',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('filter-$_path'),
                        onChanged: (value) => setState(() => _query = value),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '筛选文件',
                          prefixIcon: Icon(Icons.search_rounded, size: 20),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      isSelected: _showHidden,
                      onPressed: () =>
                          setState(() => _showHidden = !_showHidden),
                      icon: const Icon(
                        Icons.visibility_off_outlined,
                        semanticLabel: '显示隐藏文件',
                      ),
                      selectedIcon: const Icon(
                        Icons.visibility_outlined,
                        semanticLabel: '隐藏隐藏文件',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '${entries.length} 项',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!_connected) _notice('SSH 已断开，请返回终端重新连接', true),
                if (_message != null) _notice(_message!, _messageError),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.folder_off_outlined,
                                  size: 40,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(height: 12),
                                Text(_error!, textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: _connected
                                      ? () => _browse(_requestedPath)
                                      : null,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : entries.isEmpty
                      ? Center(
                          child: Text(
                            _query.isNotEmpty ? '没有匹配的文件' : '此目录没有可显示的文件',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          key: ValueKey('files-$_path'),
                          itemCount: entries.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: HarborShapes.listGap),
                          itemBuilder: (_, index) => RemoteFileTile(
                            key: ValueKey(entries[index].path),
                            file: entries[index],
                            enabled: usable,
                            slot: HarborShapes.listSlot(index, entries.length),
                            onOpen: () => _browse(entries[index].path),
                            onDownload: () => _download(entries[index]),
                          ),
                        ),
                ),
                if (_busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Material(
                      color: colors.secondaryContainer,
                      shape: HarborShapes.superellipse(),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _cancellation?.cancelled == true
                                            ? '正在取消传输'
                                            : _transferName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${fileSizeLabel(_transferred)}${_total == null ? '' : ' / ${fileSizeLabel(_total)}'}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: _cancellation?.cancelled == true
                                      ? null
                                      : () => setState(
                                          () => _cancellation?.cancel(),
                                        ),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    semanticLabel: '取消传输',
                                  ),
                                ),
                              ],
                            ),
                            LinearProgressIndicator(
                              value: _total != null && _total! > 0
                                  ? (_transferred / _total!).clamp(0, 1)
                                  : null,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice(String text, bool error) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: error ? colors.errorContainer : colors.secondaryContainer,
        shape: HarborShapes.superellipse(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                error
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 20,
                color: error
                    ? colors.onErrorContainer
                    : colors.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: error
                        ? colors.onErrorContainer
                        : colors.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FileBrowserButton extends StatelessWidget {
  const FileBrowserButton({
    super.key,
    required this.session,
    this.onReturn,
    this.onOpen,
  });
  final SshConnection session;
  final VoidCallback? onReturn;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('open-sftp'),
    onPressed: session.status == ConnectionStatus.connected
        ? () async {
            FocusManager.instance.primaryFocus?.unfocus();
            if (onOpen != null) {
              onOpen!();
              return;
            }
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FileBrowser(session: session),
              ),
            );
            if (context.mounted) onReturn?.call();
          }
        : null,
    icon: const Icon(Icons.folder_open_rounded, semanticLabel: 'SFTP 文件'),
  );
}
