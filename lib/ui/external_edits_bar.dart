import 'package:flutter/material.dart';

import '../data/external_files.dart';
import '../domain/remote_file.dart';
import 'expressive_widgets.dart';
import 'file_workspace_model.dart' show fileError;
import 'theme.dart';

/// Files opened in external applications, shown above the file status bar.
///
/// Each row states whether edits are synced, uploading or blocked, and offers
/// the matching action: reopen the copy, upload over a remote change after
/// confirmation, or stop syncing. Hidden when nothing is open.
class ExternalEditsBar extends StatelessWidget {
  const ExternalEditsBar({super.key, required this.edits});
  final ExternalEdits edits;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: edits,
    builder: (context, _) {
      final sessions = edits.sessions;
      if (sessions.isEmpty) return const SizedBox.shrink();
      return Padding(
        key: const ValueKey('external-edits'),
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: HarborShapes.superellipse(),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            // A few rows stay visible; more scroll instead of pushing the
            // file lists off screen.
            constraints: const BoxConstraints(maxHeight: 168),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final session in sessions)
                  _ExternalEditRow(edits: edits, session: session),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ExternalEditRow extends StatelessWidget {
  const _ExternalEditRow({required this.edits, required this.session});
  final ExternalEdits edits;
  final ExternalEditSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final (icon, color, label) = _status(colors);
      final progress =
          session.busy && session.total != null && session.total! > 0
          ? (session.transferred / session.total!).clamp(0.0, 1.0)
          : null;
      return Padding(
        key: ValueKey('external-edit-${session.file.path}'),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 32,
              child: session.busy
                  ? Padding(
                      padding: const EdgeInsets.all(7),
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 2.5,
                      ),
                    )
                  : DecoratedBox(
                      decoration: ShapeDecoration(
                        color: color.withValues(alpha: .14),
                        shape: HarborShapes.superellipse(
                          const BorderRadius.all(HarborShapes.sm),
                        ),
                      ),
                      child: Icon(icon, size: 18, color: color),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    label,
                    key: ValueKey('external-edit-status-${session.file.path}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: session.status == ExternalEditStatus.conflict ||
                              session.status == ExternalEditStatus.failed
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (session.status == ExternalEditStatus.conflict)
              TextButton(
                key: ValueKey('external-edit-overwrite-${session.file.path}'),
                onPressed: () => _overwrite(context),
                child: const Text('仍然上传'),
              ),
            if (session.status == ExternalEditStatus.failed &&
                session.syncedAt != null)
              TextButton(
                key: ValueKey('external-edit-retry-${session.file.path}'),
                onPressed: session.upload,
                child: const Text('重试上传'),
              ),
            if (!session.busy && session.syncedAt != null)
              IconButton(
                key: ValueKey('external-edit-reopen-${session.file.path}'),
                tooltip: '再次打开',
                onPressed: () => _guard(context, session.reopen),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
              ),
            IconButton(
              key: ValueKey('external-edit-stop-${session.file.path}'),
              tooltip: session.syncBack ? '停止同步并删除本机副本' : '删除本机副本',
              onPressed: () => _stop(context),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      );
    },
  );

  (IconData, Color, String) _status(ColorScheme colors) =>
      switch (session.status) {
        ExternalEditStatus.downloading => (
          Icons.download_rounded,
          colors.primary,
          '正在复制到本机${_bytes()}',
        ),
        ExternalEditStatus.uploading => (
          Icons.upload_rounded,
          colors.primary,
          '正在上传修改${_bytes()}',
        ),
        ExternalEditStatus.synced => (
          Icons.sync_rounded,
          colors.primary,
          session.leftoverBackupPath != null
              ? '已上传，但远端临时备份未能删除：${session.leftoverBackupPath}'
              : '外部程序保存后会自动上传 · ${_time(session.syncedAt!)} 已同步',
        ),
        ExternalEditStatus.readOnly => (
          Icons.visibility_outlined,
          colors.onSurfaceVariant,
          '只读副本，修改不会上传',
        ),
        ExternalEditStatus.conflict => (
          Icons.sync_problem_rounded,
          colors.error,
          fileError(session.error!),
        ),
        ExternalEditStatus.failed => (
          Icons.error_outline_rounded,
          colors.error,
          fileError(session.error!),
        ),
      };

  String _bytes() {
    final total = session.total;
    return ' · ${fileSizeLabel(session.transferred)}'
        '${total == null ? '' : ' / ${fileSizeLabel(total)}'}';
  }

  static String _time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Future<void> _overwrite(BuildContext context) async {
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('覆盖远端的修改？'),
        content: Text(
          '「${session.file.name}」在远端已被其他人修改。'
          '仍然上传会用本机副本替换远端内容，对方的修改将丢失。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('external-edit-overwrite-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('覆盖远端'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.upload(overwrite: true);
  }

  /// Stopping while an upload runs cancels it before it publishes, so the
  /// remote file is never left half written; still, unsent edits are lost.
  Future<void> _stop(BuildContext context) async {
    final unsent =
        session.busy || session.status == ExternalEditStatus.conflict;
    if (unsent) {
      final confirmed = await showExpressiveDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('停止同步？'),
          content: Text('「${session.file.name}」的本机修改还没有上传，停止后本机副本会被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('继续同步'),
            ),
            FilledButton(
              key: const ValueKey('external-edit-stop-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('停止并删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await edits.stop(session);
  }

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(fileError(e))));
    }
  }
}
