import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:re_editor/re_editor.dart';

import '../data/remote_text_editor.dart';
import '../domain/remote_file.dart';
import 'file_workspace_model.dart' show fileError;
import 'remote_code_highlight.dart';
import 'theme.dart';

/// 打开远程文本编辑器，返回 true 仅表示内容已成功写回远端。
///
/// 取消、读取失败、放弃修改或保存失败都返回 false；保存失败时对话框保持
/// 打开并保留草稿，用户可以直接重试或复制草稿后再关闭。
Future<bool> showRemoteTextEditor(
  BuildContext context, {
  required RemoteFileSystem files,
  required RemoteFile file,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => RemoteTextEditorDialog(files: files, file: file),
  );
  return saved ?? false;
}

/// 远程文本编辑对话框：读取 [file] 的 UTF-8 内容，编辑后经
/// [RemoteTextEditor.save] 原子写回。
class RemoteTextEditorDialog extends StatefulWidget {
  const RemoteTextEditorDialog({
    super.key,
    required this.files,
    required this.file,
  });

  final RemoteFileSystem files;
  final RemoteFile file;

  @override
  State<RemoteTextEditorDialog> createState() => _RemoteTextEditorDialogState();
}

class _RemoteTextEditorDialogState extends State<RemoteTextEditorDialog> {
  late final RemoteTextEditor _editor = RemoteTextEditor(widget.files);

  /// 代码编辑控制器。每次读取成功后按内容自身的换行符重建（见
  /// [_detectLineBreak]），旧控制器在本帧重建完成后释放，避免编辑期间出现
  /// 两个同时存活的控制器。
  CodeLineEditingController _text = CodeLineEditingController();
  final _focus = FocusNode();
  late final SelectionToolbarController _selectionToolbar =
      _RemoteSelectionToolbarController(() => mounted && _ready);

  /// 当前编辑目标。重新载入后远端大小已变化，这里会丢弃过期的 size，
  /// 让保存只依赖服务端的内容比对。
  late RemoteFile _file = widget.file;
  TransferCancellation? _loadToken;
  int _generation = 0;

  String _original = '';
  String _renderedOriginal = '';
  bool _loading = true, _saving = false, _dirty = false;
  String? _loadError, _saveError;

  /// 载入完成时的行集合。光标移动只改选择并复用同一 [CodeLines] 实例，
  /// 用它跳过全文拼接，避免大文件里的每次移动光标都重算整篇文本。
  CodeLines? _loadedLines;

  bool get _busy => _loading || _saving;

  /// 内容读取完成后即可保存。[_dirty] 只用于提示与关闭确认：保存按钮不因
  /// 未修改而禁用，避免调用方在同一帧内编辑后立刻触发时点到旧的禁用按钮。
  bool get _ready => !_busy && _loadError == null;

  @override
  void initState() {
    super.initState();
    _text.addListener(_handleTextChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    // 关闭对话框即取消仍在进行的读取，远端不会被写入。
    _loadToken?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 只在“有无未保存修改”翻转时重建，避免每次按键重建整个对话框。
  void _handleTextChanged() {
    final dirty =
        !_loading &&
        _loadError == null &&
        // 选择变化复用同一行集合实例，先做 O(1) 判断再拼全文。
        !identical(_text.value.codeLines, _loadedLines) &&
        _text.text != _renderedOriginal;
    if (dirty == _dirty || !mounted) return;
    setState(() => _dirty = dirty);
  }

  /// 用新控制器接管编辑内容：换行符不同的文件只能重建控制器，因为
  /// [CodeLineOptions] 不可变。
  void _replaceText(CodeLineEditingController next) {
    next.addListener(_handleTextChanged);
    final previous = _text;
    _text = next;
    _loadedLines = next.codeLines;
    _renderedOriginal = next.text;
    // CodeEditor 在重建时把内部 delegate 换到新控制器，旧控制器要等本帧构建
    // 完成后再释放，否则库仍在向已释放对象解绑监听。
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  Future<void> _load() async {
    _loadToken?.cancel();
    final token = TransferCancellation();
    _loadToken = token;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _loadError = null;
      _saveError = null;
    });
    try {
      final content = await _editor.load(_file, cancellation: token);
      if (!mounted || generation != _generation) return;
      _replaceText(
        CodeLineEditingController.fromText(
          content,
          CodeLineOptions(lineBreak: _detectLineBreak(content)),
        ),
      );
      setState(() {
        _original = content;
        _dirty = false;
        _loading = false;
      });
    } on TransferCancelled {
      // 读取被取消（对话框已关闭或已重新发起读取），丢弃结果即可。
      if (!mounted || generation != _generation) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadError = fileError(error);
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (!_ready) return;
    final draft = _text.text;
    // 控制器会将混合换行规范化；没有实际编辑时不能因此覆盖原文件。
    if (draft == _renderedOriginal) {
      Navigator.of(context).pop(false);
      return;
    }
    _focus.unfocus();
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await _editor.save(_file, _original, draft);
      if (!mounted) return;
      final leftover = _editor.leftoverBackupPath;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      if (leftover != null) {
        messenger.showSnackBar(
          SnackBar(content: Text('已保存，但远端临时备份未能删除：$leftover')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      // 失败时保留草稿与原始内容，用户可以修改后重试或重新载入远端内容。
      setState(() {
        _saving = false;
        _saveError = fileError(error);
      });
    }
  }

  Future<void> _reload() async {
    if (_busy) return;
    if (_dirty && !await _confirmDiscard()) return;
    _file = RemoteFile(name: _file.name, path: _file.path);
    await _load();
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: Text('「${_file.name}」的修改尚未保存，放弃后无法恢复。'),
        actions: [
          TextButton(
            key: const ValueKey('keep-editing-remote-text'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            key: const ValueKey('discard-remote-text'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (_dirty && !await _confirmDiscard()) return;
    if (mounted) Navigator.of(context).pop(false);
  }

  String get _statusLabel {
    if (_loading) return '正在读取…';
    if (_loadError != null) return '读取失败';
    if (_saving) return '正在写入远端…';
    if (_saveError != null) return '保存失败，草稿已保留';
    if (_dirty) return '未保存的修改';
    return '内容与远端一致';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final media = MediaQuery.of(context);
    final compact = media.size.width < 600;
    final inset = compact ? 8.0 : 24.0;
    final height = math.min(
      740.0,
      math.max(
        0.0,
        media.size.height -
            media.padding.vertical -
            media.viewInsets.vertical -
            inset * 2,
      ),
    );

    return PopScope(
      // 所有离开路径（取消、关闭图标、Esc、系统返回）都由 [_requestClose]
      // 处理，它按当前草稿状态决定是否确认，不依赖上一帧的构建结果。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_requestClose());
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
          // 库只在桌面平台注册内部快捷键；移动端没有任何快捷键，Esc 也不会关闭
          // barrierDismissible 为 false 的对话框，这里统一接管为关闭请求。
          const SingleActivator(LogicalKeyboardKey.escape): _requestClose,
        },
        child: Dialog(
          key: const ValueKey('remote-text-dialog'),
          insetPadding: EdgeInsets.all(inset),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 900,
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(theme, colors, compact),
                Divider(height: 1, color: colors.outlineVariant),
                Expanded(child: _body(theme, colors, compact ? 8 : 14)),
                if (_saveError != null)
                  _saveErrorBanner(colors, compact ? 12 : 20),
                Divider(height: 1, color: colors.outlineVariant),
                _footer(theme, colors, compact),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, ColorScheme colors, bool compact) => Padding(
    padding: EdgeInsets.fromLTRB(compact ? 16 : 20, 12, compact ? 8 : 12, 12),
    child: Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: .55),
            borderRadius: const BorderRadius.all(HarborShapes.sm),
          ),
          child: SizedBox.square(
            dimension: 36,
            child: Icon(
              Icons.code_rounded,
              size: 20,
              color: colors.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _languageBadge(colors),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('close-remote-text'),
          onPressed: _saving ? null : _requestClose,
          tooltip: '关闭编辑器',
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  String get _subtitle {
    final size = _file.size;
    final suffix = size == null ? '' : ' · ${fileSizeLabel(size)}';
    return '${_file.path} · UTF-8$suffix';
  }

  /// 头部语言标签：按文件路径推断高亮语言，未知文件显示「纯文本」。
  Widget _languageBadge(ColorScheme colors) => Container(
    key: const ValueKey('remote-text-language'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: colors.secondaryContainer,
      borderRadius: const BorderRadius.all(HarborShapes.xs),
    ),
    child: Text(
      remoteCodeLanguageLabel(_file.path),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: colors.onSecondaryContainer,
      ),
    ),
  );

  Widget _body(ThemeData theme, ColorScheme colors, double inset) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              '正在读取 ${_file.name}…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final error = _loadError;
    if (error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: inset, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 32, color: colors.error),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const ValueKey('retry-load-remote-text'),
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final codeTheme = remoteCodeHighlightTheme(_file.path, theme.brightness);
    // 高亮主题自带代码面板底色，浅深两套主题各自成套；无高亮时退回对话框表面色。
    final rootStyle = codeTheme?.theme['root'];
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 8),
      child: Container(
        decoration: BoxDecoration(
          color: rootStyle?.backgroundColor ?? colors.surfaceContainerLow,
          borderRadius: const BorderRadius.all(HarborShapes.sm),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: CodeEditor(
          key: const ValueKey('remote-text-content'),
          controller: _text,
          focusNode: _focus,
          toolbarController: _selectionToolbar,
          autofocus: true,
          readOnly: _busy,
          wordWrap: false,
          hint: '文件内容为空',
          padding: const EdgeInsets.all(12),
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.all(HarborShapes.sm),
          style: CodeEditorStyle(
            fontSize: 13,
            fontFamily: 'monospace',
            fontHeight: 1.45,
            textColor: rootStyle?.color ?? colors.onSurface,
            hintTextColor: colors.onSurfaceVariant,
            cursorColor: colors.primary,
            codeTheme: codeTheme,
          ),
          indicatorBuilder: (context, controller, chunkController, notifier) =>
              DefaultCodeLineNumber(
                controller: controller,
                notifier: notifier,
                textStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                  color: colors.onSurfaceVariant,
                ),
                focusedTextStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                  color: colors.primary,
                ),
              ),
          leadingDivider: VerticalDivider(
            width: 1,
            thickness: 1,
            color: colors.outlineVariant,
          ),
          // 库内部的 Shortcuts 会先吃掉 Ctrl+S 与 Esc，这里覆盖成对话框原有的
          // 保存 / 关闭请求，键盘行为与按钮保持一致。
          shortcutOverrideActions: {
            CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
              onInvoke: (_) {
                unawaited(_save());
                return null;
              },
            ),
            CodeShortcutEscIntent: CallbackAction<CodeShortcutEscIntent>(
              onInvoke: (_) {
                unawaited(_requestClose());
                return null;
              },
            ),
          },
        ),
      ),
    );
  }

  Widget _saveErrorBanner(ColorScheme colors, double inset) => Padding(
    padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: const BorderRadius.all(HarborShapes.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: colors.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _saveError!,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: colors.onErrorContainer,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('reload-remote-text'),
            onPressed: _busy ? null : _reload,
            child: Text(
              '重新载入',
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _footer(ThemeData theme, ColorScheme colors, bool compact) {
    final statusColor = _saveError != null
        ? colors.error
        : _dirty || _busy
        ? colors.primary
        : colors.onSurfaceVariant;
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _saveError != null
              ? Icons.error_outline_rounded
              : _busy
              ? Icons.sync_rounded
              : _dirty
              ? Icons.edit_outlined
              : Icons.check_circle_outline_rounded,
          size: 16,
          color: statusColor,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            _statusLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
          ),
        ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          key: const ValueKey('cancel-remote-text'),
          onPressed: _saving ? null : _requestClose,
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: '保存（Ctrl+S）',
          child: FilledButton.icon(
            key: const ValueKey('save-remote-text'),
            style: FilledButton.styleFrom(
              minimumSize: Size(0, compact ? 48 : 40),
              padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 16),
            ),
            onPressed: _ready ? _save : null,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_saving ? '正在保存…' : '保存'),
          ),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 20,
        vertical: compact ? 8 : 10,
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Align(alignment: Alignment.centerLeft, child: status),
                const SizedBox(height: 4),
                actions,
              ],
            )
          : Row(
              children: [
                Expanded(child: status),
                actions,
              ],
            ),
    );
  }
}

/// re_editor 不提供默认选区菜单；移动端长按和桌面右键都需要显式提供。
class _RemoteSelectionToolbarController implements SelectionToolbarController {
  _RemoteSelectionToolbarController(this.canEdit);

  final bool Function() canEdit;
  bool _open = false;

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    if (_open) return;
    _open = true;
    unawaited(_show(context, controller, anchors));
  }

  Future<void> _show(
    BuildContext context,
    CodeLineEditingController controller,
    TextSelectionToolbarAnchors anchors,
  ) async {
    try {
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final anchor = anchors.secondaryAnchor ?? anchors.primaryAnchor;
      final point = overlay.globalToLocal(anchor);
      final x = point.dx.clamp(0.0, overlay.size.width);
      final y = point.dy.clamp(0.0, overlay.size.height);
      final action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          x,
          y,
          overlay.size.width - x,
          overlay.size.height - y,
        ),
        items: [
          if (canEdit()) const PopupMenuItem(value: 'cut', child: Text('剪切')),
          const PopupMenuItem(value: 'copy', child: Text('复制')),
          if (canEdit()) const PopupMenuItem(value: 'paste', child: Text('粘贴')),
          const PopupMenuItem(value: 'all', child: Text('全选')),
        ],
      );
      switch (action) {
        case 'cut' when canEdit():
          controller.cut();
        case 'copy':
          await controller.copy();
        case 'paste' when canEdit():
          controller.paste();
        case 'all':
          controller.selectAll();
      }
    } finally {
      _open = false;
    }
  }

  @override
  void hide(BuildContext context) {
    // showMenu 的路由由点选、点击外部或返回键自行关闭。
  }
}

/// 按远端内容自身决定编辑器换行符，避免载入 CRLF/CR 文件后被静默改写。
///
/// 取出现次数最多的换行符；并列时取文件中先出现的那种。库的
/// [CodeLineEditingController] 只能配置单一换行符，混合换行的文件无法逐行
/// 保留，这里至少保证主流换行不被改写。
TextLineBreak _detectLineBreak(String content) {
  final counts = <TextLineBreak, int>{};
  final firstSeen = <TextLineBreak, int>{};
  for (var i = 0; i < content.length; i++) {
    final unit = content.codeUnitAt(i);
    TextLineBreak type;
    if (unit == 0x0A) {
      type = TextLineBreak.lf;
    } else if (unit == 0x0D) {
      if (i + 1 < content.length && content.codeUnitAt(i + 1) == 0x0A) {
        type = TextLineBreak.crlf;
        i++;
      } else {
        type = TextLineBreak.cr;
      }
    } else {
      continue;
    }
    counts.update(type, (count) => count + 1, ifAbsent: () => 1);
    firstSeen.putIfAbsent(type, () => i);
  }
  TextLineBreak? best;
  for (final type in counts.keys) {
    if (best == null) {
      best = type;
      continue;
    }
    final better =
        counts[type]! > counts[best]! ||
        (counts[type] == counts[best] && firstSeen[type]! < firstSeen[best]!);
    if (better) best = type;
  }
  return best ?? TextLineBreak.lf;
}

// ---------------------------------------------------------------------------
// 预览：使用内存 fake，不触达任何原生或网络 API。
// ---------------------------------------------------------------------------

const _previewContent = '''
# Harbor SSH 远程编辑预览
server {
  listen 8080;
  server_name api.example.com;
  root /srv/api;
  client_max_body_size 8m;
}
''';

/// 与 [_PreviewFileSystem.browse] 报告的大小保持一致，预览中的保存才会通过
/// 服务的“远端未被外部修改”校验。
final _previewFile = RemoteFile(
  name: 'nginx.conf',
  path: '/etc/nginx/nginx.conf',
  size: utf8.encode(_previewContent).length,
);

/// 内存 [RemoteFileSystem]：路径到 UTF-8 文本，供预览与设计稿使用。
class _PreviewFileSystem implements RemoteFileSystem {
  _PreviewFileSystem(this._entries);

  final Map<String, String> _entries;

  @override
  String childPath(String directory, String name) =>
      remoteChild(directory, name);

  @override
  Future<RemoteDirectory> browse(String path) async {
    final directory = path.isEmpty ? '/' : path;
    return RemoteDirectory(directory, [
      for (final entry in _entries.entries)
        if (remoteParent(entry.key) == directory)
          RemoteFile(
            name: entry.key.split('/').last,
            path: entry.key,
            size: utf8.encode(entry.value).length,
          ),
    ]);
  }

  @override
  Future<void> download(
    String path,
    Future<void> Function(Uint8List) write, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  }) async {
    final content = _entries[path];
    if (content == null) throw StateError('文件不存在：$path');
    final bytes = utf8.encode(content);
    cancellation.check();
    onProgress(bytes.length);
    await write(Uint8List.fromList(bytes));
  }

  @override
  Future<void> upload(
    String path,
    Stream<Uint8List> source, {
    required TransferCancellation cancellation,
    required void Function(int bytes) onProgress,
  }) async {
    if (_entries.containsKey(path)) throw StateError('目标已存在：$path');
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in source) {
      cancellation.check();
      buffer.add(chunk);
      onProgress(chunk.length);
    }
    _entries[path] = utf8.decode(buffer.takeBytes());
  }

  @override
  Future<void> renameExclusive(String oldPath, String newPath) async {
    if (_entries.containsKey(newPath)) throw StateError('目标已存在：$newPath');
    final content = _entries.remove(oldPath);
    if (content == null) throw StateError('文件不存在：$oldPath');
    _entries[newPath] = content;
  }

  @override
  Future<void> deleteFile(String path) async {
    _entries.remove(path);
  }

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> deleteDirectory(String path, {bool recursive = false}) async {}
}

Widget _previewEditor({Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: harborTheme(brightness: brightness),
      home: Scaffold(
        body: RemoteTextEditorDialog(
          files: _PreviewFileSystem({_previewFile.path: _previewContent}),
          file: _previewFile,
        ),
      ),
    );

@Preview(
  name: 'Remote text editor',
  group: 'Harbor SSH · MD3E',
  size: Size(1060, 800),
)
Widget harborRemoteTextEditorPreview() => _previewEditor();

@Preview(
  name: 'Remote text editor · dark',
  group: 'Harbor SSH · MD3E',
  size: Size(1060, 800),
)
Widget harborRemoteTextEditorDarkPreview() =>
    _previewEditor(brightness: Brightness.dark);

@Preview(
  name: 'Remote text editor · phone',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 740),
)
Widget harborRemoteTextEditorPhonePreview() => _previewEditor();

@Preview(
  name: 'Remote text editor · phone dark',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 740),
)
Widget harborRemoteTextEditorPhoneDarkPreview() =>
    _previewEditor(brightness: Brightness.dark);

@Preview(
  name: 'Remote text editor · load failed',
  group: 'Harbor SSH · MD3E',
  size: Size(760, 560),
)
Widget harborRemoteTextEditorErrorPreview() => MaterialApp(
  theme: harborTheme(),
  home: Scaffold(
    body: RemoteTextEditorDialog(
      files: _PreviewFileSystem(const {}),
      file: const RemoteFile(
        name: 'missing.conf',
        path: '/etc/harbor/missing.conf',
      ),
    ),
  ),
);
