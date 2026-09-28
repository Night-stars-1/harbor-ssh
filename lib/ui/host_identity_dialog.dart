import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/host.dart';

class HostIdentityDialog extends StatelessWidget {
  const HostIdentityDialog({
    super.key,
    required this.host,
    required this.keyType,
    required this.fingerprint,
    this.previousKey,
  });

  final Host host;
  final String keyType, fingerprint;
  final String? previousKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final previous = previousKey;
    final changed = previous != null;
    final separator = previous?.indexOf(' ') ?? -1;
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
                      color: changed
                          ? colors.errorContainer
                          : colors.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      changed
                          ? Icons.warning_amber_rounded
                          : Icons.fingerprint_rounded,
                      color: changed
                          ? colors.onErrorContainer
                          : colors.onPrimaryContainer,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      changed ? '主机指纹冲突' : '确认服务器身份',
                      style: type.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text(host.name, style: type.titleMedium),
              const SizedBox(height: 4),
              SelectableText(
                host.destination,
                style: type.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              if (changed) ...[
                Text(
                  '服务器当前指纹与已保存的指纹不一致。这可能是服务器重装或密钥更换，也可能存在中间人攻击。'
                  '请先通过可信渠道向服务器管理员核实新指纹。',
                  style: type.bodyMedium?.copyWith(color: colors.error),
                ),
                const SizedBox(height: 16),
                _FingerprintCard(
                  label: '已保存指纹',
                  keyType: separator < 0
                      ? ''
                      : previous.substring(0, separator),
                  fingerprint: separator < 0
                      ? previous
                      : previous.substring(separator + 1),
                  copyLabel: '复制已保存指纹',
                ),
                const SizedBox(height: 12),
              ],
              _FingerprintCard(
                label: changed ? '当前指纹' : '主机指纹',
                keyType: keyType,
                fingerprint: fingerprint,
                copyLabel: changed ? '复制当前指纹' : '复制指纹',
              ),
              const SizedBox(height: 16),
              Text(
                changed ? '确认后将替换已保存的指纹并继续本次连接。' : '首次连接，请与服务器管理员提供的指纹核对。',
                style: type.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                changed
                    ? '如果无法确认变更原因，请取消连接，原指纹将保留。'
                    : '信任后保存此指纹，发生变化时需要重新核对确认。',
                style: type.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    autofocus: changed,
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(changed ? '取消连接' : '取消'),
                  ),
                  FilledButton(
                    style: changed
                        ? FilledButton.styleFrom(
                            backgroundColor: colors.error,
                            foregroundColor: colors.onError,
                          )
                        : null,
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(changed ? '确认更新并连接' : '信任并连接'),
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

class _FingerprintCard extends StatefulWidget {
  const _FingerprintCard({
    required this.label,
    required this.keyType,
    required this.fingerprint,
    required this.copyLabel,
  });

  final String label, keyType, fingerprint, copyLabel;

  @override
  State<_FingerprintCard> createState() => _FingerprintCardState();
}

class _FingerprintCardState extends State<_FingerprintCard> {
  bool _copied = false;

  Future<void> _copyFingerprint() async {
    await Clipboard.setData(ClipboardData(text: widget.fingerprint));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    return Container(
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
                    Text(widget.label, style: type.labelLarge),
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
                tooltip: _copied ? '已复制指纹' : widget.copyLabel,
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
    );
  }
}
