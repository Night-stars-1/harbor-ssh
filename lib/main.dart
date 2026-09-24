import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/host_repository.dart';
import 'ui/app.dart';
import 'ui/workspace_model.dart';
import 'ui/window_frame.dart';
import 'ui/settings_window_app.dart';
import 'ui/settings_window_bridge.dart';
import 'ui/sync_settings_controller.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings =
      usesWindowsTitleBar && arguments.contains('--settings-window');
  await initializeWindowsWindow(settings: settings);
  if (settings) {
    runApp(const SettingsWindowApp());
    return;
  }
  final model = WorkspaceModel(
    HostRepository.platform(),
    localDocumentsDirectory: getApplicationDocumentsDirectory,
  );
  final host = usesWindowsTitleBar
      ? (SettingsWindowHost(LocalSyncSettingsController(model))..attach())
      : null;
  runApp(HarborApp(model: model, settingsWindow: host));
}
