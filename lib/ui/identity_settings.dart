import 'package:flutter/material.dart';

import '../domain/host.dart';
import '../domain/network_identity.dart';
import 'expressive_widgets.dart';
import 'settings_page.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';
import 'theme.dart';

class IdentitySettings extends StatefulWidget {
  const IdentitySettings({
    super.key,
    required this.controller,
    required this.navigation,
  });
  final SyncSettingsController controller;

  /// Holds the open identity, so the page header shows its name and the
  /// shared back button returns to the list.
  final SettingsNavigation navigation;

  @override
  State<IdentitySettings> createState() => _IdentitySettingsState();
}

class _IdentitySettingsState extends State<IdentitySettings> {
  bool _saving = false;

  void _open(NetworkIdentity identity) =>
      widget.navigation.openSubpage(identity.id, identity.name);

  Future<bool> _save(NetworkIdentities value) async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveNetworkIdentities(value);
      return true;
    } catch (_) {
      if (mounted) showSettingsNotice(context, '身份保存失败，请重试', error: true);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _replace(NetworkIdentity identity) {
    final current = widget.controller.networkIdentities;
    return _save(
      current.copyWith(
        identities: [
          for (final item in current.identities)
            item.id == identity.id ? identity : item,
        ],
      ),
    );
  }

  Future<String?> _askName({required String title, String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showExpressiveDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const ValueKey('identity-name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '身份名称',
            hintText: '例如：公司内网、frp 穿透',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('identity-name-save'),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final name = await _askName(title: '新建身份');
    if (!mounted || name == null || name.isEmpty) return;
    final identity = NetworkIdentity(
      id: 'identity-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
    );
    final current = widget.controller.networkIdentities;
    if (await _save(
          current.copyWith(identities: [...current.identities, identity]),
        ) &&
        mounted) {
      _open(identity);
    }
  }

  Future<void> _rename(NetworkIdentity identity) async {
    final name = await _askName(title: '重命名身份', initial: identity.name);
    if (!mounted || name == null || name.isEmpty || name == identity.name) {
      return;
    }
    if (await _replace(
          NetworkIdentity(
            id: identity.id,
            name: name,
            overrides: identity.overrides,
          ),
        ) &&
        mounted &&
        widget.navigation.subpage == identity.id) {
      widget.navigation.openSubpage(identity.id, name);
    }
  }

  Future<void> _delete(NetworkIdentity identity) async {
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除身份？'),
        content: Text('将删除「${identity.name}」的地址与端口替换规则，连接本身不受影响。'),
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
    final current = widget.controller.networkIdentities;
    if (await _save(
          current.copyWith(
            identities: [
              for (final item in current.identities)
                if (item.id != identity.id) item,
            ],
          ),
        ) &&
        mounted) {
      widget.navigation.closeSubpage();
    }
  }

  Future<void> _editRule(NetworkIdentity identity, [String? hostId]) async {
    final hosts = widget.controller.hosts;
    final rule = await showExpressiveDialog<(String, EndpointOverride)>(
      context: context,
      builder: (_) => IdentityRuleEditor(
        hosts: hostId == null
            ? [
                for (final host in hosts)
                  if (!identity.overrides.containsKey(host.id)) host,
              ]
            : hosts.where((host) => host.id == hostId).toList(),
        hostId: hostId,
        initial: hostId == null ? null : identity.overrides[hostId],
      ),
    );
    if (!mounted || rule == null) return;
    await _replace(
      NetworkIdentity(
        id: identity.id,
        name: identity.name,
        overrides: {...identity.overrides, rule.$1: rule.$2},
      ),
    );
  }

  Future<void> _deleteRule(NetworkIdentity identity, String hostId) => _replace(
    NetworkIdentity(
      id: identity.id,
      name: identity.name,
      overrides: {...identity.overrides}..remove(hostId),
    ),
  );

  /// Right-click on desktop, long press on touch: the same rename/delete menu.
  Future<void> _identityMenu(NetworkIdentity identity, Offset position) async {
    if (_saving) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final anchorX = point.dx + 4;
    final colors = Theme.of(context).colorScheme;
    Widget item(IconData icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: colors.primary),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
    final action = await showMenu<String>(
      context: context,
      clipBehavior: Theme.of(context).windowBackdrop.frosted
          ? Clip.antiAlias
          : Clip.none,
      popUpAnimationStyle: HarborMotion.popup(context),
      position: RelativeRect.fromLTRB(anchorX, point.dy, anchorX, 0),
      items: [
        if (Theme.of(context).windowBackdrop.frosted)
          const HarborPopupMenuBackdrop<String>(),
        HarborPopupMenuItem(
          key: const ValueKey('identity-rename'),
          value: 'rename',
          child: item(Icons.edit_outlined, '重命名'),
        ),
        HarborPopupMenuItem(
          key: const ValueKey('identity-delete'),
          value: 'delete',
          child: item(Icons.delete_outline_rounded, '删除'),
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'rename') await _rename(identity);
    if (action == 'delete') await _delete(identity);
  }

  Widget _list(NetworkIdentities value) {
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return SettingsList(
      children: [
        RadioGroup<String>(
          groupValue: value.activeId,
          onChanged: (id) {
            if (!_saving && id != null && id != value.activeId) {
              _save(value.copyWith(activeId: id));
            }
          },
          child: SettingsGroup(
            children: [
              RadioListTile<String>(
                key: const ValueKey('identity-default'),
                value: '',
                enabled: !_saving,
                title: const Text('默认'),
                subtitle: const Text('使用每个连接自己的地址和端口'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              for (final identity in value.identities)
                GestureDetector(
                  onSecondaryTapUp: (details) =>
                      _identityMenu(identity, details.globalPosition),
                  onLongPressStart: touch
                      ? (details) =>
                            _identityMenu(identity, details.globalPosition)
                      : null,
                  child: ListTile(
                    key: ValueKey('identity-open-${identity.id}'),
                    enabled: !_saving,
                    leading: Radio<String>(
                      key: ValueKey('identity-${identity.id}'),
                      value: identity.id,
                      enabled: !_saving,
                    ),
                    title: Text(identity.name),
                    subtitle: Text(
                      identity.overrides.isEmpty
                          ? '还没有替换规则'
                          : '${identity.overrides.length} 条替换规则',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(identity),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const ValueKey('identity-add'),
            onPressed: _saving ? null : _create,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新建身份'),
          ),
        ),
      ],
    );
  }

  Widget _detail(NetworkIdentity identity) {
    final type = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final hosts = {for (final host in widget.controller.hosts) host.id: host};
    final available = hosts.keys.any(
      (id) => !identity.overrides.containsKey(id),
    );
    String target(EndpointOverride rule, Host? host) {
      final address = rule.address.isEmpty ? host?.address ?? '' : rule.address;
      final port = rule.port ?? host?.port;
      return port == null ? address : '$address:$port';
    }

    return SettingsList(
      children: [
        if (identity.overrides.isEmpty)
          Material(
            color: colors.surfaceContainerLow,
            shape: HarborShapes.superellipse(HarborShapes.tile),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  ExpressiveMark(
                    size: 64,
                    flower: true,
                    icon: Icons.alt_route_rounded,
                    color: colors.secondaryContainer,
                    foreground: colors.onSecondaryContainer,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '还没有替换规则',
                    textAlign: TextAlign.center,
                    style: type.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hosts.isEmpty
                        ? '先新建连接，再回来添加规则'
                        : '添加规则后，选中此身份时对应连接改用新的地址和端口',
                    textAlign: TextAlign.center,
                    style: type.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          SettingsGroup(
            children: [
              for (final entry in identity.overrides.entries)
                ListTile(
                  key: ValueKey('identity-rule-${entry.key}'),
                  enabled: !_saving,
                  leading: const Icon(Icons.alt_route_rounded),
                  title: Text(hosts[entry.key]?.name ?? '已删除的连接'),
                  subtitle: Text.rich(
                    TextSpan(
                      children: [
                        if (hosts[entry.key] case final host?)
                          TextSpan(
                            text: '${host.address}:${host.port} → ',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        TextSpan(text: target(entry.value, hosts[entry.key])),
                      ],
                    ),
                  ),
                  onTap: hosts.containsKey(entry.key)
                      ? () => _editRule(identity, entry.key)
                      : null,
                  trailing: IconButton(
                    key: ValueKey('identity-rule-delete-${entry.key}'),
                    tooltip: '删除规则',
                    onPressed: _saving
                        ? null
                        : () => _deleteRule(identity, entry.key),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const ValueKey('identity-rule-add'),
            onPressed: _saving || !available ? null : () => _editRule(identity),
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加规则'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.navigation]),
    builder: (context, _) {
      final value = widget.controller.networkIdentities;
      final open = value.identities
          .where((identity) => identity.id == widget.navigation.subpage)
          .firstOrNull;
      return open == null ? _list(value) : _detail(open);
    },
  );
}

/// Picks one connection and its replacement address/port. Pops the host id
/// with its non-empty [EndpointOverride], or null when cancelled.
class IdentityRuleEditor extends StatefulWidget {
  const IdentityRuleEditor({
    super.key,
    required this.hosts,
    this.hostId,
    this.initial,
  });

  /// Connections the rule may target; editing passes only the rule's own.
  final List<Host> hosts;
  final String? hostId;
  final EndpointOverride? initial;

  @override
  State<IdentityRuleEditor> createState() => _IdentityRuleEditorState();
}

class _IdentityRuleEditorState extends State<IdentityRuleEditor> {
  final _form = GlobalKey<FormState>();
  late String? _hostId = widget.hostId;
  late final _address = TextEditingController(text: widget.initial?.address);
  late final _port = TextEditingController(
    text: widget.initial?.port?.toString(),
  );
  late final TextEditingController _hostQuery =
      TextEditingController(text: _host?.name)..addListener(() {
        // Editing the text after a pick means the user is searching again;
        // only a picked menu entry may satisfy the form.
        if (_hostId != null && _hostQuery.text != _host?.name) {
          setState(() => _hostId = null);
        }
      });

  Host? get _host =>
      widget.hosts.where((host) => host.id == _hostId).firstOrNull;

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    _hostQuery.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop((
      _hostId!,
      EndpointOverride(
        address: _address.text.trim(),
        port: int.tryParse(_port.text.trim()),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final theme = Theme.of(context);
    final host = _host;
    final address = TextFormField(
      key: const ValueKey('identity-rule-address'),
      controller: _address,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: '新地址',
        hintText: host?.address ?? '留空沿用原地址',
      ),
      validator: (value) {
        final text = value!.trim();
        if (RegExp(r'\s|/|@|\[|\]').hasMatch(text)) {
          return '请输入裸 IP 或域名，不含协议前缀';
        }
        return text.isEmpty && _port.text.trim().isEmpty ? '地址和端口至少填写一项' : null;
      },
    );
    final port = TextFormField(
      key: const ValueKey('identity-rule-port'),
      controller: _port,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: '新端口',
        hintText: host == null ? null : '${host.port}',
      ),
      validator: (value) {
        final text = value!.trim();
        if (text.isEmpty) return null;
        final port = int.tryParse(text);
        return port == null || port < 1 || port > 65535 ? '1–65535' : null;
      },
    );
    return Dialog(
      insetPadding: EdgeInsets.all(narrow ? 12 : 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(narrow ? 20 : 28),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.hostId == null ? '添加替换规则' : '编辑替换规则',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      tooltip: '取消',
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) => DropdownMenuFormField<String>(
                    key: const ValueKey('identity-rule-host'),
                    controller: _hostQuery,
                    initialSelection: _hostId,
                    width: constraints.maxWidth,
                    menuHeight: 320,
                    enabled: widget.hostId == null,
                    requestFocusOnTap: true,
                    enableSearch: false,
                    enableFilter: true,
                    filterCallback: (entries, query) {
                      final text = query.trim().toLowerCase();
                      if (text.isEmpty) return entries;
                      final hosts = {
                        for (final host in widget.hosts) host.id: host,
                      };
                      return [
                        for (final entry in entries)
                          if ('${entry.label} ${hosts[entry.value]?.destination}'
                              .toLowerCase()
                              .contains(text))
                            entry,
                      ];
                    },
                    textStyle: theme.textTheme.bodyLarge,
                    inputDecorationTheme: theme.inputDecorationTheme,
                    label: const Text('SSH 连接'),
                    hintText: '搜索名称或地址',
                    alignmentOffset: const Offset(0, 4),
                    dropdownMenuEntries: harborDropdownEntries(context, [
                      for (final host in widget.hosts)
                        DropdownMenuEntry(
                          value: host.id,
                          label: host.name,
                          // Address under the name so a phone-width menu
                          // never squeezes either one.
                          labelWidget: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                host.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                host.destination,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ]),
                    onSelected: (id) => setState(() => _hostId = id),
                    validator: (_) => _host == null ? '请选择连接' : null,
                  ),
                ),
                if (host != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      '原地址 ${host.destination}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth < 380
                      ? Column(
                          children: [address, const SizedBox(height: 16), port],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: address),
                            const SizedBox(width: 12),
                            SizedBox(width: 110, child: port),
                          ],
                        ),
                ),
                const SizedBox(height: 28),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const ValueKey('identity-rule-save'),
                    onPressed: _submit,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
