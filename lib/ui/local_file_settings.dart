import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/webdav_sync.dart';
import 'sync_settings_controller.dart';
import 'settings_widgets.dart';

class LocalFileSettings extends StatefulWidget {
  const LocalFileSettings({super.key, required this.controller});
  final SyncSettingsController controller;
  @override
  State<LocalFileSettings> createState() => _LocalFileSettingsState();
}

class _LocalFileSettingsState extends State<LocalFileSettings> {
  late final _path = TextEditingController(
    text: widget.controller.defaultLocalPath,
  );
  bool _working = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    setState(() => _working = true);
    try {
      final saved = widget.controller.defaultLocalPath;
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: '选择默认本地文件夹',
        initialDirectory: saved.isEmpty ? null : saved,
      );
      if (mounted && path != null) {
        setState(() {
          _path.text = path;
        });
      }
    } catch (_) {
      if (mounted) {
        showSettingsNotice(context, '无法打开目录选择器，请手动填写路径', error: true);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _save({bool reset = false}) async {
    setState(() {
      _working = true;
    });
    try {
      await widget.controller.saveDefaultLocalPath(reset ? '' : _path.text);
      if (mounted) {
        setState(() {
          _path.text = widget.controller.defaultLocalPath;
        });
        showSettingsNotice(
          context,
          _path.text.isEmpty ? '已恢复用户目录' : '默认本地文件路径已保存',
        );
      }
    } catch (error) {
      if (mounted) {
        showSettingsNotice(
          context,
          error is SyncFailure ? error.message : '保存失败，请检查本地存储后重试',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SettingsList(
      children: [
        SettingsGroup(
          title: '文件浏览',
          children: [
            SettingsRow(
              title: '默认本地文件路径',
              description: '打开 SFTP 或新建本地标签时使用',
              control: TextField(
                key: const ValueKey('default-local-path'),
                controller: _path,
                enabled: !_working,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: '用户目录',
                  fillColor: colors.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  suffixIcon: IconButton(
                    onPressed: _working ? null : _choose,
                    icon: const Icon(
                      Icons.folder_open_rounded,
                      semanticLabel: '选择文件夹',
                    ),
                  ),
                ),
              ),
            ),
            SettingsRow(
              title: '恢复默认',
              description: '使用系统用户目录',
              inline: true,
              control: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _working ? null : () => _save(reset: true),
                  child: const Text('恢复用户目录'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _working ? null : _save,
            child: Text(_working ? '处理中…' : '保存'),
          ),
        ),
      ],
    );
  }
}
