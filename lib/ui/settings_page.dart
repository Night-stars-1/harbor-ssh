import 'package:flutter/material.dart';

import 'cloud_sync_settings.dart';
import 'appearance_settings.dart';
import 'local_file_settings.dart';
import 'theme.dart';
import 'settings_widgets.dart';
import 'sidebar_navigation_item.dart';
import 'sync_settings_controller.dart';
import 'workspace_model.dart';

class SettingsNavigation extends ValueNotifier<int?> {
  SettingsNavigation() : super(null);
  String get title => value == null
      ? '设置'
      : value == 0
      ? '本地文件'
      : value == 1
      ? '云同步'
      : '外观';
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.model,
    this.controller,
    this.navigation,
    required this.desktop,
    this.standalone = false,
  }) : assert((model == null) != (controller == null));
  final WorkspaceModel? model;
  final SyncSettingsController? controller;
  final SettingsNavigation? navigation;
  final bool desktop;
  final bool standalone;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final navigation = widget.navigation ?? SettingsNavigation();
  int get _section => navigation.value ?? 2;
  bool get _showDetail => navigation.value != null;
  late final SyncSettingsController controller =
      widget.controller ?? LocalSyncSettingsController(widget.model!);
  @override
  void dispose() {
    if (widget.controller == null) controller.dispose();
    if (widget.navigation == null) navigation.dispose();
    super.dispose();
  }

  static const _titles = ['本地文件', '云同步', '外观'];
  static const _sectionOrder = [2, 0, 1];
  static const _icons = [
    Icons.folder_outlined,
    Icons.cloud_outlined,
    Icons.palette_outlined,
  ];
  static const _descriptions = ['默认目录', 'WebDAV、GitHub Gist 与自动同步', '主题色与显示模式'];

  void _select(int index) => navigation.value = index;

  Widget _frameContent({required bool wide, required Widget child}) {
    if (!widget.desktop || !widget.standalone) return child;
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 0 : 12, 12, 12, 12),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(32),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  Widget _categories({required bool rail}) {
    final colors = Theme.of(context).colorScheme;
    if (rail) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final i in _sectionOrder)
            SidebarNavigationItem(
              key: ValueKey('settings-category-$i'),
              icon: _icons[i],
              title: _titles[i],
              selected: _section == i,
              onTap: () => _select(i),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (slot, i) in _sectionOrder.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Material(
              color: colors.surfaceContainerLow,
              shape: HarborShapes.superellipse(
                HarborShapes.listItem(
                  HarborShapes.listSlot(slot, _titles.length),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: ValueKey('settings-category-$i'),
                leading: Icon(_icons[i], size: 22),
                title: Text(_titles[i]),
                subtitle: Text(_descriptions[i]),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _select(i),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: navigation,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = widget.desktop && constraints.maxWidth >= 700;
        final detail = wide || _showDetail;
        final theme = Theme.of(context);
        return PopScope(
          canPop: widget.navigation != null || wide || !_showDetail,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && widget.navigation == null && !wide && _showDetail) {
              navigation.value = null;
            }
          },
          child: Material(
            color: widget.desktop && widget.standalone
                ? theme.colorScheme.surfaceContainerLow
                : theme.colorScheme.surface,
            child: Row(
              children: [
                if (wide)
                  SizedBox(
                    width: 240,
                    child: Material(
                      color: theme.colorScheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 20, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                              child: Text(
                                '设置',
                                style: theme.textTheme.headlineSmall,
                              ),
                            ),
                            _categories(rail: true),
                            const Spacer(),
                            if (!widget.standalone)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: IconButton(
                                  key: const ValueKey('settings-back'),
                                  onPressed: widget.model!.closeSettings,
                                  icon: const Icon(
                                    Icons.arrow_back_rounded,
                                    semanticLabel: '返回',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: _frameContent(
                    wide: wide,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.desktop)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              wide ? 32 : 16,
                              24,
                              24,
                              24,
                            ),
                            child: Row(
                              children: [
                                if (!wide && _showDetail) ...[
                                  IconButton(
                                    key: const ValueKey(
                                      'settings-category-back',
                                    ),
                                    onPressed: () => navigation.value = null,
                                    icon: const Icon(
                                      Icons.arrow_back_rounded,
                                      semanticLabel: '设置分类',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: Text(
                                    detail ? _titles[_section] : '设置',
                                    style: theme.textTheme.headlineSmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: IndexedStack(
                            index: detail ? _section : _titles.length,
                            children: [
                              ExcludeFocus(
                                excluding: !detail || _section != 0,
                                child: LocalFileSettings(
                                  controller: controller,
                                ),
                              ),
                              ExcludeFocus(
                                excluding: !detail || _section != 1,
                                child: CloudSyncSettings(
                                  controller: controller,
                                ),
                              ),
                              ExcludeFocus(
                                excluding: !detail || _section != 2,
                                child: AppearanceSettings(
                                  controller: controller,
                                ),
                              ),
                              SettingsList(
                                children: [_categories(rail: false)],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
