import 'dart:async';

import 'package:flutter/material.dart';

import '../data/mcp_client.dart';
import '../data/terminal_ai.dart';
import 'ai_approval_mode_menu.dart';
import 'expressive_widgets.dart';
import 'theme.dart';

/// Editor for the remote HTTP MCP servers of the AI assistant.
///
/// The list is owned by `AiSettingsPage`: this widget only edits an immutable
/// copy and reports the complete list back. Header values are masked by
/// default, and everything the connection test renders (tool names and the
/// transport error) is independent of the configured credentials.
class AiMcpSettingsEditor extends StatelessWidget {
  const AiMcpSettingsEditor({
    super.key,
    required this.servers,
    required this.onChanged,
    this.clientFactory,
    this.enabled = true,
  });

  final List<AiMcpServer> servers;
  final ValueChanged<List<AiMcpServer>> onChanged;

  /// Creates the transport for tool inspection and connection tests. Null
  /// uses the real MCP client; tests and previews can inject a transport.
  final McpClient Function(AiMcpServer server)? clientFactory;
  final bool enabled;

  McpClient _client(AiMcpServer server) =>
      (clientFactory ?? McpClient.new)(server);

  Future<void> _edit(BuildContext context, AiMcpServer? server) async {
    final next = await showExpressiveDialog<AiMcpServer>(
      context: context,
      builder: (context) => _AiMcpServerDialog(
        server: server,
        clientFactory: _client,
        enabled: enabled,
      ),
    );
    if (next == null) return;
    final list = [...servers];
    final index = list.indexWhere((item) => item.id == next.id);
    if (index >= 0) {
      list[index] = next;
    } else {
      list.add(next);
    }
    onChanged(List.unmodifiable(list));
  }

  /// Lists the tools this server actually advertises. Nothing is fetched until
  /// the row menu opens the dialog; a disabled server can still be inspected
  /// without being enabled.
  Future<void> _tools(BuildContext context, AiMcpServer server) =>
      showExpressiveDialog<void>(
        context: context,
        builder: (context) =>
            _AiMcpServerToolsDialog(server: server, clientFactory: _client),
      );

  Future<void> _delete(BuildContext context, AiMcpServer server) async {
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 MCP 服务？'),
        content: Text('将删除「${server.name}」；它的地址和请求头也会一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    onChanged(
      List.unmodifiable(servers.where((item) => item.id != server.id).toList()),
    );
  }

  void _toggle(AiMcpServer server, bool value) => onChanged(
    List.unmodifiable([
      for (final item in servers)
        item.id == server.id
            ? AiMcpServer(
                id: item.id,
                name: item.name,
                url: item.url,
                headers: item.headers,
                enabled: value,
              )
            : item,
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'MCP 服务',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('ai-mcp-add'),
              onPressed: enabled ? () => _edit(context, null) : null,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('添加'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (servers.isEmpty)
          Material(
            color: colors.surfaceContainerLow,
            shape: HarborShapes.superellipse(
              const BorderRadius.all(HarborShapes.md),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '尚未添加 MCP 服务。添加后，助手可以发现并调用服务器提供的工具。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final server in servers)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: HarborShapes.listGap,
                    ),
                    child: _AiMcpServerRow(
                      key: ValueKey(server.id),
                      server: server,
                      enabled: enabled,
                      // A narrow window keeps the room for the name and the
                      // two controls instead of a decorative mark.
                      showMark: constraints.maxWidth >= _rowMarkBreakpoint,
                      onEdit: () => _edit(context, server),
                      onTools: () => _tools(context, server),
                      onDelete: () => _delete(context, server),
                      onToggle: (value) => _toggle(server, value),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Below this width the server mark would squeeze the name to nothing, so the
/// row drops decoration before it shrinks any tap target.
const double _rowMarkBreakpoint = 360;

/// One configured server: a mark, its name and address, the enabled switch and
/// an overflow menu.
///
/// The whole row opens the editor, so editing is a single tap; the overflow
/// menu holds the destructive action plus the same edit entry, keeping
/// "disable" and "delete" from sitting next to each other as bare icons.
class _AiMcpServerRow extends StatefulWidget {
  const _AiMcpServerRow({
    super.key,
    required this.server,
    required this.enabled,
    required this.showMark,
    required this.onEdit,
    required this.onTools,
    required this.onDelete,
    required this.onToggle,
  });

  final AiMcpServer server;

  /// Whether the surrounding editor accepts changes at all; a disabled server
  /// (`server.enabled == false`) stays fully editable.
  final bool enabled;
  final bool showMark;
  final VoidCallback onEdit;
  final VoidCallback onTools;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  State<_AiMcpServerRow> createState() => _AiMcpServerRowState();
}

class _AiMcpServerRowState extends State<_AiMcpServerRow> {
  final _menu = MenuController();

  /// A menu entry closes the overlay and then runs [action] on the next frame,
  /// so the dialog never opens underneath a menu that is still fading out.
  void _closeThen(VoidCallback action) {
    _menu.close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) action();
    });
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final enabled = widget.enabled;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = server.enabled;
    return Material(
      key: ValueKey('ai-mcp-server-${server.id}'),
      color: colors.surfaceContainerLow,
      shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.md)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('ai-mcp-open-${server.id}'),
        onTap: enabled ? widget.onEdit : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(widget.showMark ? 12 : 16, 8, 6, 8),
          child: Row(
            children: [
              if (widget.showMark) ...[
                ExpressiveMark(
                  size: 40,
                  icon: Icons.hub_outlined,
                  color: active
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  foreground: active
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: active
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Tooltip(
                      message: server.url,
                      child: Text(
                        server.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Switch(
                key: ValueKey('ai-mcp-toggle-${server.id}'),
                value: active,
                onChanged: enabled ? widget.onToggle : null,
              ),
              MenuAnchor(
                controller: _menu,
                alignmentOffset: const Offset(0, 4),
                menuChildren: [
                  if (theme.windowBackdrop.frosted) const HarborSurfaceBlur(),
                  MenuItemButton(
                    key: ValueKey('ai-mcp-edit-${server.id}'),
                    style: aiMenuItemStyle(context),
                    leadingIcon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: enabled ? () => _closeThen(widget.onEdit) : null,
                    child: const Text('编辑'),
                  ),
                  MenuItemButton(
                    key: ValueKey('ai-mcp-tools-${server.id}'),
                    style: aiMenuItemStyle(context),
                    leadingIcon: const Icon(Icons.widgets_outlined, size: 20),
                    onPressed: enabled
                        ? () => _closeThen(widget.onTools)
                        : null,
                    child: const Text('查看工具'),
                  ),
                  MenuItemButton(
                    key: ValueKey('ai-mcp-delete-${server.id}'),
                    style: aiMenuItemStyle(context),
                    leadingIcon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                    ),
                    onPressed: enabled
                        ? () => _closeThen(widget.onDelete)
                        : null,
                    child: const Text('删除'),
                  ),
                ],
                builder: (context, controller, child) => IconButton(
                  key: ValueKey('ai-mcp-more-${server.id}'),
                  tooltip: '更多',
                  onPressed: enabled
                      ? () => controller.isOpen
                            ? controller.close()
                            : controller.open()
                      : null,
                  icon: const Icon(Icons.more_vert_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Edit one server, including its headers and a real tool-list connection test.
class _AiMcpServerDialog extends StatefulWidget {
  const _AiMcpServerDialog({
    required this.server,
    required this.clientFactory,
    required this.enabled,
  });

  final AiMcpServer? server;
  final McpClient Function(AiMcpServer server) clientFactory;
  final bool enabled;

  @override
  State<_AiMcpServerDialog> createState() => _AiMcpServerDialogState();
}

class _AiMcpServerDialogState extends State<_AiMcpServerDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late bool _enabled;
  late final List<_HeaderRow> _headers;
  bool _testing = false;
  bool _saving = false;
  String? _testError;
  List<McpTool>? _tools;
  String? _formError;

  /// Client of the in-flight connection test. Kept on the state so dismissing
  /// or cancelling the dialog can abort the socket and session immediately
  /// instead of waiting for the request timeout.
  McpClient? _activeClient;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _name = TextEditingController(text: server?.name ?? '');
    _url = TextEditingController(text: server?.url ?? '');
    _enabled = server?.enabled ?? true;
    _headers = [
      for (final entry in (server?.headers ?? const <String, String>{}).entries)
        _HeaderRow(entry.key, entry.value),
    ];
  }

  @override
  void dispose() {
    final client = _activeClient;
    _activeClient = null;
    if (client != null) {
      client.cancel();
      unawaited(client.close().catchError((_) {}));
    }
    _name.dispose();
    _url.dispose();
    for (final row in _headers) {
      row.dispose();
    }
    super.dispose();
  }

  AiMcpServer _build() {
    final headers = <String, String>{};
    for (final row in _headers) {
      final key = row.key.text.trim();
      final value = row.value.text;
      if (key.isEmpty) {
        if (value.trim().isEmpty) continue;
        throw const FormatException('请求头名称不能为空');
      }
      if (headers.containsKey(key)) {
        throw FormatException('请求头「$key」重复');
      }
      headers[key] = value;
    }
    return AiMcpServer(
      id: widget.server?.id ?? 'mcp-${DateTime.now().microsecondsSinceEpoch}',
      name: _name.text.trim(),
      url: _url.text.trim(),
      headers: Map.unmodifiable(headers),
      enabled: _enabled,
    );
  }

  String _message(Object error) => switch (error) {
    McpFailure() => error.message,
    FormatException() => error.message,
    _ => '配置无效，请检查名称、地址和请求头',
  };

  void _addHeader() {
    setState(() => _headers.add(_HeaderRow('', '')));
  }

  void _removeHeader(int index) {
    setState(() {
      _headers.removeAt(index).dispose();
    });
  }

  Future<void> _test() async {
    if (_testing || !widget.enabled) return;
    setState(() {
      _testing = true;
      _testError = null;
      _tools = null;
      _formError = null;
    });
    McpClient? client;
    try {
      final server = _build();
      server.validate();
      client = _activeClient = widget.clientFactory(server);
      final tools = await client.listTools();
      if (!mounted) return;
      setState(() {
        _tools = List.unmodifiable(tools);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testError = _message(error);
      });
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      if (client != null) {
        try {
          await client.close();
        } catch (_) {
          // The test result is already known; closing is best effort.
        }
      }
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Aborts an in-flight connection test and closes the dialog. The client is
  /// cancelled before the route is popped so the socket never outlives the
  /// dialog, even when the server ignores the request.
  void _cancelTest() {
    _activeClient?.cancel();
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving || !widget.enabled) return;
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      final server = _build();
      server.validate();
      if (!mounted) return;
      Navigator.of(context).pop(server);
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() => _formError = _message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    // Unreachable when the dialog closed; kept for the error path.
  }

  /// One header key/value pair. The value stays masked until the eye icon is
  /// pressed; narrow dialogs stack the pair so neither field collapses.
  Widget _headerFields({
    required int index,
    required bool busy,
    required bool stacked,
  }) {
    final row = _headers[index];
    final name = TextField(
      key: ValueKey('ai-mcp-header-key-$index'),
      controller: row.key,
      enabled: !busy,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(
        labelText: '名称',
        hintText: 'Authorization',
      ),
    );
    final value = TextField(
      key: ValueKey('ai-mcp-header-value-$index'),
      controller: row.value,
      enabled: !busy,
      obscureText: !row.visible,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: '值',
        suffixIcon: IconButton(
          key: ValueKey('ai-mcp-header-visible-$index'),
          tooltip: row.visible ? '隐藏请求头值' : '显示请求头值',
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          onPressed: busy
              ? null
              : () => setState(() => row.visible = !row.visible),
          icon: Icon(
            row.visible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
        ),
      ),
    );
    final remove = IconButton(
      key: ValueKey('ai-mcp-header-remove-$index'),
      tooltip: '删除请求头',
      onPressed: busy ? null : () => _removeHeader(index),
      icon: const Icon(Icons.close_rounded, size: 20),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          name,
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: value),
              const SizedBox(width: 4),
              remove,
            ],
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(flex: 5, child: name),
        const SizedBox(width: 8),
        Expanded(flex: 7, child: value),
        const SizedBox(width: 4),
        remove,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final busy = _testing || _saving;
    // AlertDialog sizes itself to the intrinsic content, which would make the
    // dialog jump while typing. One pinned inner width keeps it steady; 80 is
    // the horizontal inset (16 per side) plus the content padding (24 per
    // side).
    final width = (MediaQuery.sizeOf(context).width - 80)
        .clamp(200.0, 480.0)
        .toDouble();
    // Header key and value stop being usable side by side below this width,
    // so they stack instead of squeezing the masked value.
    final stackedHeaders = width < 360;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      title: Text(widget.server == null ? '添加 MCP 服务' : '编辑 MCP 服务'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('启用', style: theme.textTheme.bodyLarge)),
                  Switch(
                    key: const ValueKey('ai-mcp-enabled'),
                    value: _enabled,
                    onChanged: busy
                        ? null
                        : (value) => setState(() => _enabled = value),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('ai-mcp-name'),
                controller: _name,
                enabled: !busy,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如 GitHub',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('ai-mcp-url'),
                controller: _url,
                enabled: !busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: '地址',
                  hintText: 'https://mcp.example.com/mcp',
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text('请求头', style: theme.textTheme.titleSmall),
                  ),
                  TextButton.icon(
                    key: const ValueKey('ai-mcp-header-add'),
                    onPressed: busy ? null : _addHeader,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
              if (_headers.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '请求头可留空，鉴权信息仅保存在本机。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (var index = 0; index < _headers.length; index++)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _headerFields(
                      index: index,
                      busy: busy,
                      stacked: stackedHeaders,
                    ),
                  ),
              if (_testError != null) ...[
                const SizedBox(height: 12),
                Text(
                  '连接失败：$_testError',
                  key: const ValueKey('ai-mcp-test-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
              if (_tools != null) ...[
                const SizedBox(height: 12),
                Material(
                  color: colors.surfaceContainerHighest,
                  shape: HarborShapes.superellipse(
                    const BorderRadius.all(HarborShapes.sm),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '连接成功，发现 ${_tools!.length} 个工具',
                            key: const ValueKey('ai-mcp-test-success'),
                            style: theme.textTheme.bodyMedium,
                          ),
                          for (final tool in _tools!)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                tool.name,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (_formError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _formError!,
                  key: const ValueKey('ai-mcp-form-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          key: const ValueKey('ai-mcp-test'),
          onPressed: busy ? null : _test,
          icon: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cable_rounded, size: 18),
          label: Text(_testing ? '正在连接…' : '测试连接'),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _saving
                  ? null
                  : _testing
                  ? _cancelTest
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('ai-mcp-save'),
              onPressed: widget.enabled && !busy ? _save : null,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeaderRow {
  _HeaderRow(String key, String value)
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;
  bool visible = false;

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// Read-only list of the tools one server advertises.
///
/// A read starts only when the row menu opens this dialog and again when the
/// user presses refresh: one fresh [McpClient] per read, cancelled when the
/// dialog goes away and always closed. Only [McpTool.name] and
/// [McpTool.description] are shown; the input schema is out of scope, and no
/// configured header value is ever rendered, not even inside an error.
class _AiMcpServerToolsDialog extends StatefulWidget {
  const _AiMcpServerToolsDialog({
    required this.server,
    required this.clientFactory,
  });

  final AiMcpServer server;
  final McpClient Function(AiMcpServer server) clientFactory;

  @override
  State<_AiMcpServerToolsDialog> createState() =>
      _AiMcpServerToolsDialogState();
}

class _AiMcpServerToolsDialogState extends State<_AiMcpServerToolsDialog> {
  /// Client of the read in flight; cancelling it aborts the socket and the
  /// session immediately instead of waiting for the request timeout.
  McpClient? _activeClient;
  bool _loading = true;
  String? _error;
  List<McpTool>? _tools;

  /// Bumped whenever a read starts or is abandoned, so a late answer can never
  /// overwrite a newer state or a closed dialog.
  int _generation = 0;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    // Deferred one frame: the factory may throw synchronously (the preview
    // does exactly that), and reporting an error during the first build would
    // call setState mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) unawaited(_read());
    });
  }

  @override
  void dispose() {
    _closed = true;
    _releaseClient();
    super.dispose();
  }

  /// Abandons the read in flight. Idempotent: the close button, Escape, a
  /// barrier tap and disposal all end up here, and a failing close must never
  /// block closing or replace a result that already arrived.
  void _releaseClient() {
    _generation++;
    final client = _activeClient;
    _activeClient = null;
    if (client == null) return;
    client.cancel();
    unawaited(client.close().catchError((_) {}));
  }

  Future<void> _read() async {
    if (_closed) return;
    final generation = ++_generation;
    McpClient? client;
    try {
      client = _activeClient = widget.clientFactory(widget.server);
      final tools = await client.listTools();
      if (!mounted || _closed || generation != _generation) return;
      setState(() {
        _tools = List.unmodifiable(tools);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || _closed || generation != _generation) return;
      setState(() {
        _error = _message(error);
        _loading = false;
      });
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      if (client != null) {
        try {
          await client.close();
        } catch (_) {
          // Closing is best effort; the read result is already accounted for.
        }
      }
    }
  }

  /// Failure text for the dialog. [McpFailure] messages are written to be
  /// secret-free; anything else (including a malformed configuration) is
  /// replaced by one generic hint instead of echoing the exception.
  String _message(Object error) => switch (error) {
    McpFailure() => error.message,
    _ => '无法读取工具列表，请检查地址和请求头后重试',
  };

  void _refresh() {
    if (_loading || _closed) return;
    setState(() {
      _loading = true;
      _error = null;
      // A stale list is never presented as the result of a failed refresh.
      _tools = null;
    });
    unawaited(_read());
  }

  void _close() {
    _closed = true;
    _releaseClient();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final pending = _loading;
    final tools = _tools;
    // The same pinned inner width as the editor dialog; AlertDialog would
    // otherwise size itself to the intrinsic content and jump between states.
    final width = (MediaQuery.sizeOf(context).width - 80)
        .clamp(200.0, 480.0)
        .toDouble();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _closed = true;
        _releaseClient();
      },
      child: AlertDialog(
        key: const ValueKey('ai-mcp-tools-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        title: const Text('MCP 工具'),
        content: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.server.name, style: theme.textTheme.titleSmall),
              if (tools != null) ...[
                const SizedBox(height: 2),
                Text(
                  '发现 ${tools.length} 个工具',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Flexible(
                child: _body(theme, pending: pending, tools: tools),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        actions: [
          TextButton.icon(
            key: const ValueKey('ai-mcp-tools-refresh'),
            onPressed: pending ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新'),
          ),
          TextButton(
            key: const ValueKey('ai-mcp-tools-close'),
            onPressed: _close,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// Loading, failure, empty or the tool list. The list viewport is capped so
  /// a server with hundreds of tools keeps a scrollable, lazily built list
  /// instead of growing the dialog past the screen.
  Widget _body(
    ThemeData theme, {
    required bool pending,
    required List<McpTool>? tools,
  }) {
    final colors = theme.colorScheme;
    if (pending) {
      return Row(
        key: const ValueKey('ai-mcp-tools-loading'),
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '正在读取工具…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return Text(
        '读取失败：$_error',
        key: const ValueKey('ai-mcp-tools-error'),
        style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
      );
    }
    if (tools == null || tools.isEmpty) {
      return Text(
        '该服务没有提供任何工具。',
        key: const ValueKey('ai-mcp-tools-empty'),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.builder(
        primary: false,
        padding: EdgeInsets.zero,
        itemCount: tools.length,
        itemBuilder: (context, index) {
          final tool = tools[index];
          final description = tool.description.trim();
          return Padding(
            key: ValueKey('ai-mcp-tool-${tool.name}'),
            padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  tool.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  SelectableText(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
