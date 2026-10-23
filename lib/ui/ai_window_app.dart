import 'dart:async';

import 'package:flutter/material.dart';

import 'ai_window_bridge.dart';
import 'localization.dart';
import 'system_color_scope.dart';
import 'terminal_ai_panel.dart';
import 'theme.dart';
import 'window_frame.dart';

/// Root of the detached AI window (second Flutter engine, `--ai-window`).
///
/// The window renders [TerminalAiPanel] against a [RemoteAiTaskController]: it
/// owns no SSH connection, no API client and no conversation store, it only
/// mirrors the main engine and forwards what the user does. Theme and title bar
/// follow the main window. The panel recognises the standalone mode from
/// `onDock` and lays itself out as a workbench (host header, action rail on
/// large windows) instead of the embedded in-pane layout.
class AiWindowApp extends StatefulWidget {
  const AiWindowApp({super.key});

  @override
  State<AiWindowApp> createState() => _AiWindowAppState();
}

class _AiWindowAppState extends State<AiWindowApp> {
  final controller = RemoteAiTaskController();
  late final Future<void> _ready = controller.initialize();

  /// One composer draft per SSH session, so switching sessions and back
  /// restores the text, the attachments and the transcript scroll offset
  /// instead of keeping a hidden panel alive for every session.
  final _drafts = <String, AiPanelDraft>{};

  @override
  void initState() {
    super.initState();
    controller.addListener(_pruneDrafts);
  }

  /// Drops drafts of sessions the main window has closed. The current session
  /// is always kept, and an empty catalog (before the first mirror arrives) is
  /// never treated as "everything is gone".
  void _pruneDrafts() {
    final live = {for (final session in controller.sessions) session.id};
    if (live.isEmpty) return;
    final current = controller.sessionId;
    _drafts.removeWhere((id, _) => id != current && !live.contains(id));
  }

  @override
  void dispose() {
    controller.removeListener(_pruneDrafts);
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
          locale: harborLocale,
          supportedLocales: harborSupportedLocales,
          localizationsDelegates: harborLocalizationDelegates,
          debugShowCheckedModeBanner: false,
          theme: harborTheme(
            color: appearance.color,
            dynamicScheme: system?.light,
            acrylic: appearance.windowAcrylic && windowAcrylicSupported,
            frosted: appearance.frostedSurfaces,
          ),
          darkTheme: harborTheme(
            brightness: Brightness.dark,
            color: appearance.color,
            dynamicScheme: system?.dark,
            acrylic: appearance.windowAcrylic && windowAcrylicSupported,
            frosted: appearance.frostedSurfaces,
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
              final sessionId = controller.sessionId!;
              return Scaffold(
                body: TerminalAiPanel(
                  // Rebuilding per session gives each one a fresh composer and
                  // transcript state; the draft map carries what the user typed
                  // back in when they return.
                  key: ValueKey('ai-window-$sessionId'),
                  task: controller,
                  hostName: controller.hostName,
                  sessionSelection: controller,
                  draft: _drafts[sessionId],
                  onDraftChanged: (draft) => _drafts[sessionId] = draft,
                  onSettings: controller.settingsAvailable
                      ? () => unawaited(controller.openSettings())
                      : null,
                  // The workbench renders exactly one window action: the dock
                  // button that returns the panel to the main window, where the
                  // task keeps running.
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
