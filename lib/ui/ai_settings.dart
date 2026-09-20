import 'package:flutter/material.dart';

import '../data/terminal_ai.dart';
import '../data/sync_config.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.controller});
  final SyncSettingsController controller;
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  late final _url = TextEditingController(
    text: widget.controller.aiSettings.baseUrl,
  );
  late final _key = TextEditingController(
    text: widget.controller.aiSettings.apiKey,
  );
  late final _model = TextEditingController(
    text: widget.controller.aiSettings.model,
  );
  bool _visible = false, _saving = false;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveAiSettings(
        AiSettings(
          baseUrl: _url.text.trim(),
          apiKey: _key.text.trim(),
          model: _model.text.trim(),
        ),
      );
      if (mounted) showSettingsNotice(context, 'AI 设置已保存');
    } catch (error) {
      if (mounted) {
        showSettingsNotice(context, switch (error) {
          AiFailure() => error.message,
          SyncFailure() => error.message,
          _ => '无法保存 AI 设置，请重试',
        }, error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    String name,
    TextEditingController controller,
    String hint, {
    bool secret = false,
  }) => TextField(
    key: ValueKey('ai-setting-$name'),
    controller: controller,
    enabled: !_saving,
    obscureText: secret && !_visible,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(
      hintText: hint,
      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      suffixIcon: secret
          ? IconButton(
              onPressed: () => setState(() => _visible = !_visible),
              icon: Icon(
                _visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                semanticLabel: _visible ? '隐藏 API Key' : '显示 API Key',
              ),
            )
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) => SettingsList(
    children: [
      SettingsGroup(
        title: '模型服务',
        children: [
          SettingsRow(
            title: 'API 地址',
            description: '支持工具调用的 OpenAI 兼容接口',
            control: _field('url', _url, 'https://api.example.com/v1'),
          ),
          SettingsRow(
            title: 'API Key',
            description: '保存在当前设备；本地服务可留空',
            control: _field('key', _key, 'API Key', secret: true),
          ),
          SettingsRow(
            title: '模型',
            control: _field('model', _model, '服务商提供的模型名称'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          '在终端打开 AI，输入目标后开始任务。执行记录与命令输出会发送给这里配置的模型服务。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ),
    ],
  );
}
