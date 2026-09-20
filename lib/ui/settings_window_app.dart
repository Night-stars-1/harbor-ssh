import 'package:flutter/material.dart';

import 'settings_page.dart';
import 'settings_window_bridge.dart';
import 'theme.dart';
import 'window_frame.dart';
import 'system_color_scope.dart';

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key});
  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  final controller = RemoteSyncSettingsController();
  late Future<void> ready = controller.initialize();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SystemColorScope(
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: '设置 · Harbor SSH',
        debugShowCheckedModeBanner: false,
        theme: harborTheme(
          color: controller.appearance.color,
          dynamicScheme: SystemColorScope.of(context)?.light,
        ),
        darkTheme: harborTheme(
          brightness: Brightness.dark,
          color: controller.appearance.color,
          dynamicScheme: SystemColorScope.of(context)?.dark,
        ),
        themeMode: flutterThemeMode(controller.appearance.mode),
        builder: (context, child) =>
            WindowsWindowFrame(title: '设置 · Harbor SSH', child: child!),
        home: Scaffold(
          body: FutureBuilder<void>(
            future: ready,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: FilledButton.tonal(
                    onPressed: () =>
                        setState(() => ready = controller.initialize()),
                    child: const Text('无法加载设置，点击重试'),
                  ),
                );
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              return SettingsPage(
                controller: controller,
                desktop: true,
                standalone: true,
              );
            },
          ),
        ),
      ),
    ),
  );
}
