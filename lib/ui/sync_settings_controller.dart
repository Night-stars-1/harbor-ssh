import 'package:flutter/foundation.dart';

import '../data/webdav_sync.dart';
import '../data/terminal_ai.dart';
import '../domain/sync_snapshot.dart';
import '../domain/appearance.dart';
import 'workspace_model.dart';

/// Both windows use the main workspace's sync service and storage lock.
abstract class SyncSettingsController extends ChangeNotifier {
  AiSettings get aiSettings;
  Future<void> saveAiSettings(AiSettings settings);
  AppearancePreferences get appearance;
  Future<void> saveAppearance(AppearancePreferences value);
  CloudSyncConfig? get settings;
  bool get busy;
  bool get failed;
  String? get message;
  DateTime? get lastSync;
  String get defaultLocalPath;
  Future<void> saveDefaultLocalPath(String path);
  Future<void> test(CloudSyncConfig settings);
  Future<void> save(CloudSyncConfig settings);
  Future<void> saveGitHubAccount(String token, String login);
  Future<void> sync({SyncConflictChoice? choice});
}

class LocalSyncSettingsController extends SyncSettingsController {
  LocalSyncSettingsController(this.model) {
    model.addListener(notifyListeners);
    model.cloudSync.addListener(notifyListeners);
  }
  final WorkspaceModel model;
  @override
  AiSettings get aiSettings => model.aiSettings;
  @override
  Future<void> saveAiSettings(AiSettings settings) =>
      model.saveAiSettings(settings);
  @override
  AppearancePreferences get appearance => model.appearance.value;
  @override
  Future<void> saveAppearance(AppearancePreferences value) =>
      model.saveAppearance(value);
  @override
  String get defaultLocalPath => model.defaultLocalPath;
  @override
  Future<void> saveDefaultLocalPath(String path) =>
      model.saveDefaultLocalPath(path);
  @override
  CloudSyncConfig? get settings => model.cloudSync.settings;
  @override
  bool get busy => model.saving || model.loading || model.cloudSync.busy;
  @override
  bool get failed => model.cloudSync.failed;
  @override
  String? get message => model.cloudSync.message;
  @override
  DateTime? get lastSync => model.cloudSync.lastSync;
  @override
  Future<void> test(CloudSyncConfig settings) =>
      model.cloudSync.testConnection(settings);
  @override
  Future<void> save(CloudSyncConfig settings) => model.configureSync(settings);
  @override
  Future<void> saveGitHubAccount(String token, String login) =>
      model.saveGitHubAccount(token, login);
  @override
  Future<void> sync({SyncConflictChoice? choice}) =>
      model.syncNow(choice: choice);
  @override
  void dispose() {
    model.removeListener(notifyListeners);
    model.cloudSync.removeListener(notifyListeners);
    super.dispose();
  }
}
