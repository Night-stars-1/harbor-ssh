import 'dart:async';

import 'package:flutter/material.dart';

import 'ai_window_bridge.dart';
import 'system_color_scope.dart';
import 'terminal_ai_panel.dart';
import 'theme.dart';
import 'window_frame.dart';

/// Root of the detached AI window (second Flutter engine, `--ai-window`).
///
/// The window renders the very same [TerminalAiPanel] against a
/// [RemoteAiTaskController]: it owns no SSH connection, no API client and no
/// conversation store, it only mirrors the main engine and forwards what the
/// user does. Theme and title bar follow the main window, so the detached panel
/// is visually identical to the embedded one.
class AiWindowApp extends StatefulWidget {
  const AiWindowApp({super.key});

  @override
  State<AiWindowApp> createState() => _AiWindowAppState();
}

class _AiWindowAppState extends State<AiWindowApp> {
  final controller = RemoteAiTaskController();
  late final Future<void> _ready = controller.initialize();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SystemColorScope(
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final appearance = controller.appearance;
        final system = SystemColorScope.of(context);
        return MaterialApp(
          title: 'AI 助手 · Harbor SSH',
          debugShowCheckedModeBanner: false,
          theme: harborTheme(
            color: appearance.color,
            dynamicScheme: system?.light,
          ),
          darkTheme: harborTheme(
            brightness: Brightness.dark,
            color: appearance.color,
            dynamicScheme: system?.dark,
          ),
          themeMode: flutterThemeMode(appearance.mode),
          builder: (context, child) =>
              WindowsWindowFrame(title: 'AI 助手 · Harbor SSH', child: child!),
          home: FutureBuilder<void>(
            future: _ready,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              if (controller.sessionId == null) {
                return _ClosedPane(onDock: controller.dock);
              }
              return Scaffold(
                body: TerminalAiPanel(
                  task: controller,
                  hostName: controller.hostName,
                  onSettings: controller.settingsAvailable
                      ? () => unawaited(controller.openSettings())
                      : null,
                  // Both the header close button and the dock button return the
                  // panel to the main window; the task keeps running there.
                  onClose: () => unawaited(controller.dock()),
                  onDock: () => unawaited(controller.dock()),
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

/// Shown while no session is mirrored: the SSH pane that owned the session is
/// gone, so there is nothing left to chat with.
class _ClosedPane extends StatelessWidget {
  const _ClosedPane({required this.onDock});

  final Future<void> Function() onDock;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.link_off_rounded,
              size: 40,
              semanticLabel: 'AI 会话已关闭',
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'AI 会话已关闭，请从主窗口重新打开',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.tonal(
              key: const ValueKey('ai-window-dock'),
              onPressed: () => unawaited(onDock()),
              child: const Text('返回主窗口'),
            ),
          ],
        ),
      ),
    ),
  );
}
