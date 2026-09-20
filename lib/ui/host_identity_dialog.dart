import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/host.dart';

class HostIdentityDialog extends StatefulWidget {
  const HostIdentityDialog({
    super.key,
    required this.host,
    required this.keyType,
    required this.fingerprint,
  });

  final Host host;
  final String keyType, fingerprint;

  @override
  State<HostIdentityDialog> createState() => _HostIdentityDialogState();
}

class _HostIdentityDialogState extends State<HostIdentityDialog> {
  bool _copied = false;

  Future<void> _copyFingerprint() async {
    await Clipboard.setData(ClipboardData(text: widget.fingerprint));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.fingerprint_rounded,
                      color: colors.onPrimaryContainer,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Text('确认服务器身份', style: type.titleLarge)),
                ],
              ),
              const SizedBox(height: 24),
              Text(widget.host.name, style: type.titleMedium),
              const SizedBox(height: 4),
              SelectableText(
                widget.host.destination,
                style: type.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('主机指纹', style: type.labelLarge),
                              Text(
                                widget.keyType,
                                style: type.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _copyFingerprint,
                          tooltip: _copied ? '已复制指纹' : '复制指纹',
                          icon: Icon(
                            _copied ? Icons.check_rounded : Icons.copy_rounded,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      widget.fingerprint,
                        style: type.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        height: 1.6,
                        color: colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '首次连接，请与服务器管理员提供的指纹核对。',
                style: type.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '信任后保存此指纹，发生变化时会阻止连接。',
                style: type.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('信任并连接'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
