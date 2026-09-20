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
  late String _provider = widget.controller.aiSettings.provider ?? 'custom';
  late AiProtocol _protocol =
      widget.controller.aiSettings.protocol ?? AiProtocol.openai;
  final _drafts = <String, AiSettings>{};

  AiSettings get _settings => AiSettings(
    baseUrl: _url.text.trim(),
    apiKey: _key.text.trim(),
    model: _model.text.trim(),
    provider: _provider,
    protocol: _protocol,
  );

  void _selectProvider(String provider) {
    if (provider == _provider) return;
    final current = _settings;
    _drafts[_provider] = current;
    final preset = aiProviderPresets.firstWhere(
      (value) => value.id == provider,
    );
    final next =
        _drafts[provider] ??
        (provider == 'custom'
            ? current
            : AiSettings(baseUrl: preset.baseUrl, protocol: preset.protocol));
    setState(() {
      _provider = provider;
      _protocol = next.protocol ?? AiProtocol.openai;
      _url.text = next.baseUrl;
      _key.text = next.apiKey;
      _model.text = next.model;
      _visible = false;
    });
  }

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
      await widget.controller.saveAiSettings(_settings);
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

  Widget _dropdown<T>(
    String name,
    T value,
    Map<T, String> options,
    ValueChanged<T> onChanged,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => DropdownMenu<T>(
        key: ValueKey('ai-setting-$name'),
        width: constraints.maxWidth,
        initialSelection: value,
        enabled: !_saving,
        selectOnly: true,
        requestFocusOnTap: true,
        enableSearch: false,
        textStyle: theme.textTheme.bodyLarge,
        inputDecorationTheme: theme.inputDecorationTheme,
        trailingIcon: const Icon(Icons.expand_more_rounded),
        selectedTrailingIcon: const Icon(Icons.expand_less_rounded),
        alignmentOffset: const Offset(0, 4),
        menuHeight: 320,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(2),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        dropdownMenuEntries: [
          for (final entry in options.entries)
            DropdownMenuEntry(
              value: entry.key,
              label: entry.value,
              trailingIcon: entry.key == value
                  ? const Icon(Icons.check_rounded, size: 20)
                  : null,
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                backgroundColor: entry.key == value
                    ? colors.secondaryContainer
                    : null,
                foregroundColor: entry.key == value
                    ? colors.onSecondaryContainer
                    : colors.onSurface,
                textStyle: theme.textTheme.bodyLarge,
              ),
            ),
        ],
        onSelected: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SettingsList(
    children: [
      SettingsGroup(
        title: '模型服务',
        children: [
          SettingsRow(
            title: '服务商',
            control: _dropdown('provider', _provider, {
              for (final preset in aiProviderPresets) preset.id: preset.name,
            }, _selectProvider),
          ),
          SettingsRow(
            title: '接口类型',
            control: _dropdown('protocol', _protocol, {
              AiProtocol.openai: 'OpenAI 兼容',
              AiProtocol.anthropic: 'Anthropic 兼容',
            }, (value) => setState(() => _protocol = value)),
          ),
          SettingsRow(
            title: 'API 地址',
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
