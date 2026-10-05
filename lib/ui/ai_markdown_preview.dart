import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'ai_markdown_code_block.dart';
import 'ai_markdown_style.dart';
import 'ai_markdown_table.dart';
import 'localization.dart';
import 'theme.dart';

@Preview(
  name: 'AI reply code · dark',
  group: 'Harbor SSH · AI',
  size: Size(760, 480),
)
Widget aiMarkdownDarkPreview() => _preview(Brightness.dark);

@Preview(
  name: 'AI reply code · mobile',
  group: 'Harbor SSH · AI',
  size: Size(320, 640),
)
Widget aiMarkdownMobilePreview() => _preview(Brightness.light);

const _reply = '''这个脚本需要先下载，然后用 bash 运行。

先下载：

```bash
curl -fsSL -o deploy.sh https://example.com/deploy.sh
chmod +x deploy.sh
bash deploy.sh
```

不带参数时会打印用法：

| 命令 | 作用 |
| --- | --- |
| `bash deploy-marzban.sh 1 管理员密码 面板域名` | 安装主面板 |
| `bash deploy-marzban.sh 2` | 更新 Xray 内核 |
| `bash deploy-marzban.sh 3 域名` | 设置 Cloudflare 中转 |
| `bash deploy-marzban.sh 4` | 安装 Marzban Node |
| `bash deploy-marzban.sh 5 域名` | 用 Cloudflare DNS-01 申请 TLS 证书 |
''';

Widget _preview(Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: harborTheme(brightness: brightness),
  locale: harborLocale,
  supportedLocales: harborSupportedLocales,
  localizationsDelegates: harborLocalizationDelegates,
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Builder(
        builder: (context) => MarkdownBody(
          data: _reply,
          selectable: true,
          fitContent: false,
          blockSyntaxes: const [AiMarkdownTableSyntax()],
          builders: {
            'pre': AiMarkdownCodeBuilder(),
            AiMarkdownTableSyntax.tag: AiMarkdownTableBuilder(),
          },
          styleSheet: aiMarkdownStyle(Theme.of(context)),
        ),
      ),
    ),
  ),
);
