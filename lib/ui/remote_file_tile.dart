import 'package:flutter/material.dart';

import '../domain/remote_file.dart';
import 'theme.dart';

class RemoteFileTile extends StatelessWidget {
  const RemoteFileTile({
    super.key,
    required this.file,
    required this.onOpen,
    required this.onDownload,
    required this.slot,
    this.enabled = true,
  });
  final RemoteFile file;
  final VoidCallback onOpen, onDownload;
  final HarborListSlot slot;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        final modified = file.modified?.toLocal();
        final date = modified == null
            ? '—'
            : '${modified.year}-${modified.month.toString().padLeft(2, '0')}-${modified.day.toString().padLeft(2, '0')} ${modified.hour.toString().padLeft(2, '0')}:${modified.minute.toString().padLeft(2, '0')}';
        final size = file.isDirectory ? '文件夹' : fileSizeLabel(file.size);
        final shape = HarborShapes.superellipse(HarborShapes.listItem(slot));
        return Material(
          color: colors.surfaceContainerLow,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? (file.isDirectory ? onOpen : onDownload) : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: [
                  Icon(
                    file.isDirectory
                        ? Icons.folder_rounded
                        : file.isLink
                        ? Icons.link_rounded
                        : Icons.description_outlined,
                    color: file.isDirectory
                        ? colors.primary
                        : colors.onSurfaceVariant,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!wide)
                            Text(
                              '$size${file.isLink ? ' · 链接' : ''}',
                              style: type.labelSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (wide) ...[
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 80,
                      child: Text(
                        size,
                        style: type.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: Text(
                        date,
                        style: type.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  IconButton(
                    onPressed: enabled
                        ? (file.isDirectory ? onOpen : onDownload)
                        : null,
                    icon: Icon(
                      file.isDirectory
                          ? Icons.chevron_right_rounded
                          : Icons.download_rounded,
                      semanticLabel:
                          '${file.isDirectory ? '打开' : '下载'} ${file.name}',
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
