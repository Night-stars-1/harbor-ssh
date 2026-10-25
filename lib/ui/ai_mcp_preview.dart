import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../data/mcp_client.dart';
import '../data/terminal_ai.dart';
import 'ai_mcp_settings.dart';
import 'ai_prompt_settings.dart';
import 'theme.dart';

/// In-memory settings previews. Tool discovery uses preview-only data and
/// never opens a socket; edits, toggles and deletes stay in local state.
List<AiMcpServer> _configured() => const [
  AiMcpServer(
    id: 'github',
    name: 'GitHub',
    url: 'https://mcp.example.com/github',
    headers: {'Authorization': 'Bearer preview-token'},
  ),
  AiMcpServer(
    id: 'docs',
    name: '内部文档',
    url: 'http://10.0.0.12:8080/mcp',
    enabled: false,
  ),
];

class _PreviewMcpClient extends McpClient {
  _PreviewMcpClient(super.server);

  @override
  Future<List<McpTool>> listTools() async => [
    McpTool('search_issues', '按关键词搜索项目中的 issue。', const {'type': 'object'}),
    McpTool('read_issue', '读取指定 issue 的内容和状态。', const {'type': 'object'}),
  ];
}

class _ServersPreview extends StatefulWidget {
  const _ServersPreview({required this.initial, this.enabled = true});

  final List<AiMcpServer> initial;
  final bool enabled;

  @override
  State<_ServersPreview> createState() => _ServersPreviewState();
}

class _ServersPreviewState extends State<_ServersPreview> {
  late List<AiMcpServer> _servers = widget.initial;

  @override
  Widget build(BuildContext context) => AiMcpSettingsEditor(
    servers: _servers,
    enabled: widget.enabled,
    onChanged: (next) => setState(() => _servers = next),
    clientFactory: _PreviewMcpClient.new,
  );
}

Widget _surface({required Brightness brightness, required Widget child}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: harborTheme(brightness: brightness),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: child,
            ),
          ),
        ),
      ),
    );

@Preview(
  name: 'MCP 服务 · 已配置 · 760',
  group: 'Harbor SSH · AI 设置',
  size: Size(760, 520),
)
Widget aiMcpServersConfiguredPreview() => _surface(
  brightness: Brightness.light,
  child: _ServersPreview(initial: _configured()),
);

@Preview(
  name: 'MCP 服务 · 空态 · 390',
  group: 'Harbor SSH · AI 设置',
  size: Size(390, 420),
)
Widget aiMcpServersEmptyPreview() => _surface(
  brightness: Brightness.light,
  child: _ServersPreview(initial: const []),
);

@Preview(
  name: 'MCP 服务 · 已停用 · 760 深色',
  group: 'Harbor SSH · AI 设置',
  size: Size(760, 520),
)
Widget aiMcpServersDisabledPreview() => _surface(
  brightness: Brightness.dark,
  child: _ServersPreview(initial: _configured(), enabled: false),
);

/// Keeps the prompt controller alive for the preview and opens the same edit
/// dialog as the settings page, without touching the app's persisted settings.
class _PromptPreview extends StatefulWidget {
  const _PromptPreview({required this.initial, required this.expanded});

  final String initial;
  final bool expanded;

  @override
  State<_PromptPreview> createState() => _PromptPreviewState();
}

class _PromptPreviewState extends State<_PromptPreview> {
  late final _prompt = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AiPromptSettings(
    controller: _prompt,
    enabled: true,
    builtinExpanded: widget.expanded,
  );
}

@Preview(
  name: '默认提示词 · 编辑入口 · 760',
  group: 'Harbor SSH · AI 设置',
  size: Size(760, 280),
)
Widget aiPromptSupplementPreview() => _surface(
  brightness: Brightness.light,
  child: const _PromptPreview(
    initial: '回答时优先给出可回滚的操作步骤，并在执行前说明影响范围。',
    expanded: false,
  ),
);

@Preview(
  name: '默认提示词 · 内置只读 · 390',
  group: 'Harbor SSH · AI 设置',
  size: Size(390, 700),
)
Widget aiPromptBuiltinPreview() => _surface(
  brightness: Brightness.dark,
  child: const _PromptPreview(initial: '', expanded: true),
);
