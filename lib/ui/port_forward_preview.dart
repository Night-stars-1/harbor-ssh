import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../domain/port_forward.dart';
import 'port_forward_panel.dart';
import 'theme.dart';

@Preview(
  name: 'Port forwarding',
  group: 'Harbor SSH · MD3E',
  size: Size(760, 720),
)
Widget portForwardPreview() => _preview(Brightness.light);
@Preview(
  name: 'Port forwarding · dark',
  group: 'Harbor SSH · MD3E',
  size: Size(760, 720),
)
Widget portForwardDarkPreview() => _preview(Brightness.dark);
@Preview(
  name: 'Port forwarding · narrow',
  group: 'Harbor SSH · MD3E',
  size: Size(320, 720),
)
Widget portForwardNarrowPreview() => _preview(Brightness.light);

Widget _preview(Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: harborTheme(brightness: brightness),
  home: Scaffold(
    body: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: PortForwardPanel(
        hostName: '开发服务器',
        connected: true,
        rules: const [
          PortForwardRule(
            id: 'db',
            name: '数据库',
            type: PortForwardType.local,
            bindPort: 15432,
            targetPort: 5432,
          ),
          PortForwardRule(
            id: 'proxy',
            name: '开发代理',
            type: PortForwardType.dynamic,
            bindPort: 1080,
          ),
        ],
        stateFor: (id) => id == 'db'
            ? const PortForwardState(
                status: PortForwardStatus.running,
                port: 15432,
              )
            : const PortForwardState(),
        onAdd: () {},
        onEdit: (_) {},
        onDelete: (_) {},
        onStart: (_) {},
        onStop: (_) {},
        onClose: () {},
      ),
    ),
  ),
);
