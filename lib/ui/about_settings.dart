import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_update.dart';
import 'app_update_dialog.dart';
import 'expressive_widgets.dart';
import 'settings_widgets.dart';
import 'sync_settings_controller.dart';
import 'theme.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({
    super.key,
    required this.controller,
    this.updaterFactory = AppUpdater.new,
  });
  final SyncSettingsController controller;
  final AppUpdater Function() updaterFactory;

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  late final Future<String> _version = widget
      .updaterFactory()
      .currentVersion()
      .catchError((Object _) => '');
  AppUpdater? _checking;
  UpdateCheck? _result;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _checking?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final updater = _checking = widget.updaterFactory();
    setState(() => _error = null);
    UpdateCheck result;
    try {
      result = await updater.check();
    } on UpdateCancelled {
      return;
    } catch (error) {
      if (mounted) {
        setState(() {
          _checking = null;
          _error = error is UpdateFailure ? error.message : '检查更新失败，请重试';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _checking = null;
      _result = result;
    });
    if (result.available) {
      await showAppUpdateDialog(
        context,
        check: result,
        updaterFactory: widget.updaterFactory,
      );
    }
  }

  Future<void> _setAutoCheck(bool value) async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveUpdatePreferences(
        widget.controller.updatePreferences.copyWith(autoCheck: value),
      );
    } catch (_) {
      if (mounted) showSettingsNotice(context, '更新设置保存失败，请重试', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _open(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // The same notice also covers a missing browser or launcher failure.
    }
    if (mounted) {
      showSettingsNotice(context, '无法打开浏览器，请检查默认浏览器设置', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final preferences = widget.controller.updatePreferences;
      final checking = _checking != null;
      final result = _result;
      final (statusIcon, statusText, statusColor) = _error != null
          ? (Icons.error_outline_rounded, _error!, colors.error)
          : checking
          ? (Icons.sync_rounded, '正在检查更新…', colors.onSurfaceVariant)
          : result == null
          ? (
              Icons.update_rounded,
              '从 GitHub Releases 获取新版本',
              colors.onSurfaceVariant,
            )
          : result.available
          ? (
              Icons.new_releases_outlined,
              '可更新到 v${result.release.version}',
              colors.primary,
            )
          : (Icons.check_circle_outline_rounded, '已是最新版本', colors.primary);
      return SettingsList(
        children: [
          Material(
            color: colors.primaryContainer,
            shape: HarborShapes.superellipse(HarborShapes.hero),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: Row(
                children: [
                  ExpressiveMark(
                    size: 64,
                    flower: true,
                    color: colors.primary,
                    foreground: colors.onPrimary,
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Harbor SSH',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        FutureBuilder<String>(
                          future: _version,
                          builder: (context, snapshot) => Text(
                            key: const ValueKey('about-version'),
                            snapshot.data?.isNotEmpty == true
                                ? '版本 ${snapshot.data}'
                                : '版本信息读取中',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            title: '更新',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ExpressiveSwitcher(
                      spin: true,
                      alignment: Alignment.center,
                      child: Icon(
                        statusIcon,
                        key: ValueKey(statusIcon),
                        size: 22,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('检查更新', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 4),
                          ExpressiveSwitcher(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              statusText,
                              key: ValueKey(statusText),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: statusColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    ExpressiveSwitcher(
                      alignment: AlignmentDirectional.centerEnd,
                      child: result?.available == true && !checking
                          ? FilledButton(
                              key: const ValueKey('update-show'),
                              onPressed: () => showAppUpdateDialog(
                                context,
                                check: result!,
                                updaterFactory: widget.updaterFactory,
                              ),
                              child: const Text('查看'),
                            )
                          : FilledButton.tonal(
                              key: const ValueKey('update-check'),
                              onPressed: checking ? null : _check,
                              child: AnimatedSwitcher(
                                duration: expressiveDuration(context),
                                child: checking
                                    ? const SizedBox.square(
                                        key: ValueKey('checking'),
                                        dimension: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                        ),
                                      )
                                    : const Text('检查'),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              SettingsRow(
                title: '启动时检查',
                description: '有新版本时提示，可跳过某个版本',
                inline: true,
                control: Switch.adaptive(
                  key: const ValueKey('update-auto-check'),
                  value: preferences.autoCheck,
                  onChanged: _saving ? null : _setAutoCheck,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SettingsGroup(
            title: '项目',
            children: [
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('更新日志'),
                trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                onTap: () =>
                    _open(Uri.https('github.com', '/$appRepository/releases')),
              ),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: const Text('源代码'),
                trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                onTap: () => _open(Uri.https('github.com', '/$appRepository')),
              ),
            ],
          ),
        ],
      );
    },
  );
}
