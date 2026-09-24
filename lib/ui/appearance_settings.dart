import 'package:flutter/material.dart';

import '../domain/appearance.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';
import 'theme.dart';
import 'system_color_scope.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key, required this.controller});
  final SyncSettingsController controller;

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  bool _saving = false;

  Future<void> _save(AppearancePreferences value) async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveAppearance(value);
    } catch (_) {
      if (mounted) showSettingsNotice(context, '主题设置保存失败，请重试', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final appearance = widget.controller.appearance;
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final systemColors = SystemColorScope.of(context);
      return SettingsList(
        children: [
          RadioGroup<AppThemeMode>(
            groupValue: appearance.mode,
            onChanged: (mode) {
              if (!_saving && mode != null && mode != appearance.mode) {
                _save(appearance.copyWith(mode: mode));
              }
            },
            child: SettingsGroup(
              title: '显示模式',
              children: [
                for (final option in [
                  (AppThemeMode.light, '白天', Icons.light_mode_outlined),
                  (AppThemeMode.dark, '夜间', Icons.dark_mode_outlined),
                  (AppThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
                ])
                  RadioListTile<AppThemeMode>(
                    key: ValueKey('theme-mode-${option.$1.name}'),
                    value: option.$1,
                    enabled: !_saving,
                    title: Text(option.$2),
                    secondary: Icon(option.$3, color: colors.onSurfaceVariant),
                    controlAffinity: ListTileControlAffinity.trailing,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            title: '主题色',
            children: [
              SettingsRow(
                title: '动态取色',
                description: systemColors?.loaded == false
                    ? '正在读取系统配色'
                    : systemColors?.available != true
                    ? '系统未提供动态颜色，使用默认配色'
                    : theme.platform == TargetPlatform.android
                    ? '使用系统的壁纸配色'
                    : '跟随系统强调色',
                inline: true,
                control: Switch.adaptive(
                  key: const ValueKey('dynamic-color-toggle'),
                  value: appearance.color == AppThemeColor.dynamic,
                  onChanged: _saving
                      ? null
                      : (enabled) => _save(
                          appearance.copyWith(
                            color: enabled
                                ? AppThemeColor.dynamic
                                : AppThemeColor.defaultColor,
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: [
                    for (final color in AppThemeColor.values.where(
                      (color) => color != AppThemeColor.dynamic,
                    ))
                      _colorOption(color, appearance, theme),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            title: '终端',
            children: [
              SettingsRow(
                title: '默认字体大小',
                description: '只保存在本机，新建终端使用，范围 10–24',
                inline: true,
                control: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('terminal-font-smaller'),
                      tooltip: '减小默认字体',
                      onPressed: _saving || appearance.terminalFontSize <= 10
                          ? null
                          : () => _save(
                              appearance.copyWith(
                                terminalFontSize:
                                    appearance.terminalFontSize - 1,
                              ),
                            ),
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        '${appearance.terminalFontSize}',
                        key: const ValueKey('terminal-font-size'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('terminal-font-larger'),
                      tooltip: '增大默认字体',
                      onPressed: _saving || appearance.terminalFontSize >= 24
                          ? null
                          : () => _save(
                              appearance.copyWith(
                                terminalFontSize:
                                    appearance.terminalFontSize + 1,
                              ),
                            ),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
              ),
              SettingsRow(
                title: '自动换行',
                description: '关闭后长行保持在同一行，可横向滚动。只保存在本机',
                inline: true,
                control: Switch.adaptive(
                  key: const ValueKey('terminal-wrap'),
                  value: appearance.terminalWrap,
                  onChanged: _saving
                      ? null
                      : (enabled) =>
                            _save(appearance.copyWith(terminalWrap: enabled)),
                ),
              ),
              SettingsRow(
                title: '状态刷新间隔',
                description: 'CPU、内存、存储和网络状态。只保存在本机',
                inline: true,
                control: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const ValueKey('status-refresh-interval'),
                    value: appearance.statusRefreshSeconds,
                    borderRadius: BorderRadius.circular(16),
                    onChanged: _saving
                        ? null
                        : (seconds) {
                            if (seconds != null &&
                                seconds != appearance.statusRefreshSeconds) {
                              _save(
                                appearance.copyWith(
                                  statusRefreshSeconds: seconds,
                                ),
                              );
                            }
                          },
                    items: [
                      for (final seconds in statusRefreshIntervalOptions)
                        DropdownMenuItem(
                          value: seconds,
                          child: Text('$seconds 秒'),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );

  Widget _colorOption(
    AppThemeColor color,
    AppearancePreferences appearance,
    ThemeData theme,
  ) {
    final selected = color == appearance.color;
    final palette = harborColorScheme(
      brightness: theme.brightness,
      color: color,
    );
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
    );
    return Semantics(
      label: color.label,
      button: true,
      selected: selected,
      child: SizedBox(
        width: 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: palette.primaryContainer,
              shape: border.copyWith(
                side: selected
                    ? BorderSide(color: palette.primary, width: 2)
                    : BorderSide.none,
              ),
              child: InkWell(
                key: ValueKey('theme-color-${color.name}'),
                customBorder: border,
                onTap: _saving || selected
                    ? null
                    : () => _save(appearance.copyWith(color: color)),
                child: SizedBox.square(
                  dimension: 52,
                  child: Center(
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            color: palette.onPrimaryContainer,
                          )
                        : Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: palette.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(color.label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
