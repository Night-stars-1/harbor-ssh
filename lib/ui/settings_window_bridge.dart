import 'dart:async';

import 'package:flutter/services.dart';

import '../data/webdav_sync.dart';
import '../domain/sync_snapshot.dart';
import '../domain/appearance.dart';
import 'sync_settings_controller.dart';

const settingsWindowChannel = MethodChannel('harbor/settings_window');

/// The second engine never creates a repository or an automatic sync timer.
/// Requests run in the original workspace so hosts and sessions stay coherent.
class SettingsWindowHost {
  SettingsWindowHost(this.controller);
  final SyncSettingsController controller;

  void attach() {
    settingsWindowChannel.setMethodCallHandler(handle);
    controller.addListener(_changed);
  }

  Map<String, Object?> get state => {
    'settings': controller.settings?.toJson(),
    'busy': controller.busy,
    'failed': controller.failed,
    'message': controller.message,
    'lastSync': controller.lastSync?.toIso8601String(),
    'appearance': controller.appearance.toJson(),
    'defaultLocalPath': controller.defaultLocalPath,
  };

  void _changed() {
    unawaited(
      settingsWindowChannel
          .invokeMethod<void>('changed', state)
          .catchError((Object _) {}),
    );
  }

  Future<void> open() async {
    await settingsWindowChannel.invokeMethod<void>('open');
    _changed();
  }

  Future<Object?> handle(MethodCall call) async {
    try {
      switch (call.method) {
        case 'state':
          return state;
        case 'saveAppearance':
          await controller.saveAppearance(
            AppearancePreferences.fromJson(call.arguments as Map),
          );
        case 'saveLocalPath':
          await controller.saveDefaultLocalPath(call.arguments as String);
        case 'saveGitHubAccount':
          final account = call.arguments as Map;
          await controller.saveGitHubAccount(
            account['token'] as String,
            account['login'] as String,
          );
        case 'test':
          await controller.test(
            CloudSyncConfig.fromJson(
              Map<String, dynamic>.from(call.arguments as Map),
            ),
          );
        case 'save':
          await controller.save(
            CloudSyncConfig.fromJson(
              Map<String, dynamic>.from(call.arguments as Map),
            ),
          );
        case 'sync':
          final choice = call.arguments as String?;
          await controller.sync(
            choice: choice == null
                ? null
                : SyncConflictChoice.values.byName(choice),
          );
        default:
          throw MissingPluginException('Unknown settings operation');
      }
      return state;
    } on SyncConflict catch (error) {
      throw PlatformException(code: 'conflict', details: error.names);
    } on SyncFailure catch (error) {
      throw PlatformException(code: 'sync', message: error.message);
    } catch (_) {
      throw PlatformException(code: 'settings', message: '操作未完成，请检查设置后重试');
    }
  }

  void dispose() {
    controller.removeListener(_changed);
    settingsWindowChannel.setMethodCallHandler(null);
    controller.dispose();
  }
}

class RemoteSyncSettingsController extends SyncSettingsController {
  Map<Object?, Object?> _state = {};
  bool _disposed = false;
  @override
  AppearancePreferences get appearance =>
      AppearancePreferences.fromJson(_state['appearance'] as Map? ?? {});
  @override
  Future<void> saveAppearance(AppearancePreferences value) =>
      _request('saveAppearance', value.toJson());
  @override
  String get defaultLocalPath => _state['defaultLocalPath'] as String? ?? '';
  @override
  Future<void> saveDefaultLocalPath(String path) =>
      _request('saveLocalPath', path);
  @override
  CloudSyncConfig? get settings => _state['settings'] == null
      ? null
      : CloudSyncConfig.fromJson(
          Map<String, dynamic>.from(_state['settings'] as Map),
        );
  @override
  bool get busy => _state['busy'] == true;
  @override
  bool get failed => _state['failed'] == true;
  @override
  String? get message => _state['message'] as String?;
  @override
  DateTime? get lastSync =>
      DateTime.tryParse(_state['lastSync'] as String? ?? '');

  Future<void> initialize() async {
    settingsWindowChannel.setMethodCallHandler((call) async {
      if (call.method == 'changed') _update(call.arguments);
    });
    await _request('state');
  }

  void _update(Object? state) {
    if (_disposed) return;
    _state = Map<Object?, Object?>.from(state as Map);
    notifyListeners();
  }

  Future<void> _request(String method, [Object? arguments]) async {
    try {
      _update(
        await settingsWindowChannel.invokeMethod<Object?>(method, arguments),
      );
    } on PlatformException catch (error) {
      if (error.code == 'conflict') {
        throw SyncConflict((error.details as List).cast<String>());
      }
      throw SyncFailure(error.message ?? '无法连接主窗口，请重新打开设置');
    }
  }

  @override
  Future<void> test(CloudSyncConfig settings) =>
      _request('test', settings.toJson());
  @override
  Future<void> save(CloudSyncConfig settings) =>
      _request('save', settings.toJson());
  @override
  Future<void> saveGitHubAccount(String token, String login) =>
      _request('saveGitHubAccount', {'token': token, 'login': login});
  @override
  Future<void> sync({SyncConflictChoice? choice}) =>
      _request('sync', choice?.name);
  @override
  void dispose() {
    _disposed = true;
    settingsWindowChannel.setMethodCallHandler(null);
    super.dispose();
  }
}
