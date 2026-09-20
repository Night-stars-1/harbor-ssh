import 'package:flutter/material.dart';

import '../data/terminal_ai.dart';
import '../data/sync_config.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({
    super.key,
    required this.controller,
    this.modelClientFactory,
  });
  final SyncSettingsController controller;
  final TerminalAiClient Function()? modelClientFactory;
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
  List<String> _models = [];
  String? _modelsQueryAtFetch;
  bool _fetchingModels = false;
  int _modelsRevision = 0;
  TerminalAiClient? _modelsClient;
  final _modelsMenu = MenuController();

  void _invalidateModels() {
    _modelsMenu.close();
    _modelsRevision++;
    _modelsClient?.cancel();
    _modelsClient = null;
    setState(() {
      _models = [];
      _fetchingModels = false;
    });
  }

  Future<void> _fetchModels() async {
    final revision = ++_modelsRevision;
    _modelsClient?.cancel();
    final client = _modelsClient =
        (widget.modelClientFactory ?? TerminalAiClient.new)();
    setState(() => _fetchingModels = true);
    try {
      final models = await client.listModels(_settings);
      if (!mounted || revision != _modelsRevision) return;
      setState(() {
        _models = models;
        _modelsQueryAtFetch = _model.text;
      });
      showSettingsNotice(context, '已获取 ${models.length} 个模型');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _modelsRevision) _modelsMenu.open();
      });
    } catch (error) {
      if (mounted && revision == _modelsRevision) {
        showSettingsNotice(
          context,
          error is AiFailure ? error.message : '获取模型失败，请重试或手动填写',
          error: true,
        );
      }
    } finally {
      client.cancel();
      if (mounted && revision == _modelsRevision) {
        _modelsClient = null;
        setState(() => _fetchingModels = false);
      }
    }
  }

  AiSettings get _settings => AiSettings(
    baseUrl: _url.text.trim(),
    apiKey: _key.text.trim(),
    model: _model.text.trim(),
    provider: _provider,
    protocol: _protocol,
  );

  void _selectProvider(String provider) {
    if (provider == _provider) return;
    _invalidateModels();
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
    _modelsRevision++;
    _modelsClient?.cancel();
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
    onChanged: name == 'url' || name == 'key'
        ? (_) => _invalidateModels()
        : null,
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
    T? value,
    Map<T, String> options,
    ValueChanged<T> onChanged, {
    TextEditingController? controller,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => DropdownMenu<T>(
        key: ValueKey('ai-setting-$name'),
        width: constraints.maxWidth,
        initialSelection: value,
        controller: controller,
        menuController: controller == null ? null : _modelsMenu,
        hintText: controller == null ? null : '输入或选择模型',
        enabled: !_saving,
        selectOnly: controller == null,
        requestFocusOnTap: true,
        enableSearch: false,
        enableFilter: controller != null,
        filterCallback: controller == null
            ? null
            : (entries, query) =>
                  options.containsKey(query) || query == _modelsQueryAtFetch
                  ? entries
                  : entries
                        .where(
                          (entry) => entry.label.toLowerCase().contains(
                            query.toLowerCase(),
                          ),
                        )
                        .toList(),
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
              trailingIcon: entry.key == (controller?.text ?? value)
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
                backgroundColor: entry.key == (controller?.text ?? value)
                    ? colors.secondaryContainer
                    : null,
                foregroundColor: entry.key == (controller?.text ?? value)
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
            control: _dropdown(
              'protocol',
              _protocol,
              {
                AiProtocol.openai: 'OpenAI 兼容',
                AiProtocol.anthropic: 'Anthropic 兼容',
              },
              (value) {
                _invalidateModels();
                setState(() => _protocol = value);
              },
            ),
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
            control: Row(
              children: [
                Expanded(
                  child: _dropdown<String>(
                    'model',
                    null,
                    {for (final model in _models) model: model},
                    (value) => setState(() => _model.text = value),
                    controller: _model,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const ValueKey('ai-fetch-models'),
                  onPressed: _saving || _fetchingModels ? null : _fetchModels,
                  child: _fetchingModels
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('获取'),
                ),
              ],
            ),
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
