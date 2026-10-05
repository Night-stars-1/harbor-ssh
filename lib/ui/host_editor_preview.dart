import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/host.dart';
import 'host_editor.dart';
import 'localization.dart';
import 'theme.dart';

@Preview(
  name: 'SSH jump host · mobile',
  group: 'Harbor SSH · connections',
  size: Size(390, 844),
)
Widget jumpHostMobilePreview() => _preview(Brightness.light);

@Preview(
  name: 'SSH jump host · desktop',
  group: 'Harbor SSH · connections',
  size: Size(760, 900),
)
Widget jumpHostDesktopPreview() => _preview(Brightness.dark);

Widget _preview(Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: harborTheme(brightness: brightness),
  locale: harborLocale,
  supportedLocales: harborSupportedLocales,
  localizationsDelegates: harborLocalizationDelegates,
  home: const _JumpHostPreview(),
);

class _JumpHostPreview extends StatefulWidget {
  const _JumpHostPreview();

  @override
  State<_JumpHostPreview> createState() => _JumpHostPreviewState();
}

class _JumpHostPreviewState extends State<_JumpHostPreview> {
  static const _gateway = Host(
    id: 'preview-gateway',
    name: '堡垒机',
    address: 'gateway.example.com',
    username: 'deploy',
  );
  Host _target = const Host(
    id: 'preview-target',
    name: '内网服务器',
    address: '10.0.0.8',
    username: 'deploy',
    jumpHostId: 'preview-gateway',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _edit());
  }

  Future<void> _edit() => showDialog<void>(
    context: context,
    builder: (_) => HostEditor(
      host: _target,
      hosts: const [_gateway],
      credentials: const Credentials(password: 'preview-password'),
      onSave: (host, _) async => setState(() => _target = host),
      onTest: (_, _) async {},
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(onPressed: _edit, child: const Text('编辑中转连接')),
    ),
  );
}
