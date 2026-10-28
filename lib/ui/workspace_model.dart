import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/ai_conversation_store.dart';
import '../data/host_repository.dart';
import '../data/terminal_ai.dart';
import '../data/local_files.dart';
import '../data/local_path_access.dart';
import '../data/ssh_connection.dart';
import '../data/startup_failure.dart';
import '../data/sync_storage.dart';
import '../data/webdav_sync.dart';
import '../domain/sync_snapshot.dart';
import '../domain/host.dart';
import '../domain/network_identity.dart';
import '../domain/appearance.dart';
import '../domain/app_update.dart';
import 'file_workspace_model.dart';

class WorkspaceModel extends ChangeNotifier {
  WorkspaceModel(
    this.repository, {
    this.localDocumentsDirectory,
    this.aiHistoryStore,
  });
  final HostRepository repository;
  final Future<Directory> Function()? localDocumentsDirectory;
  final AiConversationStore? aiHistoryStore;
  AiSettings aiSettings = const AiSettings();
  static const _aiKey = 'harbor.ai.v1';
  Future<void> _aiWrite = Future.value();

  Future<void> saveAiSettings(AiSettings settings) {
    // Rejects an unusable address before anything is written.
    settings.modelsEndpoint;
    return _writeAiSettings((_) => settings);
  }

  /// Saves only the model of the stored AI settings, so the model a panel
  /// chose survives the session. Every other field keeps its current value:
  /// the update is computed when the queued write runs, never from a stale
  /// snapshot taken by the caller.
  Future<void> saveAiModel(String model) =>
      _writeAiSettings((current) => current.withModel(model));

  /// One serial queue for every AI write: writes land in call order, and a
  /// failed write leaves [aiSettings] at the last value that was actually
  /// stored.
  Future<void> _writeAiSettings(
    AiSettings Function(AiSettings current) update,
  ) {
    final operation = _aiWrite.then((_) async {
      final next = update(aiSettings);
      await repository.secrets.write(_aiKey, jsonEncode(next.toJson()));
      if (_disposed) return;
      aiSettings = next;
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

  /// Bumped each time saved appearance prefs replace the in-memory defaults.
  /// Views that own a live drag use it to adopt a late restore exactly once,
  /// while ordinary [saveAppearance] notifications leave their local width
  /// alone.
  int appearanceRevision = 0;

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
    final saved = await readAppearance(repository.preferences);
    if (saved != null && !_disposed) {
      appearance.value = saved;
      appearanceRevision++;
    }
  }

  /// The saved appearance, or null when none is stored or it is unreadable.
  /// Also read before the first window is shown, ahead of [initialize].
  static Future<AppearancePreferences?> readAppearance(
    KeyValueStore preferences,
  ) async {
    try {
      final saved = await preferences.read(_appearanceKey);
      return saved == null
          ? null
          : AppearancePreferences.fromJson(jsonDecode(saved) as Map);
    } catch (_) {
      // An unreadable appearance preference must not prevent loading connections.
      return null;
    }
  }

  UpdatePreferences updatePreferences = const UpdatePreferences();
  static const _updateKey = 'harbor.update.v1';
  Future<void> _updateWrite = Future.value();

  Future<void> saveUpdatePreferences(UpdatePreferences value) {
    final operation = _updateWrite.then((_) async {
      await repository.preferences.write(
        _updateKey,
        jsonEncode(value.toJson()),
      );
      if (_disposed) return;
      updatePreferences = value;
      _notify();
    });
    _updateWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _loadUpdatePreferences() async {
    try {
      final saved = await repository.preferences.read(_updateKey);
      if (saved != null && !_disposed) {
        updatePreferences = UpdatePreferences.fromJson(
          jsonDecode(saved) as Map,
        );
      }
    } catch (_) {
      // An unreadable update preference falls back to automatic checks.
    }
  }

  NetworkIdentities networkIdentities = const NetworkIdentities();

  Future<void> saveNetworkIdentities(NetworkIdentities value) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    // Only a definition change needs a cloud round trip; which identity this
    // device uses never leaves it.
    final changed = !SyncSnapshot.same(
      [for (final identity in networkIdentities.identities) identity.toJson()],
      [for (final identity in value.identities) identity.toJson()],
    );
    _saving = true;
    _notify();
    try {
      // 本地提交走仓库锁：与同步的快照/恢复事务串行，锁内只有本地读写。
      await repository.withLocalData(
        () => repository.saveNetworkIdentities(value),
      );
      if (_disposed) return;
      networkIdentities = value;
      if (changed) _scheduleSync();
    } finally {
      _saving = false;
      _notify();
    }
  }

  Future<void> _loadNetworkIdentities() async {
    try {
      final saved = await repository.loadNetworkIdentities();
      if (!_disposed) networkIdentities = saved;
    } catch (_) {
      // Unreadable identities fall back to each connection's own endpoint.
    }
  }

  late final cloudSync = CloudSync(repository);
  Timer? _syncDelay, _syncPoll;
  List<Host> _hosts = [];
  List<Host> get hosts => List.unmodifiable(_hosts);

  /// 会话展示图标对应的主机配置 id：快照只保留建连时的身份，图标以最新的
  /// 已保存主机为准，未保存的主机沿用快照。直接遍历内部列表，避免每个会话
  /// 复制整份 [hosts]。
  String sessionHostIcon(Host snapshot) {
    for (final host in _hosts) {
      if (host.id == snapshot.id) return host.icon;
    }
    return snapshot.icon;
  }

  static const _hostOrderKey = 'harbor.host-order.v1';
  Map<String, int> _hostRank = const {};

  Future<void> _loadHostOrder() async {
    try {
      final saved = await repository.preferences.read(_hostOrderKey);
      if (saved == null || _disposed) return;
      final decoded = jsonDecode(saved);
      if (decoded is! List) return;
      final rank = <String, int>{};
      for (final item in decoded) {
        if (item is! String || rank.containsKey(item)) continue;
        rank[item] = rank.length;
      }
      _hostRank = rank;
    } catch (_) {
      // A corrupt local order must not prevent loading connections.
    }
  }

  /// 本地顺序优先，未登记的主机（含首次排序前的全部主机）回退收藏/名称。
  int _compareHosts(Host a, Host b) {
    final rankA = _hostRank[a.id];
    final rankB = _hostRank[b.id];
    if (rankA != null || rankB != null) {
      if (rankA == null) return 1;
      if (rankB == null) return -1;
      if (rankA != rankB) return rankA.compareTo(rankB);
    }
    if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  /// 把 [sourceId] 移动到当前可见列表中 [targetId] 所在的位置，隐藏主机
  /// 占据的全局槽位保持不动；保存成功后才应用新的本地顺序。
  Future<void> reorderHost(String sourceId, String targetId) async {
    if (saving) return;
    final visible = filteredHosts;
    final source = visible.indexWhere((h) => h.id == sourceId);
    final target = visible.indexWhere((h) => h.id == targetId);
    if (source < 0 || target < 0 || source == target) return;
    final reordered = visible.map((h) => h.id).toList()..removeAt(source);
    reordered.insert(target, sourceId);
    final visibleIds = visible.map((h) => h.id).toSet();
    var cursor = 0;
    final global = [..._hosts]..sort(_compareHosts);
    final next = <String>[
      for (final host in global)
        if (visibleIds.contains(host.id)) reordered[cursor++] else host.id,
    ];
    _saving = true;
    _notify();
    try {
      await repository.preferences.write(_hostOrderKey, jsonEncode(next));
      if (_disposed) return;
      _hostRank = {for (var i = 0; i < next.length; i++) next[i]: i};
    } finally {
      _saving = false;
      _notify();
    }
  }

  List<SshUser> _users = [];
  List<SshUser> get users => List.unmodifiable(_users);
  final List<SshConnection> _sessions = [];
  List<SshConnection> get sessions => List.unmodifiable(_sessions);
  String? activeSessionId;

  /// 切换页面前的终端。列表页的 [filter] 会清空 [activeSessionId]，
  /// 但标题栏的「返回终端」仍要记住目标，因此单独保留；会话关闭后
  /// [lastTerminal] 会因为找不到会话而失效。
  String? _lastTerminalId;
  String query = '';
  String? selectedTag;
  bool ungroupedOnly = false;
  bool favoritesOnly = false;
  bool showingUsers = false;
  bool showingFiles = false;
  bool showingPortForwards = false;
  String? portForwardSessionId;
  int portForwardRequest = 0;
  bool showingSettings = false;
  bool sidebarCollapsed = false;
  late final fileWorkspace = FileWorkspaceModel();
  static const _localPathKey = 'harbor.files.default-local-path.v1';
  String get defaultLocalPath => fileWorkspace.defaultLocalPath;

  Future<void> saveDefaultLocalPath(String value) async {
    final previous = fileWorkspace.defaultLocalPath;
    try {
      final path = await LocalFiles.validateDefaultPath(value);
      await repository.preferences.write(_localPathKey, path);
      try {
        if (path.isEmpty) {
          await LocalPathAccess.clear();
        } else {
          await LocalPathAccess.commit(path);
        }
      } on PlatformException catch (error) {
        await repository.preferences.write(_localPathKey, previous);
        throw SyncFailure(error.message ?? '无法保存目录访问权限');
      }
      fileWorkspace.defaultLocalPath = path;
      _notify();
    } on FileSystemException catch (error) {
      throw SyncFailure(error.message);
    }
  }

  /// 本地文件夹书签只存在本机偏好里：不进入主机数据，也就不参与云同步，
  /// 本机路径不会被带到其他设备。
  List<String> localBookmarks = const [];
  static const _localBookmarksKey = 'harbor.files.local-bookmarks.v1';
  Future<void> _localBookmarkWrite = Future.value();

  /// Windows 路径不区分大小写；其他平台按原样比较。
  static bool sameLocalPath(String a, String b) =>
      Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

  /// 每次只提交一个路径的意图并排队执行，连续收藏、移除按操作顺序落盘。
  Future<void> setLocalBookmark(String path, {required bool saved}) {
    final operation = _localBookmarkWrite.then((_) async {
      final current = localBookmarks;
      final exists = current.any((value) => sameLocalPath(value, path));
      if (saved == exists) return;
      final next = saved
          ? [...current, path]
          : [
              for (final value in current)
                if (!sameLocalPath(value, path)) value,
            ];
      await repository.preferences.write(_localBookmarksKey, jsonEncode(next));
      if (_disposed) return;
      localBookmarks = List.unmodifiable(next);
      _notify();
    });
    _localBookmarkWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _loadLocalBookmarks() async {
    try {
      final saved = await repository.preferences.read(_localBookmarksKey);
      if (saved == null || _disposed) return;
      final decoded = jsonDecode(saved);
      if (decoded is! List) return;
      localBookmarks = List.unmodifiable([
        for (final path in decoded)
          if (path is String && path.isNotEmpty) path,
      ]);
    } catch (_) {
      // Unreadable local bookmarks must not prevent loading connections.
    }
  }

  bool loading = true;

  /// 本地写入占用：书签、主机、用户等本地变更。
  bool _saving = false;

  /// 网络同步占用：仅 [syncNow] 期间为 true。
  bool _syncing = false;

  /// 界面沿用旧语义：本地写入或网络同步任一进行中都显示为保存中。
  bool get saving => _saving || _syncing;
  String? loadError;
  bool _disposed = false;
  int _sequence = 0;
  Future<void> _bookmarkWrite = Future.value();
  Completer<void>? _idleCompleter;
  SshConnection? get activeSession {
    for (final session in _sessions) {
      if (session.id == activeSessionId) return session;
    }
    return null;
  }

  /// 可返回的终端：最近显示过的会话仍在 [sessions] 里才有效，
  /// 关闭后失效，不会退回到另一个会话。
  SshConnection? get lastTerminal {
    final id = _lastTerminalId;
    if (id == null) return null;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  /// 终端真正显示在屏幕上，而不是被页面覆盖。
  bool get showsTerminal =>
      !showingSettings &&
      !showingFiles &&
      !showingPortForwards &&
      activeSession != null;

  /// 仅在页面覆盖终端、且仍有可返回的终端时提供「返回终端」。
  bool get canReturnToTerminal => !showsTerminal && lastTerminal != null;

  /// 离开终端页前记住当前终端，供标题栏的「返回终端」使用。
  void _rememberTerminal() {
    final id = activeSession?.id;
    if (id != null) _lastTerminalId = id;
  }

  void returnToTerminal() {
    final session = lastTerminal;
    if (session != null) selectSession(session.id);
  }

  List<String> get tags =>
      _hosts.expand((h) => h.tags).toSet().toList()..sort();
  List<Host> get filteredHosts =>
      _hosts
          .where(
            (h) =>
                (!favoritesOnly || h.favorite) &&
                (selectedTag == null || h.tags.contains(selectedTag)) &&
                (!ungroupedOnly || h.tags.isEmpty) &&
                '${h.name} ${h.address} ${h.username} ${h.tags.join(' ')}'
                    .toLowerCase()
                    .contains(query.toLowerCase()),
          )
          .toList()
        ..sort(_compareHosts);
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
    await _loadUpdatePreferences();
    await _loadAiSettings();
    await _loadHostOrder();
    await _loadNetworkIdentities();
    await _loadLocalBookmarks();
    var stage = StartupStage.localDirectory;
    try {
      await LocalFiles.prepareDefaultHome(
        directoryProvider: localDocumentsDirectory,
      );
      stage = StartupStage.recovery;
      await SyncStorage(repository).recover();
      // Recovery may have rolled identities back; reload the restored ones.
      await _loadNetworkIdentities();
      stage = StartupStage.hosts;
      final hosts = await repository.loadHosts();
      stage = StartupStage.users;
      final users = await repository.loadUsers();
      _hosts = hosts;
      _users = users;
      stage = StartupStage.localDirectory;
      final savedLocalPath =
          await repository.preferences.read(_localPathKey) ?? '';
      final restoredLocalPath = await LocalFiles.restoreDefaultPath(
        savedLocalPath,
      );
      final normalizedSavedPath = savedLocalPath.replaceAll('\\', '/');
      final pathChanged = restoredLocalPath != normalizedSavedPath;
      if (pathChanged) {
        await repository.preferences.write(_localPathKey, restoredLocalPath);
      }
      try {
        if (restoredLocalPath.isEmpty) {
          await LocalPathAccess.clear();
        } else {
          await LocalPathAccess.commit(restoredLocalPath);
        }
      } on PlatformException {
        if (pathChanged) {
          await repository.preferences.write(_localPathKey, savedLocalPath);
        }
        rethrow;
      }
      fileWorkspace.defaultLocalPath = restoredLocalPath;
    } catch (error) {
      loadError = describeStartupFailure(stage, error);
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

  Future<void> saveGitHubAccount(
    String token,
    String login, {
    String refreshToken = '',
    DateTime? expiresAt,
    DateTime? refreshExpiresAt,
  }) async {
    await cloudSync.saveGitHubAccount(
      token,
      login,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
      refreshExpiresAt: refreshExpiresAt,
    );
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
    _syncing = true;
    _notify();
    try {
      await cloudSync.synchronize(choice: choice);
    } finally {
      try {
        // 本地恢复与重载是仓库事务：只做读取/写入，绝不在网络阶段持有。
        await repository.withLocalData(() async {
          await SyncStorage(repository).recover();
          _hosts = await repository.loadHosts();
          _users = await repository.loadUsers();
          // The applied snapshot may have renamed or deleted identities.
          networkIdentities = await repository.loadNetworkIdentities();
        });
      } catch (_) {
        loadError = '本地同步数据尚未恢复，请检查存储权限后重试';
        rethrow;
      } finally {
        // 只释放网络同步占用，绝不清掉并发书签写入的 _saving。
        _syncing = false;
        _notify();
      }
    }
  }

  /// Saves one edited connection without ever waiting for the network.
  ///
  /// [originalHost] and [originalCredentials] are the values the editor opened
  /// with; both are null for a new connection. They describe this save's
  /// intent, so only what the user actually changed is applied to the host as
  /// it exists on disk now: a bookmark, a password or a field written by a
  /// concurrent sync or another save survives instead of being replaced by the
  /// stale copy the editor was showing.
  ///
  /// Writes queue behind other local commits instead of waiting for the
  /// network: a save that lands while an automatic sync is uploading is folded
  /// back into the sync's final local commit, so the edit is neither blocked
  /// for seconds nor overwritten by the sync it raced with. Deriving from the
  /// on-disk state inside the repository lock keeps a queued edit from
  /// clobbering whatever the sync or another save just wrote, and a connection
  /// deleted underneath the open editor is reported as [SyncConflict] instead
  /// of being resurrected.
  Future<void> saveHost(
    Host host,
    Credentials? credentials, {
    required Host? originalHost,
    required Credentials? originalCredentials,
  }) {
    final id = 'host:${host.id}';
    final operation = _bookmarkWrite.then((_) async {
      await _waitForIdle();
      if (_disposed) throw StateError('工作区已关闭，未保存');
      _saving = true;
      _notify();
      try {
        await repository.withLocalData(() async {
          final latest = await repository.loadHosts();
          final index = latest.indexWhere((h) => h.id == host.id);
          final latestCredentials = index < 0
              ? null
              : await repository.credentials(host.id);
          if (index < 0 && originalHost != null) {
            // The host this editor shows was deleted meanwhile; writing it
            // back would undo that deletion.
            throw SyncConflict([host.name]);
          }
          final merged =
              SyncSnapshot({
                if (index >= 0)
                  id: SyncSnapshot.hostRecord(latest[index], latestCredentials),
              }).rebaseLocalChanges(
                started: SyncSnapshot({
                  if (originalHost != null)
                    id: SyncSnapshot.hostRecord(
                      originalHost,
                      originalCredentials,
                    ),
                }),
                current: SyncSnapshot({
                  id: SyncSnapshot.hostRecord(host, credentials),
                }),
              );
          final record = merged.records[id];
          if (record == null) throw SyncConflict([host.name]);
          final nextHost = Host.fromJson(
            Map<String, dynamic>.from(record['data'] as Map),
          );
          final secret = record['secret'] as Map?;
          final nextCredentials = secret == null
              ? null
              : Credentials.fromJson(Map<String, dynamic>.from(secret));
          final next = [...latest];
          if (index < 0) {
            next.add(nextHost);
          } else {
            next[index] = nextHost;
          }
          final credentialsChanged = nextCredentials != latestCredentials;
          if (credentialsChanged) {
            await repository.saveCredentials(host.id, nextCredentials);
          }
          try {
            await repository.saveHosts(next);
          } catch (_) {
            if (credentialsChanged) {
              await repository.saveCredentials(host.id, latestCredentials);
            }
            rethrow;
          }
          if (_disposed) return;
          _hosts = next;
          _scheduleSync();
        });
      } finally {
        _saving = false;
        _notify();
      }
    });
    _bookmarkWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> deleteHost(Host host) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    _saving = true;
    _notify();
    try {
      await repository.saveCredentials(host.id, null);
      final next = _hosts.where((h) => h.id != host.id).toList();
      await repository.saveHosts(next);
      _hosts = next;
      _scheduleSync();
    } finally {
      _saving = false;
      _notify();
    }
  }

  Future<void> toggleFavorite(Host host) async {
    if (saving) return;
    _saving = true;
    _notify();
    try {
      final next = _hosts
          .map((h) => h.id == host.id ? h.withFavorite(!h.favorite) : h)
          .toList();
      await repository.saveHosts(next);
      _hosts = next;
      _scheduleSync();
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// 单个收藏路径的写入排队执行：保存后立刻删除不会因为前一次写入或同步
  /// 占用而被拒绝。
  ///
  /// 每次只提交一个路径的意图，并在本地事务内基于磁盘最新主机派生结果，
  /// 因此即使短暂排在同步的本地提交之后，也不会用菜单里的旧整表覆盖掉
  /// 云端新增的其它收藏或其它字段。
  Future<void> setSftpBookmark(
    String hostId,
    String path, {
    required bool saved,
  }) {
    final operation = _bookmarkWrite.then((_) async {
      await _waitForIdle();
      if (_disposed) return;
      _saving = true;
      _notify();
      try {
        await repository.withLocalData(() async {
          final latest = await repository.loadHosts();
          final index = latest.indexWhere((host) => host.id == hostId);
          if (index < 0) {
            // 主机已在云端被删除并写回本地：绝不能把这次意图静默丢弃成“已保存”。
            throw StateError('主机已不存在，无法保存书签');
          }
          final next = [...latest];
          next[index] = latest[index].withSftpBookmarks(
            _bookmarksWith(latest[index].sftpBookmarks, path, saved),
          );
          await repository.saveHosts(next);
          if (_disposed) return;
          _hosts = next;
          _scheduleSync();
        });
      } finally {
        _saving = false;
        _notify();
      }
    });
    _bookmarkWrite = operation.catchError((Object _) {});
    return operation;
  }

  /// 单个路径的收藏意图：新增保持既有顺序并追加到末尾，取消则只移除该路径。
  static List<String> _bookmarksWith(
    List<String> current,
    String path,
    bool saved,
  ) {
    if (!saved) {
      return [
        for (final value in current)
          if (value != path) value,
      ];
    }
    if (current.contains(path)) return current;
    return [...current, path];
  }

  /// 等待其它保存或加载结束后再独占写入，避免与正在进行的操作交错。
  Future<void> _waitForIdle() async {
    while (!_disposed && (_saving || loading)) {
      _idleCompleter ??= Completer<void>();
      await _idleCompleter!.future;
    }
  }

  Future<void> saveUser(SshUser user, Credentials? credentials) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    _saving = true;
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
      _saving = false;
      _notify();
    }
  }

  Future<void> deleteUser(SshUser user) async {
    if (saving) throw StateError('正在保存，请稍后重试');
    _saving = true;
    _notify();
    try {
      await repository.saveUserCredentials(user.id, null);
      final next = _users.where((u) => u.id != user.id).toList();
      await repository.saveUsers(next);
      _users = next;
      _scheduleSync();
    } finally {
      _saving = false;
      _notify();
    }
  }

  void search(String value) {
    query = value;
    _notify();
  }

  void filter({
    bool favorites = false,
    String? tag,
    bool ungrouped = false,
    bool users = false,
  }) {
    showingSettings = false;
    showingFiles = false;
    showingPortForwards = false;
    _rememberTerminal();
    favoritesOnly = favorites;
    ungroupedOnly = ungrouped;
    selectedTag = ungrouped ? null : tag;
    showingUsers = users;
    activeSessionId = null;
    _notify();
  }

  void selectSession(String? id) {
    showingSettings = false;
    showingFiles = false;
    showingPortForwards = false;
    activeSessionId = id;
    if (id != null) _lastTerminalId = id;
    _notify();
  }

  void connect(
    Host host,
    Credentials credentials,
    TrustHost prompt, {
    ConfirmHostKeyChange? confirmKeyChange,
    TrustJumpHost? trustJumpHost,
    ConfirmJumpHostKeyChange? confirmJumpHostKeyChange,
  }) {
    showingSettings = false;
    showingFiles = false;
    showingPortForwards = false;
    final session = SshConnection(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      host: host,
    );
    _sessions.add(session);
    activeSessionId = session.id;
    _lastTerminalId = session.id;
    session.addListener(_notify);
    _notify();
    unawaited(
      session.connect(
        credentials,
        repository,
        prompt,
        confirmKeyChange: confirmKeyChange,
        trustJumpHost: trustJumpHost,
        confirmJumpHostKeyChange: confirmJumpHostKeyChange,
      ),
    );
  }

  void closeSession(SshConnection session) {
    _sessions.remove(session);
    if (_lastTerminalId == session.id) _lastTerminalId = null;
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
    if (!_saving && !loading) {
      _idleCompleter?.complete();
      _idleCompleter = null;
    }
  }

  void showFiles() {
    showingSettings = false;
    _rememberTerminal();
    showingFiles = true;
    showingPortForwards = false;
    _notify();
  }

  void showPortForwards({String? sessionId}) {
    showingSettings = false;
    showingFiles = false;
    _rememberTerminal();
    showingPortForwards = true;
    if (sessionId != null) {
      portForwardSessionId = sessionId;
      portForwardRequest++;
    }
    _notify();
  }

  void showSettings() {
    _rememberTerminal();
    showingSettings = true;
    _notify();
  }

  void closeSettings() {
    showingSettings = false;
    _notify();
  }

  void toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _idleCompleter?.complete();
    _idleCompleter = null;
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
