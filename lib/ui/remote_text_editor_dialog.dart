import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:re_editor/re_editor.dart';

import '../data/external_files.dart' show externalEditsSyncBack;
import '../data/remote_text_editor.dart';
import '../domain/remote_file.dart';
import 'file_workspace_model.dart' show fileError;
import 'expressive_widgets.dart';
import 'remote_code_highlight.dart';
import 'theme.dart';

/// 打开远程文本编辑器，返回 true 仅表示内容已成功写回远端。
///
/// 取消、读取失败、放弃修改或保存失败都返回 false；保存失败时对话框保持
/// 打开并保留草稿，用户可以直接重试或复制草稿后再关闭。
///
/// [onOpenExternal] 为空时不显示「用外部程序打开」。它在编辑器关闭之后才被
/// 调用，避免外部副本与未保存的草稿同时修改同一个远端文件。
Future<bool> showRemoteTextEditor(
  BuildContext context, {
  required RemoteFileSystem files,
  required RemoteFile file,
  Future<void> Function()? onOpenExternal,
}) async {
  final result = await showExpressiveDialog<_EditorResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => RemoteTextEditorDialog(
      files: files,
      file: file,
      externalLabel: onOpenExternal == null ? null : externalOpenLabel,
    ),
  );
  if (result == _EditorResult.external) await onOpenExternal?.call();
  return result == _EditorResult.saved;
}

/// 「用外部程序打开」在当前平台上的说明：桌面会把外部保存同步回远端，
/// Android 只能交出只读副本。
String get externalOpenLabel =>
    externalEditsSyncBack ? '用外部程序打开' : '用其他应用查看';

enum _EditorResult { saved, external }

/// 远程文本编辑对话框：读取 [file] 的 UTF-8 内容，编辑后经
/// [RemoteTextEditor.save] 原子写回。
class RemoteTextEditorDialog extends StatefulWidget {
  const RemoteTextEditorDialog({
    super.key,
    required this.files,
    required this.file,
    this.externalLabel,
  });

  final RemoteFileSystem files;
  final RemoteFile file;

  /// 外部打开按钮的文字；为空时不显示该入口。
  final String? externalLabel;

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

  /// UTF-8 大小，载入时计算一次，供状态栏显示；重新载入后远端大小可能变化。
  int? _size;

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
        _size = utf8.encode(content).length;
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
      Navigator.of(context).pop();
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
      Navigator.of(context).pop(_EditorResult.saved);
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
    final discard = await showExpressiveDialog<bool>(
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
    if (mounted) Navigator.of(context).pop();
  }

  /// 外部程序拿到的是远端当前内容；编辑器先关闭，未保存的草稿需要确认放弃，
  /// 避免两份内容分别写回同一个远端文件。
  Future<void> _openExternal() async {
    if (_saving) return;
    if (_dirty && !await _confirmDiscard()) return;
    if (mounted) Navigator.of(context).pop(_EditorResult.external);
  }

  String get _statusLabel {
    if (_loading) return '正在读取…';
    if (_loadError != null) return '读取失败';
    if (_saving) return '正在写入远端…';
    if (_saveError != null) return '保存失败，草稿已保留';
    if (_dirty) return '未保存的修改';
    return '已与远端同步';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // 手机上占满屏幕：代码需要尽可能宽，四周留白只会挤掉可见列数。
    final compact = MediaQuery.sizeOf(context).width < 600;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(theme, colors, compact),
        Divider(height: 1, color: colors.outlineVariant),
        Expanded(child: _body(theme, colors)),
        if (_saveError != null) _saveErrorBanner(colors),
        Divider(height: 1, color: colors.outlineVariant),
        _statusBar(theme, colors, compact),
      ],
    );

    return PopScope(
      // 所有离开路径（关闭图标、Esc、系统返回）都由 [_requestClose] 处理，
      // 它按当前草稿状态决定是否确认，不依赖上一帧的构建结果。
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
        child: compact
            ? Dialog.fullscreen(
                key: const ValueKey('remote-text-dialog'),
                backgroundColor: colors.surfaceContainerLow,
                child: SafeArea(child: content),
              )
            : Dialog(
                key: const ValueKey('remote-text-dialog'),
                insetPadding: const EdgeInsets.all(24),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 1120,
                    maxHeight: 860,
                  ),
                  child: SizedBox.expand(child: content),
                ),
              ),
      ),
    );
  }

  /// 顶部工具栏：文件身份在左，操作在右。保存是唯一的主操作，其余都是图标
  /// 或描边按钮；手机上把重新载入和外部打开收进「更多」菜单，给文件名留宽度。
  Widget _toolbar(ThemeData theme, ColorScheme colors, bool compact) {
    final external = widget.externalLabel;
    final save = Tooltip(
      message: '保存（Ctrl+S）',
      child: FilledButton.icon(
        key: const ValueKey('save-remote-text'),
        style: FilledButton.styleFrom(
          minimumSize: Size(0, compact ? 44 : 40),
          padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 18),
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
    );
    final close = IconButton(
      key: const ValueKey('close-remote-text'),
      onPressed: _saving ? null : _requestClose,
      tooltip: '关闭编辑器',
      icon: const Icon(Icons.close_rounded),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 4 : 16, 10, compact ? 4 : 12, 10),
      child: Row(
        children: [
          if (compact) close else _fileMark(colors),
          SizedBox(width: compact ? 4 : 12),
          Expanded(child: _identity(theme, colors, compact)),
          const SizedBox(width: 8),
          if (compact) ...[
            save,
            PopupMenuButton<String>(
              key: const ValueKey('remote-text-more'),
              tooltip: '更多操作',
              enabled: !_saving,
              clipBehavior: theme.windowBackdrop.frosted
                  ? Clip.antiAlias
                  : Clip.none,
              popUpAnimationStyle: HarborMotion.popup(context),
              onSelected: (action) => unawaited(
                action == 'reload' ? _reload() : _openExternal(),
              ),
              itemBuilder: (_) => [
                if (theme.windowBackdrop.frosted)
                  const HarborPopupMenuBackdrop<String>(),
                HarborPopupMenuItem(
                  key: const ValueKey('reload-remote-text'),
                  value: 'reload',
                  enabled: !_busy,
                  child: const _MenuLabel(Icons.refresh_rounded, '重新载入'),
                ),
                if (external != null)
                  HarborPopupMenuItem(
                    key: const ValueKey('open-remote-text-external'),
                    value: 'external',
                    child: _MenuLabel(Icons.open_in_new_rounded, external),
                  ),
              ],
            ),
          ] else ...[
            IconButton(
              key: const ValueKey('reload-remote-text'),
              onPressed: _busy ? null : _reload,
              tooltip: '重新载入远端内容',
              icon: const Icon(Icons.refresh_rounded),
            ),
            if (external != null) ...[
              const SizedBox(width: 4),
              OutlinedButton.icon(
                key: const ValueKey('open-remote-text-external'),
                onPressed: _saving ? null : _openExternal,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text(external),
              ),
            ],
            const SizedBox(width: 8),
            save,
            const SizedBox(width: 4),
            close,
          ],
        ],
      ),
    );
  }

  Widget _fileMark(ColorScheme colors) => DecoratedBox(
    decoration: BoxDecoration(
      color: colors.primaryContainer.withValues(alpha: .55),
      borderRadius: const BorderRadius.all(HarborShapes.sm),
    ),
    child: SizedBox.square(
      dimension: 40,
      child: Icon(
        Icons.code_rounded,
        size: 20,
        color: colors.onPrimaryContainer,
      ),
    ),
  );

  /// 文件名与完整路径。未保存时文件名后跟一个圆点，与常见桌面编辑器一致；
  /// 路径用等宽字体，便于和终端里看到的路径对照。
  Widget _identity(ThemeData theme, ColorScheme colors, bool compact) => Column(
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
          if (_dirty) ...[
            const SizedBox(width: 8),
            Semantics(
              label: '未保存',
              child: DecoratedBox(
                key: const ValueKey('remote-text-dirty'),
                decoration: BoxDecoration(
                  color: colors.tertiary,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(dimension: 8),
              ),
            ),
          ],
        ],
      ),
      if (!compact) const SizedBox(height: 2),
      Text(
        _file.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: colors.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _body(ThemeData theme, ColorScheme colors) {
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
      final external = widget.externalLabel;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 32,
                  color: colors.error,
                ),
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('retry-load-remote-text'),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                    // 二进制、非 UTF-8 或超过 1 MiB 的文件编辑器打不开，外部
                    // 程序往往可以，这里直接给出替代路径。
                    if (external != null)
                      OutlinedButton.icon(
                        key: const ValueKey('open-remote-text-external-error'),
                        onPressed: _openExternal,
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text(external),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    final codeTheme = remoteCodeHighlightTheme(_file.path, theme.brightness);
    // 高亮主题自带代码面板底色，浅深两套主题各自成套；无高亮时退回表面色。
    final rootStyle = codeTheme?.theme['root'];
    return ColoredBox(
      color: rootStyle?.backgroundColor ?? colors.surfaceContainerLowest,
      child: CodeEditor(
        key: const ValueKey('remote-text-content'),
        controller: _text,
        focusNode: _focus,
        toolbarController: _selectionToolbar,
        autofocus: true,
        readOnly: _busy,
        wordWrap: false,
        hint: '文件内容为空',
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        style: CodeEditorStyle(
          fontSize: 13,
          fontFamily: 'monospace',
          fontHeight: 1.5,
          textColor: rootStyle?.color ?? colors.onSurface,
          hintTextColor: colors.onSurfaceVariant,
          cursorColor: colors.primary,
          codeTheme: codeTheme,
        ),
        indicatorBuilder: (context, controller, chunkController, notifier) =>
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 10),
              child: DefaultCodeLineNumber(
                controller: controller,
                notifier: notifier,
                textStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                  color: colors.onSurfaceVariant.withValues(alpha: .7),
                ),
                focusedTextStyle: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        leadingDivider: VerticalDivider(
          width: 1,
          thickness: 1,
          color: colors.outlineVariant.withValues(alpha: .6),
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
    );
  }

  Widget _saveErrorBanner(ColorScheme colors) => Material(
    key: const ValueKey('remote-text-save-error'),
    color: colors.errorContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: colors.onErrorContainer,
          ),
          const SizedBox(width: 10),
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
            key: const ValueKey('reload-remote-text-after-error'),
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

  /// 底部状态栏：左边是保存状态，右边是光标位置与文件属性。光标位置单独
  /// 监听控制器，移动光标不会重建整个对话框。
  Widget _statusBar(ThemeData theme, ColorScheme colors, bool compact) {
    final failed = _saveError != null || _loadError != null;
    final statusColor = failed
        ? colors.error
        : _busy
        ? colors.primary
        : _dirty
        ? colors.tertiary
        : colors.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final ready = !_loading && _loadError == null;
    return SizedBox(
      height: compact ? 32 : 30,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
        child: Row(
          children: [
            Icon(
              failed
                  ? Icons.error_outline_rounded
                  : _busy
                  ? Icons.sync_rounded
                  : _dirty
                  ? Icons.edit_outlined
                  : Icons.check_circle_outline_rounded,
              size: 14,
              color: statusColor,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _statusLabel,
                key: const ValueKey('remote-text-status'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(color: statusColor),
              ),
            ),
            const SizedBox(width: 12),
            if (ready) ...[
              ValueListenableBuilder<CodeLineEditingValue>(
                valueListenable: _text,
                builder: (context, value, _) {
                  final selection = value.selection;
                  return Text(
                    '行 ${selection.extentIndex + 1}，列 ${selection.extentOffset + 1}',
                    key: const ValueKey('remote-text-cursor'),
                    style: style,
                  );
                },
              ),
              _statusDivider(colors),
            ],
            Text(
              remoteCodeLanguageLabel(_file.path),
              key: const ValueKey('remote-text-language'),
              style: style,
            ),
            if (!compact) ...[
              _statusDivider(colors),
              Text('UTF-8', style: style),
              if (ready) ...[
                _statusDivider(colors),
                Text(
                  _lineBreakLabel(_text.options.lineBreak),
                  key: const ValueKey('remote-text-line-break'),
                  style: style,
                ),
              ],
              if (_size != null) ...[
                _statusDivider(colors),
                Text(fileSizeLabel(_size), style: style),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusDivider(ColorScheme colors) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: SizedBox(
      height: 12,
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        color: colors.outlineVariant,
      ),
    ),
  );
}

String _lineBreakLabel(TextLineBreak lineBreak) => switch (lineBreak) {
  TextLineBreak.crlf => 'CRLF',
  TextLineBreak.cr => 'CR',
  TextLineBreak.lf => 'LF',
};

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 12),
      Text(text),
    ],
  );
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
      final localizations = MaterialLocalizations.of(context);
      final action = await showMenu<String>(
        context: context,
        clipBehavior: Theme.of(context).windowBackdrop.frosted
            ? Clip.antiAlias
            : Clip.none,
        popUpAnimationStyle: HarborMotion.popup(context),
        position: RelativeRect.fromLTRB(
          x,
          y,
          overlay.size.width - x,
          overlay.size.height - y,
        ),
        items: [
          if (Theme.of(context).windowBackdrop.frosted)
            const HarborPopupMenuBackdrop<String>(),
          if (canEdit())
            HarborPopupMenuItem(
              value: 'cut',
              child: Text(localizations.cutButtonLabel),
            ),
          HarborPopupMenuItem(
            value: 'copy',
            child: Text(localizations.copyButtonLabel),
          ),
          if (canEdit())
            HarborPopupMenuItem(
              value: 'paste',
              child: Text(localizations.pasteButtonLabel),
            ),
          HarborPopupMenuItem(
            value: 'all',
            child: Text(localizations.selectAllButtonLabel),
          ),
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
  Future<void> createFileExclusive(String path) async {
    if (_entries.containsKey(path)) throw StateError('目标已存在：$path');
    _entries[path] = '';
  }

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
          externalLabel: externalOpenLabel,
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
      externalLabel: externalOpenLabel,
    ),
  ),
);
