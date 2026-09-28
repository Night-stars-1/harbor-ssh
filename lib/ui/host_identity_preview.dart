import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/host.dart';
import 'host_identity_dialog.dart';
import 'theme.dart';

@Preview(
  name: 'Host fingerprint conflict',
  group: 'Harbor SSH · MD3E',
  size: Size(720, 820),
)
Widget harborHostKeyConflictPreview() => _preview(Brightness.light);

@Preview(
  name: 'Host fingerprint conflict · dark',
  group: 'Harbor SSH · MD3E',
  size: Size(720, 820),
)
Widget harborHostKeyConflictDarkPreview() => _preview(Brightness.dark);

@Preview(
  name: 'Host fingerprint conflict · narrow',
  group: 'Harbor SSH · MD3E',
  size: Size(320, 720),
)
Widget harborHostKeyConflictNarrowPreview() => _preview(Brightness.light);

Widget _preview(Brightness brightness) => MaterialApp(
  theme: harborTheme(brightness: brightness),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const HostIdentityDialog(
              host: Host(
                id: 'preview',
                name: '生产服务器',
                address: 'api.example.com',
                username: 'deploy',
              ),
              keyType: 'ssh-ed25519',
              fingerprint: 'SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG',
              previousKey:
                  'ssh-rsa SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg',
            ),
          ),
          child: const Text('预览指纹冲突确认'),
        ),
      ),
    ),
  ),
);
