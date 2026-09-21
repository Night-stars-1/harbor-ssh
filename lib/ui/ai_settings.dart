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
  late final _approvalModel = TextEditingController(
    text: widget.controller.aiSettings.approvalModel,
  );
  bool _visible = false, _saving = false;
  late String _provider = widget.controller.aiSettings.provider ?? 'custom';
  late AiProtocol _protocol =
      widget.controller.aiSettings.protocol ?? AiProtocol.openai;
  late String _modelProvider = _provider;
  late String _approvalProvider =
      widget.controller.aiSettings.approvalProvider.trim().isNotEmpty
      ? widget.controller.aiSettings.approvalProvider
      : _provider;
  final _drafts = <String, AiSettings>{};
  final _providerNames = <String, String>{};
  final _models = <String, List<String>>{};
  String? _modelsQueryAtFetch;
  bool _fetchingModels = false;
  String? _fetchingProvider;
  int _modelsRevision = 0;
  TerminalAiClient? _modelsClient;
  final _modelsMenu = MenuController();
  final _approvalModelsMenu = MenuController();

  @override
  void initState() {
    super.initState();
    for (final profile in widget.controller.aiSettings.profiles) {
      _providerNames[profile.id] = profile.name;
      _drafts[profile.id] = AiSettings(
        baseUrl: profile.baseUrl,
        apiKey: profile.apiKey,
        model: profile.defaultModel,
        approvalModel: profile.approvalModel,
        protocol: profile.protocol,
        provider: profile.id,
      );
    }
    _drafts[_provider] = AiSettings(
      baseUrl: widget.controller.aiSettings.baseUrl,
      apiKey: widget.controller.aiSettings.apiKey,
      model: widget.controller.aiSettings.model,
      approvalModel: _approvalProvider == _provider
          ? widget.controller.aiSettings.approvalModel
          : (_drafts[_provider]?.approvalModel ?? ''),
      protocol: widget.controller.aiSettings.protocol,
      provider: _provider,
    );
  }

  AiSettings _copyDraft(
    AiSettings draft, {
    String? model,
    String? approvalModel,
  }) => AiSettings(
    baseUrl: draft.baseUrl,
    apiKey: draft.apiKey,
    model: model ?? draft.model,
    approvalModel: approvalModel ?? draft.approvalModel,
    protocol: draft.protocol,
    provider: draft.provider,
  );

  AiSettings _editingCredentials() => AiSettings(
    baseUrl: _url.text.trim(),
    apiKey: _key.text.trim(),
    model: _modelProvider == _provider
        ? _model.text.trim()
        : (_drafts[_provider]?.model ?? ''),
    approvalModel: _approvalProvider == _provider
        ? _approvalModel.text.trim()
        : (_drafts[_provider]?.approvalModel ?? ''),
    protocol: _protocol,
    provider: _provider,
  );

  AiSettings _credentialsOf(String providerId) {
    if (providerId == _provider) return _editingCredentials();
    final draft = _drafts[providerId];
    if (draft != null) return draft;
    final preset = aiProviderPresets
        .where((value) => value.id == providerId)
        .firstOrNull;
    return AiSettings(
      baseUrl: preset?.baseUrl ?? '',
      protocol: preset?.protocol ?? AiProtocol.openai,
      provider: providerId,
    );
  }

  void _storeEditing() {
    _drafts[_provider] = _editingCredentials();
    _drafts[_modelProvider] = _copyDraft(
      _drafts[_modelProvider] ?? _credentialsOf(_modelProvider),
      model: _model.text.trim(),
    );
    _drafts[_approvalProvider] = _copyDraft(
      _drafts[_approvalProvider] ?? _credentialsOf(_approvalProvider),
      approvalModel: _approvalModel.text.trim(),
    );
  }

  void _invalidateModels() {
    _modelsMenu.close();
    _approvalModelsMenu.close();
    _modelsRevision++;
    _modelsClient?.cancel();
    _modelsClient = null;
    setState(() {
      _models.remove(_provider);
      _fetchingModels = false;
      _fetchingProvider = null;
    });
  }

  Future<void> _fetchModels(
    String providerId,
    MenuController menu,
    TextEditingController query,
  ) async {
    final revision = ++_modelsRevision;
    _modelsClient?.cancel();
    final client = _modelsClient =
        (widget.modelClientFactory ?? TerminalAiClient.new)();
    setState(() {
      _fetchingModels = true;
      _fetchingProvider = providerId;
    });
    try {
      final models = await client.listModels(_credentialsOf(providerId));
      if (!mounted || revision != _modelsRevision) return;
      setState(() {
        _models[providerId] = models;
        _modelsQueryAtFetch = query.text;
      });
      showSettingsNotice(context, '已获取 ${models.length} 个模型');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && revision == _modelsRevision) menu.open();
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
        setState(() {
          _fetchingModels = false;
          _fetchingProvider = null;
        });
      }
    }
  }

  void _selectProvider(String provider) {
    if (provider == _provider) return;
    _storeEditing();
    final previousProvider = _provider;
    final preset = aiProviderPresets
        .where((value) => value.id == provider)
        .firstOrNull;
    final next =
        _drafts[provider] ??
        (provider == 'custom'
            ? _credentialsOf(previousProvider)
            : preset == null
            ? const AiSettings()
            : AiSettings(
                baseUrl: preset.baseUrl,
                protocol: preset.protocol,
                provider: provider,
              ));
    final followModel = _modelProvider == previousProvider;
    final followApproval = _approvalProvider == previousProvider;
    setState(() {
      _provider = provider;
      _protocol = next.protocol ?? AiProtocol.openai;
      _url.text = next.baseUrl;
      _key.text = next.apiKey;
      if (followModel) {
        _modelProvider = provider;
        _model.text = next.model;
      }
      if (followApproval) {
        _approvalProvider = provider;
        _approvalModel.text = next.approvalModel;
      }
      _visible = false;
    });
  }

  void _selectModelProvider(String provider) {
    if (provider == _modelProvider) return;
    _storeEditing();
    final next = _credentialsOf(provider).model;
    setState(() {
      _modelProvider = provider;
      _model.text = next;
    });
  }

  void _selectApprovalProvider(String provider) {
    if (provider == _approvalProvider) return;
    _storeEditing();
    setState(() {
      _approvalProvider = provider;
      _approvalModel.text = _credentialsOf(provider).approvalModel;
    });
  }

  void _setApprovalModel(String value) {
    _approvalModel.text = value;
    final draft = _drafts[_approvalProvider];
    if (draft != null) {
      _drafts[_approvalProvider] = _copyDraft(draft, approvalModel: value);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _modelsRevision++;
    _modelsClient?.cancel();
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _approvalModel.dispose();
    super.dispose();
  }

  Future<String?> _askProviderName({
    required String title,
    required String action,
    String initial = '',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '服务商名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  Future<void> _newProvider() async {
    final name = await _askProviderName(title: '新建服务商', action: '新建');
    if (!mounted || name == null || name.isEmpty) return;
    _storeEditing();
    final id = 'custom-${DateTime.now().microsecondsSinceEpoch}';
    _providerNames[id] = name;
    _drafts[id] = AiSettings(provider: id);
    setState(() {
      _provider = id;
      _protocol = AiProtocol.openai;
      _url.clear();
      _key.clear();
      _visible = false;
    });
  }

  Future<void> _renameProvider() async {
    if (_saving) return;
    final current =
        _providerNames[_provider] ??
        aiProviderPresets
            .where((preset) => preset.id == _provider)
            .map((preset) => preset.name)
            .firstOrNull ??
        _provider;
    final name = await _askProviderName(
      title: '重命名服务商',
      action: '保存',
      initial: current,
    );
    if (!mounted || name == null || name.isEmpty || name == current) return;
    setState(() => _providerNames[_provider] = name);
  }


  bool _isCustomProvider(String id) =>
      id.startsWith('custom-') &&
      !aiProviderPresets.any((preset) => preset.id == id);

  Future<void> _deleteProvider() async {
    if (_saving || !_isCustomProvider(_provider)) return;
    final name = _providerNames[_provider] ?? _provider;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务商？'),
        content: Text('将删除「$name」的配置。'),
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
    if (!mounted || confirmed != true) return;
    final id = _provider;
    if (_fetchingProvider == id) {
      _modelsRevision++;
      _modelsClient?.cancel();
      _modelsClient = null;
    }
    _drafts.remove(id);
    _providerNames.remove(id);
    _models.remove(id);
    final next = _drafts['custom'] ?? const AiSettings(provider: 'custom');
    setState(() {
      _provider = 'custom';
      _protocol = next.protocol ?? AiProtocol.openai;
      _url.text = next.baseUrl;
      _key.text = next.apiKey;
      if (_modelProvider == id) {
        _modelProvider = 'custom';
        _model.text = next.model;
      }
      if (_approvalProvider == id) {
        _approvalProvider = 'custom';
        _approvalModel.text = next.approvalModel;
      }
      if (_fetchingProvider == id) {
        _fetchingModels = false;
        _fetchingProvider = null;
      }
      _visible = false;
    });
  }

  List<AiProviderProfile> _profilesForSave() => [
    for (final entry in _drafts.entries)
      if (entry.key.trim().isNotEmpty &&
          (_isCustomProvider(entry.key) ||
              entry.value.baseUrl.trim().isNotEmpty ||
              entry.value.apiKey.trim().isNotEmpty ||
              entry.value.model.trim().isNotEmpty ||
              entry.value.approvalModel.trim().isNotEmpty ||
              _providerNames.containsKey(entry.key)))
        AiProviderProfile(
          id: entry.key,
          name:
              _providerNames[entry.key] ??
              aiProviderPresets
                  .where((preset) => preset.id == entry.key)
                  .map((preset) => preset.name)
                  .firstOrNull ??
              entry.key,
          baseUrl: entry.value.baseUrl,
          apiKey: entry.value.apiKey,
          defaultModel: entry.value.model,
          approvalModel: entry.value.approvalModel,
          protocol: entry.value.protocol ?? AiProtocol.openai,
        ),
  ];


  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _storeEditing();
      final selected = _credentialsOf(_modelProvider);
      await widget.controller.saveAiSettings(
        AiSettings(
          baseUrl: selected.baseUrl,
          apiKey: selected.apiKey,
          model: _model.text.trim(),
          approvalModel: _approvalModel.text.trim(),
          approvalProvider: _approvalProvider,
          protocol: selected.protocol,
          provider: _modelProvider,
          profiles: _profilesForSave(),
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

  List<String> _modelsFor(String providerId) =>
      _models[providerId] ?? const [];


  Widget _providerOverflow() {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(2),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      alignmentOffset: const Offset(0, 4),
      builder: (context, controller, child) => IconButton(
        key: const ValueKey('ai-provider-more'),
        tooltip: '更多',
        onPressed: _saving
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.more_vert_rounded),
      ),
      menuChildren: [
        MenuItemButton(
          key: const ValueKey('ai-rename-provider'),
          leadingIcon: const Icon(Icons.edit_outlined, size: 20),
          onPressed: _renameProvider,
          child: const Text('重命名'),
        ),
        MenuItemButton(
          key: const ValueKey('ai-delete-provider'),
          leadingIcon: const Icon(Icons.delete_outline_rounded, size: 20),
          onPressed: _isCustomProvider(_provider) ? _deleteProvider : null,
          child: const Text('删除'),
        ),
      ],
    );
  }

  Widget _providerModelRow({
    required String providerField,
    required String modelField,
    required String providerValue,
    required Map<String, String> providerOptions,
    required ValueChanged<String> onProvider,
    required TextEditingController modelController,
    required MenuController modelMenu,
    required ValueChanged<String> onModel,
    required String fetchKey,
    required String fetchProviderId,
    bool clearable = false,
  }) {
    final models = <String, String>{
      if (clearable) '__unset__': '未设置',
      for (final model in _modelsFor(fetchProviderId))
        if (model.isNotEmpty) model: model,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: ValueKey(
            '$providerField-label-${providerOptions[providerValue] ?? providerValue}',
          ),
          child: _dropdown(
            providerField,
            providerValue,
            providerOptions,
            onProvider,
          ),
        ),
        const SizedBox(height: 8),
        _dropdown<String>(
          modelField,
          null,
          models,
          (value) => onModel(value == '__unset__' ? '' : value),
          controller: modelController,
          menuController: modelMenu,
          fetchKey: fetchKey,
          fetchProviderId: fetchProviderId,
          clearable: clearable,
        ),
      ],
    );
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
    MenuController? menuController,
    String? fetchKey,
    String? fetchProviderId,
    bool clearable = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fetching =
        fetchKey != null &&
        _fetchingModels &&
        _fetchingProvider == fetchProviderId;
    return LayoutBuilder(
      builder: (context, constraints) => DropdownMenu<T>(
        key: ValueKey('ai-setting-$name'),
        width: constraints.maxWidth,
        initialSelection: value,
        controller: controller,
        menuController: controller == null
            ? null
            : (menuController ?? _modelsMenu),
        hintText: fetchKey != null || controller == null ? null : '输入或选择模型',
        enabled: !_saving,
        selectOnly: controller == null,
        requestFocusOnTap: true,
        enableSearch: false,
        enableFilter: controller != null,
        filterCallback: controller == null
            ? null
            : (entries, query) {
                if (options.containsKey(query) ||
                    query == _modelsQueryAtFetch ||
                    query.trim().isEmpty) {
                  return entries;
                }
                return [
                  for (final entry in entries)
                    if ((clearable && entry.value == '__unset__') ||
                        entry.label.toLowerCase().contains(
                          query.toLowerCase(),
                        ))
                      entry,
                ];
              },
        textStyle: theme.textTheme.bodyLarge,
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          suffixIconConstraints: fetchKey == null
              ? theme.inputDecorationTheme.suffixIconConstraints
              : const BoxConstraints(minWidth: 96, minHeight: 48),
        ),
        trailingIcon: const Icon(Icons.expand_more_rounded),
        selectedTrailingIcon: const Icon(Icons.expand_less_rounded),
        decorationBuilder: fetchKey == null
            ? null
            : (context, menu) {
                final fetch = fetchProviderId!;
                return InputDecoration(
                  hintText: clearable ? '未设置' : '输入或选择模型',
                  suffixIcon: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          isSelected: menu.isOpen,
                          icon: const Icon(Icons.expand_more_rounded),
                          selectedIcon: const Icon(Icons.expand_less_rounded),
                          onPressed: !_saving
                              ? () =>
                                    menu.isOpen ? menu.close() : menu.open()
                              : null,
                        ),
                        IconButton(
                          key: ValueKey(fetchKey),
                          tooltip: '获取',
                          onPressed: _saving || _fetchingModels
                              ? null
                              : () => _fetchModels(
                                  fetch,
                                  menuController ?? menu,
                                  controller!,
                                ),
                          icon: fetching
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ),
                );
              },


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
  Widget build(BuildContext context) {
    final providerOptions = <String, String>{
      for (final preset in aiProviderPresets) preset.id: preset.name,
      ..._providerNames,
    };
    final providerSelection = providerOptions.containsKey(_provider)
        ? _provider
        : 'custom';
    final modelProviderSelection = providerOptions.containsKey(_modelProvider)
        ? _modelProvider
        : providerSelection;
    final approvalProviderSelection =
        providerOptions.containsKey(_approvalProvider)
        ? _approvalProvider
        : providerSelection;
    return SettingsList(
      children: [
        SettingsGroup(
          title: '服务商',
          children: [
            SettingsRow(
              title: '名称',
              control: Row(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: ValueKey(
                        'provider-label-${_providerNames[_provider] ?? _provider}',
                      ),
                      child: _dropdown(
                        'provider',
                        providerSelection,
                        providerOptions,
                        _selectProvider,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '新建服务商',
                    child: IconButton.filledTonal(
                      onPressed: _saving ? null : _newProvider,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ),
                  _providerOverflow(),
                ],
              ),
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
          ],
        ),
        const SizedBox(height: 24),
        SettingsGroup(
          title: '模型',
          children: [
            SettingsRow(
              title: '默认模型',
              control: _providerModelRow(
                providerField: 'model-provider',
                modelField: 'model',
                providerValue: modelProviderSelection,
                providerOptions: providerOptions,
                onProvider: _selectModelProvider,
                modelController: _model,
                modelMenu: _modelsMenu,
                onModel: (value) => setState(() => _model.text = value),
                fetchKey: 'ai-fetch-models',
                fetchProviderId: _modelProvider,
              ),
            ),
            SettingsRow(
              title: '审批模型',
              description: '未设置时使用默认模型',
              control: _providerModelRow(
                providerField: 'approval-provider',
                modelField: 'approval-model',
                providerValue: approvalProviderSelection,
                providerOptions: providerOptions,
                onProvider: _selectApprovalProvider,
                modelController: _approvalModel,
                modelMenu: _approvalModelsMenu,
                onModel: _setApprovalModel,
                fetchKey: 'ai-fetch-approval-models',
                fetchProviderId: _approvalProvider,
                clearable: true,
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

}
