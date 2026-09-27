import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/host.dart';
import 'theme.dart';

/// 选择把公钥安装到哪台已保存的服务器。
///
/// 弹窗只做选择与确认：列出 [hosts] 里每一台服务器的登录账户与地址，
/// 由用户显式点击「安装公钥」后才返回选中的 [Host]，取消返回 null。
/// 不改动凭证、连接配置或任何登录信息。
class PublicKeyTargetDialog extends StatefulWidget {
  const PublicKeyTargetDialog({
    super.key,
    required this.credential,
    required this.publicKey,
    required this.hosts,
    this.liveSessionHostIds = const {},
    this.initialSelection,
  });

  /// 公钥所属的凭证，只用于展示名称。
  final SshUser credential;

  /// 已规范为单行的 OpenSSH 公钥（`<算法> <base64> [注释]`）。
  final String publicKey;

  /// 可选目标：全部已保存的主机。
  final List<Host> hosts;

  /// 已有已连接会话的主机 id：安装时会复用该会话，不会影响其终端。
  final Set<String> liveSessionHostIds;

  /// 打开弹窗时预先选中的主机 id（仅有一台服务器时用于省一步操作）。
  final String? initialSelection;

  /// 用户明确选定目标并点击安装后返回该主机，取消或未选择返回 null。
  static Future<Host?> show(
    BuildContext context, {
    required SshUser credential,
    required String publicKey,
    required List<Host> hosts,
    Set<String> liveSessionHostIds = const {},
  }) => showDialog<Host>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PublicKeyTargetDialog(
      credential: credential,
      publicKey: publicKey,
      hosts: hosts,
      liveSessionHostIds: liveSessionHostIds,
      initialSelection: hosts.length == 1 ? hosts.single.id : null,
    ),
  );

  @override
  State<PublicKeyTargetDialog> createState() => _PublicKeyTargetDialogState();
}

class _PublicKeyTargetDialogState extends State<PublicKeyTargetDialog> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSelection;
    if (initial != null && widget.hosts.any((host) => host.id == initial)) {
      _selectedId = initial;
    }
  }

  Host? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final host in widget.hosts) {
      if (host.id == id) return host;
    }
    return null;
  }

  void _select(Host host) => setState(() => _selectedId = host.id);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final selected = _selected;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.key_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('安装公钥到服务器', style: type.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '只把公钥追加到目标账户的 ~/.ssh/authorized_keys，'
                '不会复制私钥，也不会修改这份凭证或连接配置。',
                style: type.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              _credentialCard(colors, type),
              const SizedBox(height: 16),
              Text('选择目标服务器', style: type.titleSmall),
              const SizedBox(height: 8),
              if (widget.hosts.isEmpty)
                Text(
                  '还没有保存的连接，请先在连接页添加主机及其登录凭证。',
                  style: type.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    primary: false,
                    itemCount: widget.hosts.length,
                    itemBuilder: (context, index) =>
                        _targetTile(widget.hosts[index], colors, type),
                  ),
                ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    key: const ValueKey('public-key-install-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    key: const ValueKey('public-key-install-confirm'),
                    onPressed: selected == null
                        ? null
                        : () => Navigator.of(context).pop(selected),
                    child: const Text('安装公钥'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _credentialCard(ColorScheme colors, TextTheme type) {
    final parts = widget.publicKey.split(' ');
    final algorithm = parts.first;
    final blob = parts.length > 1 ? parts[1] : '';
    final comment = parts.length > 2 ? parts.sublist(2).join(' ') : '';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.credential.name, style: type.titleMedium),
          const SizedBox(height: 4),
          Text(
            comment.isEmpty ? algorithm : '$algorithm · $comment',
            style: type.bodyMedium?.copyWith(color: colors.primary),
          ),
          if (blob.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _shortBlob(blob),
              style: type.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _targetTile(Host host, ColorScheme colors, TextTheme type) {
    final chosen = host.id == _selectedId;
    final live = widget.liveSessionHostIds.contains(host.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: chosen ? colors.secondaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ValueKey('public-key-target-${host.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => _select(host),
          child: Semantics(
            selected: chosen,
            button: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(
                    chosen
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: chosen ? colors.primary : colors.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(host.name, style: type.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          host.destination,
                          style: type.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        if (live) ...[
                          const SizedBox(height: 4),
                          Text(
                            '复用已连接的会话，不会影响正在使用的终端。',
                            style: type.bodySmall?.copyWith(
                              color: colors.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

}

/// `<算法> <base64> [注释]` 的 base64 主体太长，只留首尾便于核对。
String _shortBlob(String blob) => blob.length <= 28
    ? blob
    : '${blob.substring(0, 16)}…${blob.substring(blob.length - 8)}';

const _previewCredential = SshUser(
  id: 'user-1',
  name: '生产部署密钥',
  username: 'deploy',
  authMethod: AuthMethod.privateKey,
  publicKey:
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH0mGm2Yf3D1RSQ0FQ3vVd8dHjK0PqW1sB7uXm9tYzAB deploy@laptop',
);

const _previewHosts = [
  Host(
    id: 'host-1',
    name: '生产服务器',
    address: 'prod.example.com',
    username: 'deploy',
    tags: ['生产'],
    favorite: true,
  ),
  Host(
    id: 'host-2',
    name: '测试环境',
    address: '10.0.0.24',
    username: 'tester',
    port: 2222,
    tags: ['测试'],
  ),
  Host(
    id: 'host-3',
    name: '构建机',
    address: 'ci.example.com',
    username: 'builder',
    authMethod: AuthMethod.privateKey,
    userId: 'user-1',
  ),
];

Widget _previewDialog({
  Brightness brightness = Brightness.light,
  bool live = false,
}) => MaterialApp(
  theme: harborTheme(brightness: brightness),
  home: Scaffold(
    body: Center(
      child: PublicKeyTargetDialog(
        credential: _previewCredential,
        publicKey: _previewCredential.publicKey,
        hosts: _previewHosts,
        liveSessionHostIds: live ? const {'host-1'} : const {},
        initialSelection: 'host-2',
      ),
    ),
  ),
);

@Preview(
  name: 'Public key install target',
  group: 'Harbor SSH · MD3E',
  size: Size(760, 640),
)
Widget harborPublicKeyTargetPreview() => _previewDialog();

@Preview(
  name: 'Public key install target · dark',
  group: 'Harbor SSH · MD3E',
  size: Size(760, 640),
)
Widget harborPublicKeyTargetDarkPreview() =>
    _previewDialog(brightness: Brightness.dark);

@Preview(
  name: 'Public key install target · phone',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 740),
)
Widget harborPublicKeyTargetPhonePreview() => _previewDialog();

@Preview(
  name: 'Public key install target · phone dark',
  group: 'Harbor SSH · MD3E',
  size: Size(390, 740),
)
Widget harborPublicKeyTargetPhoneDarkPreview() =>
    _previewDialog(brightness: Brightness.dark, live: true);
