import 'package:flutter/material.dart';

import '../data/webdav_sync.dart';
import '../domain/sync_snapshot.dart';
import 'sync_settings_controller.dart';
import 'settings_widgets.dart';
import 'github_sign_in.dart';

class CloudSyncSettings extends StatefulWidget {
  const CloudSyncSettings({super.key, required this.controller});
  final SyncSettingsController controller;
  @override
  State<CloudSyncSettings> createState() => _CloudSyncSettingsState();
}

class _CloudSyncSettingsState extends State<CloudSyncSettings> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _encryption = TextEditingController();
  final _gistId = TextEditingController();
  bool _authenticating = false;
  bool _hadGitHubAccount = false;
  SyncProvider _provider = SyncProvider.webdav;
  String _knownGistId = '';
  final _visibleSecrets = <TextEditingController>{};
  bool _automatic = false;
  String? _activeAction;
  String? _lastFailure;

  @override
  void initState() {
    super.initState();
    _lastFailure = widget.controller.failed ? widget.controller.message : null;
    widget.controller.addListener(_onSyncChanged);
    final config = widget.controller.settings;
    if (config != null) {
      _provider = config.provider;
      _gistId.text = config.gistId;
      _knownGistId = config.gistId;
      _url.text = config.url;
      _username.text = config.username;
      _password.text = config.password;
      _encryption.text = config.encryptionPassword;
      _automatic = config.automatic;
    }
  }

  void _onSyncChanged() {
    final config = widget.controller.settings;
    if (config != null && config.gistId != _knownGistId) {
      if (_knownGistId.isEmpty &&
          _gistId.text.trim().isEmpty &&
          config.gistId.isNotEmpty) {
        setState(() => _gistId.text = config.gistId);
      }
      _knownGistId = config.gistId;
    }
    final failure = widget.controller.failed ? widget.controller.message : null;
    final changed = failure != _lastFailure;
    _lastFailure = failure;
    if (failure != null && changed && _activeAction == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showSettingsNotice(context, failure, error: true);
      });
    }
  }

  @override
  void didUpdateWidget(covariant CloudSyncSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onSyncChanged);
      _lastFailure = widget.controller.failed
          ? widget.controller.message
          : null;
      widget.controller.addListener(_onSyncChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSyncChanged);
    for (final field in [_url, _username, _password, _encryption, _gistId]) {
      field.dispose();
    }
    super.dispose();
  }

  CloudSyncConfig get _settings => CloudSyncConfig(
    provider: _provider,
    gistId: _gistId.text.trim(),
    token: widget.controller.settings?.token ?? '',
    githubLogin: widget.controller.settings?.githubLogin ?? '',
    url: _url.text.trim(),
    username: _username.text.trim(),
    password: _password.text,
    encryptionPassword: _encryption.text,
    automatic: _automatic,
  );

  Future<void> _run(String action) async {
    setState(() {
      _activeAction = action;
    });
    try {
      if (action == 'test') {
        await widget.controller.test(_settings);
        if (mounted) {
          showSettingsNotice(context, '${_settings.providerName} 连接成功');
        }
      } else {
        await widget.controller.save(_settings);
        if (action == 'sync') {
          try {
            await widget.controller.sync();
          } on SyncConflict catch (conflict) {
            if (!mounted) return;
            final choice = await showDialog<SyncConflictChoice>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('选择冲突版本'),
                content: SingleChildScrollView(
                  child: Text(
                    '${conflict.names.join('、')}在本机和云端都有更改。\n选择这些冲突项保留的版本，其他更改会自动合并。',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, SyncConflictChoice.remote),
                    child: const Text('保留云端'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, SyncConflictChoice.local),
                    child: const Text('保留本机'),
                  ),
                ],
              ),
            );
            if (choice == null) return;
            await widget.controller.sync(choice: choice);
          }
        }
        if (mounted) {
          showSettingsNotice(context, action == 'sync' ? '同步完成' : '同步设置已保存');
        }
      }
    } catch (error) {
      if (mounted) {
        showSettingsNotice(
          context,
          error is SyncFailure ? error.message : '操作未完成，请检查设置和本地存储后重试',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _activeAction = null);
    }
  }

  Widget _field(
    String name,
    TextEditingController controller, {
    String? hint,
    bool secret = false,
    bool enabled = true,
  }) {
    final colors = Theme.of(context).colorScheme;
    final visible = _visibleSecrets.contains(controller);
    return Semantics(
      label: name,
      child: TextField(
        key: ValueKey('sync-field-$name'),
        controller: controller,
        enabled: enabled,
        obscureText: secret && !visible,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: hint ?? name,
          fillColor: colors.surfaceContainerHighest,
          suffixIcon: secret
              ? IconButton(
                  onPressed: enabled
                      ? () => setState(() {
                          if (visible) {
                            _visibleSecrets.remove(controller);
                          } else {
                            _visibleSecrets.add(controller);
                          }
                        })
                      : null,
                  icon: Icon(
                    visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    semanticLabel: visible ? '隐藏$name' : '显示$name',
                  ),
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final sync = widget.controller;
      final busy = _activeAction != null || sync.busy || _authenticating;
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final last = sync.settings?.provider == _provider
          ? sync.lastSync?.toLocal()
          : null;
      String two(int value) => value.toString().padLeft(2, '0');
      return SettingsList(
        children: [
          SettingsGroup(
            title: '同步服务',
            children: [
              SettingsRow(
                title: '服务商',
                control: LayoutBuilder(
                  builder: (context, constraints) => DropdownMenu<SyncProvider>(
                    key: const ValueKey('sync-provider'),
                    initialSelection: _provider,
                    width: constraints.maxWidth,
                    enabled: !busy,
                    selectOnly: true,
                    requestFocusOnTap: true,
                    enableSearch: false,
                    textStyle: theme.textTheme.bodyLarge,
                    inputDecorationTheme: theme.inputDecorationTheme,
                    trailingIcon: const Icon(Icons.expand_more_rounded),
                    selectedTrailingIcon: const Icon(Icons.expand_less_rounded),
                    alignmentOffset: const Offset(0, 4),
                    menuStyle: MenuStyle(
                      backgroundColor: WidgetStatePropertyAll(
                        colors.surfaceContainer,
                      ),
                      surfaceTintColor: const WidgetStatePropertyAll(
                        Colors.transparent,
                      ),
                      elevation: const WidgetStatePropertyAll(2),
                      padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    dropdownMenuEntries: [
                      for (final provider in SyncProvider.values)
                        DropdownMenuEntry(
                          value: provider,
                          label: provider == SyncProvider.webdav
                              ? 'WebDAV'
                              : 'GitHub Gist',
                          trailingIcon: provider == _provider
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
                            backgroundColor: provider == _provider
                                ? colors.secondaryContainer
                                : null,
                            foregroundColor: provider == _provider
                                ? colors.onSecondaryContainer
                                : colors.onSurface,
                            textStyle: theme.textTheme.bodyLarge,
                          ),
                        ),
                    ],
                    onSelected: (value) {
                      if (value != null) setState(() => _provider = value);
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_provider == SyncProvider.gist)
            SettingsGroup(
              title: 'GitHub Gist',
              children: [
                GitHubSignIn(
                  controller: widget.controller,
                  enabled: _activeAction == null && !sync.busy,
                  onBusyChanged: (value) => setState(() {
                    if (value) {
                      _hadGitHubAccount =
                          widget.controller.settings?.token.isNotEmpty == true;
                    }
                    _authenticating = value;
                    if (!value &&
                        _hadGitHubAccount &&
                        widget.controller.settings?.token.isEmpty == true) {
                      _automatic = false;
                    }
                  }),
                ),
                SettingsRow(
                  title: 'Gist ID',
                  description: '留空时首次同步创建 Secret Gist',
                  control: _field(
                    'Gist ID',
                    _gistId,
                    hint: 'Gist ID 或链接',
                    enabled: !busy,
                  ),
                ),
              ],
            )
          else
            SettingsGroup(
              title: 'WebDAV 服务',
              children: [
                SettingsRow(
                  title: '目录地址',
                  description: '坚果云或自建服务中的已有目录',
                  control: _field(
                    '目录地址',
                    _url,
                    hint: 'https://dav.example.com/HarborSSH/',
                    enabled: !busy,
                  ),
                ),
                SettingsRow(
                  title: '用户名',
                  control: _field('用户名', _username, enabled: !busy),
                ),
                SettingsRow(
                  title: '密码',
                  description: 'WebDAV 密码或应用密码',
                  control: _field(
                    '密码 / 应用密码',
                    _password,
                    secret: true,
                    enabled: !busy,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 24),
          SettingsGroup(
            title: '同步偏好',
            children: [
              SettingsRow(
                title: '加密密码',
                description: '各设备使用相同密码，至少 12 个字符',
                control: _field(
                  '加密密码',
                  _encryption,
                  secret: true,
                  enabled: !busy,
                ),
              ),
              SettingsRow(
                title: '自动同步',
                description: '保存后同步，每两分钟检查更新',
                inline: true,
                control: Switch.adaptive(
                  value: _automatic,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => _automatic = value),
                ),
              ),
            ],
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '上次同步  ${last.year}-${two(last.month)}-${two(last.day)}  ${two(last.hour)}:${two(last.minute)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => _run('test'),
                child: Text(_activeAction == 'test' ? '测试中…' : '测试连接'),
              ),
              FilledButton.tonal(
                onPressed: busy ? null : () => _run('save'),
                child: Text(_activeAction == 'save' ? '保存中…' : '保存'),
              ),
              FilledButton(
                onPressed: busy ? null : () => _run('sync'),
                child: Text(
                  _activeAction == 'sync' || sync.busy ? '同步中…' : '保存并同步',
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}
