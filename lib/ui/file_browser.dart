import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../data/local_transfer.dart';
import '../data/picked_transfer.dart';
import '../data/ssh_connection.dart';
import '../domain/remote_file.dart';
import 'expressive_widgets.dart';
import 'remote_file_tile.dart';
import 'remote_text_editor_dialog.dart';
import 'theme.dart';
import 'transfer_speed.dart';

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
  static final _pendingBySession = Expando<PickedTransfer>();
  PickedTransfer? get _pending => _pendingBySession[widget.session];
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
  final _speed = TransferSpeed();
  int _speedOffset = 0;
  bool get _connected => widget.session.status == ConnectionStatus.connected;
  String get _endpoint =>
      '${widget.session.host.endpoint}\x00${widget.session.host.username}\x00${widget.session.host.jumpHostId}';

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
    _speed.addListener(_speedChanged);
    if (_pending != null) {
      _message = '传输已暂停 · 可继续传输';
      _transferName = _pending!.name;
      _transferred = _pending!.transferred;
      _total = _pending!.total;
    }
    unawaited(_browse('~'));
  }

  void _speedChanged() {
    if (mounted) setState(() {});
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
    _speed.removeListener(_speedChanged);
    _speed.dispose();
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
    _speed.update(bytes - _speedOffset);
    final now = DateTime.now();
    if (_lastProgress == null ||
        now.difference(_lastProgress!).inMilliseconds >= 80) {
      _lastProgress = bytes == 0 ? null : now;
      setState(() {});
    }
  }

  Future<void> _transfer(
    Future<String?> Function(TransferCancellation) action, {
    bool requireConnection = true,
  }) async {
    if (_busy || (requireConnection && !_connected)) return;
    final cancellation = TransferCancellation();
    setState(() {
      _busy = true;
      _cancellation = cancellation;
      _transferName = '选择文件';
      _transferred = 0;
      _total = null;
      _message = null;
      _lastProgress = null;
      _speed.reset();
      _speedOffset = 0;
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
          _message = _pending?.discarding == true
              ? '缓存清理失败，请再次放弃传输：${_errorLabel(error)}'
              : _pending == null
              ? _errorLabel(error)
              : error is TransferCancelled
              ? '传输已暂停 · 可继续传输'
              : '${_errorLabel(error)} · 已保留断点，可继续传输';
          _messageError = error is! TransferCancelled;
        });
      }
    } finally {
      _speed.stop();
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

  Future<String?> _runPending(TransferCancellation cancellation) async {
    final pending = _pending!;
    if (pending.endpoint != _endpoint) {
      throw StateError('主机已变化，请连接原来的主机后继续传输');
    }
    await pending.run(
      _files as ResumableFileSystem,
      cancellation,
      picker: widget.local,
      onFile: (name, total, offset) {
        if (!mounted) throw TransferCancelled();
        setState(() {
          _transferName = name;
          _total = total;
          _transferred = offset;
          _speedOffset = offset;
          _lastProgress = null;
          _speed.start();
        });
      },
      onProgress: (bytes) {
        _total = pending.total;
        _progress(bytes);
      },
    );
    _pendingBySession[widget.session] = null;
    return pending.download == null
        ? '已上传 ${pending.completed} 个文件'
        : '已下载 ${pending.download!.name}';
  }

  Future<void> _resume() => _transfer(_runPending);

  Future<void> _discard() => _transfer((cancellation) async {
    if (_pending!.download == null && _pending!.endpoint != _endpoint) {
      throw StateError('请连接原来的目标主机后清理传输缓存');
    }
    await _pending!.discard(_files as ResumableFileSystem);
    _pendingBySession[widget.session] = null;
    return '已放弃传输并清理缓存';
  }, requireConnection: false);

  Future<void> _upload() => _transfer((cancellation) async {
    if (_pending != null) return '请先继续或放弃当前传输';
    final directory = _path;
    final uploads = await widget.local.pickUploads();
    cancellation.check();
    if (_files is ResumableFileSystem && uploads.isNotEmpty) {
      _pendingBySession[widget.session] = await PickedTransfer.upload(
        uploads,
        directory,
        endpoint: _endpoint,
      );
      return _runPending(cancellation);
    }
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
        _lastProgress = null;
        _speed.start();
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
    if (_pending != null) return '请先继续或放弃当前传输';
    if (_files is ResumableFileSystem) {
      _pendingBySession[widget.session] = await PickedTransfer.downloading(
        file,
        endpoint: _endpoint,
      );
      return _runPending(cancellation);
    }
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
        _lastProgress = null;
        _speed.start();
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

  /// Opens the remote text editor for a regular file. The directory listing is
  /// only refreshed after a successful save, so a cancelled or failed edit
  /// leaves the current view untouched.
  Future<void> _edit(RemoteFile file) async {
    if (_busy || !_connected) return;
    final saved = await showRemoteTextEditor(
      context,
      files: _files,
      file: file,
    );
    if (saved && mounted && _connected) await _browse(_path);
  }

  Future<void> _leave() async {
    if (!_busy) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_pending != null ? '暂停传输并返回？' : '取消传输并返回？'),
        content: Text(_pending != null ? '重新连接后返回文件页面，即可继续传输' : '当前文件尚未传输完成'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续传输'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_pending != null ? '暂停并返回' : '取消传输'),
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
    final usable = _connected && !_busy && !_loading && _pending == null;
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
                            onEdit: () => _edit(entries[index]),
                          ),
                        ),
                ),
                if (_busy || _pending != null)
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
                                            ? (_pending != null
                                                  ? '正在暂停传输'
                                                  : '正在取消传输')
                                            : _transferName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${fileSizeLabel(_transferred)}${_total == null ? '' : ' / ${fileSizeLabel(_total)}'}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _speed.label,
                                            key: const ValueKey(
                                              'file-browser-transfer-speed',
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (_busy)
                                  IconButton(
                                    onPressed: _cancellation?.cancelled == true
                                        ? null
                                        : () => setState(
                                            () => _cancellation?.cancel(),
                                          ),
                                    tooltip: _pending != null ? '暂停传输' : '取消传输',
                                    icon: Icon(
                                      _pending != null
                                          ? Icons.pause_rounded
                                          : Icons.close_rounded,
                                      semanticLabel: _pending != null
                                          ? '暂停传输'
                                          : '取消传输',
                                    ),
                                  ),
                                if (!_busy && _pending != null) ...[
                                  IconButton(
                                    key: const ValueKey(
                                      'resume-picked-transfer',
                                    ),
                                    tooltip: '继续传输',
                                    onPressed:
                                        _connected && !_pending!.discarding
                                        ? _resume
                                        : null,
                                    icon: const Icon(
                                      Icons.play_arrow_rounded,
                                      semanticLabel: '继续传输',
                                    ),
                                  ),
                                  IconButton(
                                    key: const ValueKey(
                                      'discard-picked-transfer',
                                    ),
                                    tooltip: '放弃传输并清理缓存',
                                    onPressed:
                                        (_connected ||
                                            _pending!.download != null)
                                        ? _discard
                                        : null,
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      semanticLabel: '放弃传输',
                                    ),
                                  ),
                                ],
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
