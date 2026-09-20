import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/host_repository.dart';
import '../data/terminal_ai.dart';
import '../data/local_files.dart';
import '../data/ssh_connection.dart';
import '../data/sync_storage.dart';
import '../data/webdav_sync.dart';
import '../domain/sync_snapshot.dart';
import '../domain/host.dart';
import '../domain/appearance.dart';
import 'file_workspace_model.dart';

class WorkspaceModel extends ChangeNotifier {
  WorkspaceModel(this.repository);
  final HostRepository repository;
  AiSettings aiSettings = const AiSettings();
  static const _aiKey = 'harbor.ai.v1';
  Future<void> _aiWrite = Future.value();

  Future<void> saveAiSettings(AiSettings settings) {
    settings.endpoint;
    final operation = _aiWrite.then((_) async {
      await repository.secrets.write(_aiKey, jsonEncode(settings.toJson()));
      if (_disposed) return;
      aiSettings = settings;
      _notify();
    });
    _aiWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _loadAiSettings() async {
    try {
      final value = await repository.secrets.read(_aiKey);
      if (value != null && !_disposed) {
        aiSettings = AiSettings.fromJson(jsonDecode(value) as Map);
      }
    } catch (_) {
      // A missing or unreadable AI configuration must not block SSH startup.
    }
  }

  final appearance = ValueNotifier(const AppearancePreferences());
  static const _appearanceKey = 'harbor.appearance.v1';
  Future<void> _appearanceWrite = Future.value();

  Future<void> saveAppearance(AppearancePreferences value) {
    final operation = _appearanceWrite.then((_) async {
      await repository.preferences.write(
        _appearanceKey,
        jsonEncode(value.toJson()),
      );
      if (_disposed) return;
      appearance.value = value;
      _notify();
    });
    _appearanceWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _loadAppearance() async {
    try {
      final saved = await repository.preferences.read(_appearanceKey);
      if (saved != null && !_disposed) {
        appearance.value = AppearancePreferences.fromJson(
          jsonDecode(saved) as Map,
        );
      }
    } catch (_) {
      // An unreadable appearance preference must not prevent loading connections.
    }
  }

  late final cloudSync = CloudSync(repository);
  Timer? _syncDelay, _syncPoll;
  List<Host> _hosts = [];
  List<Host> get hosts => List.unmodifiable(_hosts);
  List<SshUser> _users = [];
  List<SshUser> get users => List.unmodifiable(_users);
  final List<SshConnection> _sessions = [];
  List<SshConnection> get sessions => List.unmodifiable(_sessions);
  String? activeSessionId;
  String query = '';
  String? group;
  bool favoritesOnly = false;
  bool showingUsers = false;
  bool showingFiles = false;
  bool showingSettings = false;
  late final fileWorkspace = FileWorkspaceModel();
  static const _localPathKey = 'harbor.files.default-local-path.v1';
  String get defaultLocalPath => fileWorkspace.defaultLocalPath;

  Future<void> saveDefaultLocalPath(String value) async {
    try {
      final path = await LocalFiles.validateDefaultPath(value);
      await repository.preferences.write(_localPathKey, path);
      fileWorkspace.defaultLocalPath = path;
      _notify();
    } on FileSystemException catch (error) {
      throw SyncFailure(error.message);
    }
  }

  bool loading = true, saving = false;
  String? loadError;
  bool _disposed = false;
  int _sequence = 0;
  SshConnection? get activeSession {
    for (final session in _sessions) {
      if (session.id == activeSessionId) return session;
    }
    return null;
  }

  List<String> get groups =>
      _hosts.map((h) => h.group).where((g) => g.isNotEmpty).toSet().toList()
        ..sort();
  List<Host> get filteredHosts =>
      _hosts
          .where(
            (h) =>
                (!favoritesOnly || h.favorite) &&
                (group == null || h.group == group) &&
                '${h.name} ${h.address} ${h.username} ${h.group}'
                    .toLowerCase()
                    .contains(query.toLowerCase()),
          )
          .toList()
        ..sort((a, b) {
          if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
  List<SshUser> get filteredUsers =>
      _users
          .where(
            (u) => '${u.name} ${u.username}'.toLowerCase().contains(
              query.toLowerCase(),
            ),
          )
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  Future<void> initialize() async {
    loading = true;
    loadError = null;
    _notify();
    await _loadAppearance();
    await _loadAiSettings();
    try {
      await SyncStorage(repository).recover();
      _hosts = await repository.loadHosts();
      _users = await repository.loadUsers();
      fileWorkspace.defaultLocalPath =
          await repository.preferences.read(_localPathKey) ?? '';
    } catch (_) {
      loadError = '无法读取本地连接配置，请检查存储权限后重试。';
    }
    loading = false;
    await cloudSync.initialize();
    _configureAutoSync();
    _notify();
  }

  Future<void> configureSync(CloudSyncConfig settings) async {
    await cloudSync.saveSettings(settings);
    _configureAutoSync();
  }

  Future<void> saveGitHubAccount(String token, String login) async {
    await cloudSync.saveGitHubAccount(token, login);
    _configureAutoSync();
  }

  void _configureAutoSync() {
    _syncPoll?.cancel();
    _syncDelay?.cancel();
    if (_disposed || cloudSync.settings?.automatic != true) return;
    _syncPoll = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _scheduleSync(),
    );
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_disposed || cloudSync.settings?.automatic != true) return;
    _syncDelay?.cancel();
    _syncDelay = Timer(const Duration(seconds: 2), () async {
      if (_disposed) return;
      if (saving || loading) {
        _scheduleSync();
        return;
      }
      if (loadError != null) return;
      try {
        await syncNow();
      } catch (_) {
        /* The sync panel exposes the failure. */
      }
    });
  }

  Future<void> syncNow({SyncConflictChoice? choice}) async {
    if (saving || loading) throw const SyncFailure('正在保存或加载，请稍后同步');
    if (loadError != null) throw const SyncFailure('请先恢复本地数据读取后再同步');
    _syncDelay?.cancel();
    saving = true;
    _notify();
    try {
      await cloudSync.synchronize(choice: choice);
    } finally {
      try {
        await SyncStorage(repository).recover();
        _hosts = await repository.loadHosts();
        _users = await repository.loadUsers();
      } catch (_) {
        loadError = '本地同步数据尚未恢复，请检查存储权限后重试';
        rethrow;
      } finally {
        saving = false;
        _notify();
      }
    }
  }

  Future<void> saveHost(Host host, Credentials? credentials) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    saving = true;
    _notify();
    try {
      final previousCredentials = await repository.credentials(host.id);
      await repository.saveCredentials(host.id, credentials);
      final next = [..._hosts];
      final index = next.indexWhere((h) => h.id == host.id);
      if (index < 0) {
        next.add(host);
      } else {
        next[index] = host;
      }
      try {
        await repository.saveHosts(next);
      } catch (_) {
        await repository.saveCredentials(host.id, previousCredentials);
        rethrow;
      }
      _hosts = next;
      _scheduleSync();
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> deleteHost(Host host) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    saving = true;
    _notify();
    try {
      await repository.saveCredentials(host.id, null);
      final next = _hosts.where((h) => h.id != host.id).toList();
      await repository.saveHosts(next);
      _hosts = next;
      _scheduleSync();
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> toggleFavorite(Host host) async {
    if (saving) return;
    saving = true;
    _notify();
    try {
      final next = _hosts
          .map((h) => h.id == host.id ? h.withFavorite(!h.favorite) : h)
          .toList();
      await repository.saveHosts(next);
      _hosts = next;
      _scheduleSync();
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> saveUser(SshUser user, Credentials? credentials) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    saving = true;
    _notify();
    try {
      final previous = await repository.userCredentials(user.id);
      await repository.saveUserCredentials(user.id, credentials);
      final next = [..._users];
      final index = next.indexWhere((u) => u.id == user.id);
      if (index < 0) {
        next.add(user);
      } else {
        next[index] = user;
      }
      try {
        await repository.saveUsers(next);
      } catch (_) {
        await repository.saveUserCredentials(user.id, previous);
        rethrow;
      }
      _users = next;
      _scheduleSync();
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> deleteUser(SshUser user) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    saving = true;
    _notify();
    try {
      await repository.saveUserCredentials(user.id, null);
      final next = _users.where((u) => u.id != user.id).toList();
      await repository.saveUsers(next);
      _users = next;
      _scheduleSync();
    } finally {
      saving = false;
      _notify();
    }
  }

  void search(String value) {
    query = value;
    _notify();
  }

  void filter({
    bool favorites = false,
    String? selectedGroup,
    bool users = false,
  }) {
    showingSettings = false;
    showingFiles = false;
    favoritesOnly = favorites;
    group = selectedGroup;
    showingUsers = users;
    activeSessionId = null;
    _notify();
  }

  void selectSession(String? id) {
    showingSettings = false;
    showingFiles = false;
    activeSessionId = id;
    _notify();
  }

  void connect(Host host, Credentials credentials, TrustHost prompt) {
    showingSettings = false;
    showingFiles = false;
    final session = SshConnection(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      host: host,
    );
    _sessions.add(session);
    activeSessionId = session.id;
    session.addListener(_notify);
    _notify();
    unawaited(session.connect(credentials, repository, prompt));
  }

  void closeSession(SshConnection session) {
    _sessions.remove(session);
    if (activeSessionId == session.id) {
      activeSessionId = _sessions.lastOrNull?.id;
    }
    session.removeListener(_notify);
    session.close();
    session.dispose();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void showFiles() {
    showingSettings = false;
    showingFiles = true;
    _notify();
  }

  void showSettings() {
    showingSettings = true;
    _notify();
  }

  void closeSettings() {
    showingSettings = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncDelay?.cancel();
    _syncPoll?.cancel();
    cloudSync.dispose();
    appearance.dispose();
    fileWorkspace.dispose();
    for (final session in _sessions) {
      session.dispose();
    }
    super.dispose();
  }
}
