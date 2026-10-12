import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_update.dart';
import '../domain/remote_file.dart';
import 'expressive_widgets.dart';
import 'theme.dart';

/// Shows the release in [check] and lets the user download and install it.
///
/// [onSkip] adds a "skip this version" action; automatic prompts pass it so a
/// dismissed release does not come back on every launch.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required UpdateCheck check,
  required AppUpdater Function() updaterFactory,
  ValueChanged<String>? onSkip,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => AppUpdateDialog(
    check: check,
    updaterFactory: updaterFactory,
    onSkip: onSkip,
  ),
);

enum _Phase { ready, downloading, installing, opened, failed }

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.check,
    required this.updaterFactory,
    this.onSkip,
  });
  final UpdateCheck check;
  final AppUpdater Function() updaterFactory;
  final ValueChanged<String>? onSkip;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  _Phase _phase = _Phase.ready;
  String _error = '';
  AppUpdater? _updater;
  final _received = ValueNotifier(0);

  AppRelease get _release => widget.check.release;
  bool get _working =>
      _phase == _Phase.downloading || _phase == _Phase.installing;

  @override
  void dispose() {
    _updater?.cancel();
    _received.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    final asset = _release.asset!;
    final updater = _updater = widget.updaterFactory();
    _received.value = 0;
    setState(() => _phase = _Phase.downloading);
    try {
      final package = await updater.download(
        asset,
        onProgress: (received, _) => _received.value = received,
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.installing);
      await updater.install(package);
      if (!mounted) return;
      if (updater.platform == TargetPlatform.macOS) {
        setState(() => _phase = _Phase.opened);
      } else {
        Navigator.pop(context);
      }
    } on UpdateCancelled {
      if (mounted) setState(() => _phase = _Phase.ready);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = error is UpdateFailure ? error.message : '更新失败，请稍后重试';
      });
    } finally {
      if (identical(_updater, updater)) _updater = null;
    }
  }

  void _cancelDownload() => _updater?.cancel();

  Future<void> _openPage([Uri? uri]) async {
    try {
      if (await launchUrl(
        uri ?? _release.page,
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // The same message covers a missing browser or launcher failure.
    }
    if (mounted) {
      setState(() {
        _phase = _Phase.failed;
        _error = '无法打开浏览器，请检查默认浏览器设置';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final type = theme.textTheme;
    final published = _release.publishedAt?.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final notes = _releaseNotes(_release.notes);
    return PopScope(
      canPop: !_working,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: ExpressiveMark(
                    size: 72,
                    flower: true,
                    icon: Icons.system_update_alt_rounded,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '发现新版本',
                  textAlign: TextAlign.center,
                  style: type.headlineSmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _VersionBadge(
                      label: widget.check.current,
                      background: colors.surfaceContainerHighest,
                      foreground: colors.onSurfaceVariant,
                    ),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                      semanticLabel: '更新到',
                    ),
                    _VersionBadge(
                      key: const ValueKey('update-new-version'),
                      label: _release.version,
                      background: colors.primary,
                      foreground: colors.onPrimary,
                    ),
                  ],
                ),
                if (published != null || _release.asset != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (published != null)
                        '${published.year}/${two(published.month)}/${two(published.day)}',
                      if (_release.asset != null)
                        fileSizeLabel(_release.asset!.size),
                    ].join(' · '),
                    key: const ValueKey('update-meta'),
                    textAlign: TextAlign.center,
                    style: type.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (notes.isNotEmpty)
                  Flexible(
                    child: Material(
                      color: colors.surfaceContainer,
                      shape: HarborShapes.superellipse(
                        const BorderRadius.all(HarborShapes.lg),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: SingleChildScrollView(
                        key: const ValueKey('update-notes'),
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                        child: MarkdownBody(
                          data: notes,
                          styleSheet: MarkdownStyleSheet.fromTheme(theme)
                              .copyWith(
                                p: type.bodyMedium,
                                h2: type.titleSmall?.copyWith(
                                  color: colors.primary,
                                ),
                                h2Padding: const EdgeInsets.only(top: 8),
                                h3: type.titleSmall,
                                listBullet: type.bodyMedium,
                                blockSpacing: 10,
                              ),
                          onTapLink: (_, href, _) {
                            final uri = Uri.tryParse(href ?? '');
                            if (uri != null &&
                                (uri.scheme == 'https' ||
                                    uri.scheme == 'http')) {
                              unawaited(_openPage(uri));
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                AnimatedSize(
                  duration: expressiveDuration(context),
                  curve: expressiveCurve,
                  alignment: Alignment.topCenter,
                  child: _status(context),
                ),
                const SizedBox(height: 20),
                _actionBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final type = theme.textTheme;
    final asset = _release.asset;
    switch (_phase) {
      case _Phase.ready:
        return const SizedBox(width: double.infinity);
      case _Phase.downloading:
      case _Phase.installing:
        return Padding(
          padding: const EdgeInsets.only(top: 20),
          child: ValueListenableBuilder<int>(
            valueListenable: _received,
            builder: (context, received, _) {
              final total = asset!.size;
              final installing = _phase == _Phase.installing;
              final fraction = installing
                  ? null
                  : (received / total).clamp(0.0, 1.0);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          installing ? '正在启动安装程序…' : '正在下载',
                          style: type.titleSmall,
                        ),
                      ),
                      if (!installing)
                        Text(
                          '${(fraction! * 100).floor()}%',
                          style: type.labelLarge?.copyWith(
                            color: colors.primary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    key: const ValueKey('update-progress'),
                    value: fraction,
                    minHeight: 8,
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                    stopIndicatorRadius: 4,
                    trackGap: 4,
                    // Flutter still gates the current M3 indicator behind this
                    // temporary migration flag.
                    // ignore: deprecated_member_use
                    year2023: false,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    installing
                        ? '安装包已通过校验'
                        : [
                            '${fileSizeLabel(received)} / ${fileSizeLabel(total)}',
                            // Only the Windows installer closes the running app.
                            if (asset.name.endsWith('.exe')) '安装时将重启应用',
                          ].join(' · '),
                    style: type.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            },
          ),
        );
      case _Phase.opened:
        return _Banner(
          icon: Icons.check_circle_outline_rounded,
          message: '已打开安装包，请将 Harbor SSH 拖入「应用程序」替换旧版本。',
          background: colors.primaryContainer,
          foreground: colors.onPrimaryContainer,
        );
      case _Phase.failed:
        return _Banner(
          icon: Icons.error_outline_rounded,
          message: _error,
          background: colors.errorContainer,
          foreground: colors.onErrorContainer,
        );
    }
  }

  /// One row: the optional skip action sits on the leading edge, the
  /// dismiss and primary actions on the trailing edge.
  Widget _actionBar() {
    final asset = _release.asset;
    final onSkip = widget.onSkip;
    void close() => Navigator.pop(context);
    final Widget? leading = onSkip != null && _phase == _Phase.ready
        ? TextButton(
            key: const ValueKey('update-skip'),
            onPressed: () {
              onSkip(_release.version);
              close();
            },
            child: const Text('跳过此版本'),
          )
        : null;
    final trailing = switch (_phase) {
      _Phase.downloading => [
        TextButton(
          key: const ValueKey('update-cancel'),
          onPressed: _cancelDownload,
          child: const Text('取消下载'),
        ),
      ],
      _Phase.installing => const <Widget>[],
      _Phase.opened => [
        FilledButton(onPressed: close, child: const Text('完成')),
      ],
      _Phase.ready || _Phase.failed => [
        TextButton(
          key: const ValueKey('update-later'),
          onPressed: close,
          child: Text(_phase == _Phase.failed ? '关闭' : '稍后'),
        ),
        FilledButton(
          key: ValueKey(asset == null ? 'update-open-page' : 'update-install'),
          autofocus: true,
          onPressed: asset == null ? _openPage : _update,
          child: Text(
            asset == null
                ? '前往下载'
                : _phase == _Phase.failed
                ? '重试'
                : '立即更新',
          ),
        ),
      ],
    };
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: leading,
          ),
        ),
        for (final (i, action) in trailing.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          action,
        ],
      ],
    );
  }
}

/// Release notes without the download table; the dialog installs directly.
String _releaseNotes(String notes) {
  final downloads = RegExp(r'^##\s*下载\s*$', multiLine: true).firstMatch(notes);
  return (downloads == null ? notes : notes.substring(0, downloads.start))
      .trim();
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });
  final String label;
  final Color background, foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(color: background, shape: HarborShapes.pill),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Text(
        'v$label',
        style: Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    required this.background,
    required this.foreground,
  });
  final IconData icon;
  final String message;
  final Color background, foreground;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Material(
      color: background,
      shape: HarborShapes.superellipse(const BorderRadius.all(HarborShapes.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
