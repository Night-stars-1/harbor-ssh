import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/app_update.dart';
import '../data/public_key_install.dart';
import '../data/ssh_connection.dart';
import '../domain/host.dart';
import '../domain/appearance.dart';
import 'ai_window_bridge.dart';
import 'app_update_dialog.dart';
import 'host_editor.dart';
import 'host_identity_dialog.dart';
import 'localization.dart';
import 'port_forward_workspace.dart';
import 'expressive_widgets.dart';
import 'public_key_target_dialog.dart';
import 'reorderable_host_collection.dart';
import 'terminal_pane.dart';
import 'terminal_workspace.dart';
import 'theme.dart';
import 'host_icons.dart';
import 'workspace_model.dart';
import 'file_browser.dart';
import 'file_workspace.dart';
import 'window_frame.dart';
import 'settings_page.dart';
import 'settings_widgets.dart';
import 'sidebar_navigation_item.dart';
import 'settings_window_bridge.dart';
import 'system_color_scope.dart';

class HarborApp extends StatefulWidget {
  const HarborApp({
    super.key,
    required this.model,
    this.settingsWindow,
    this.aiWindow,
    this.updaterFactory,
  });
  final WorkspaceModel model;
  final SettingsWindowHost? settingsWindow;
  final AiWindowHost? aiWindow;

  /// Enables the launch-time update check; tests and previews leave it null.
  final AppUpdater Function()? updaterFactory;
  @override
  State<HarborApp> createState() => _HarborAppState();
}

class _HarborAppState extends State<HarborApp> {
  // The title bar lives above the navigator; closing a tab there still needs
  // the workspace's confirmation dialog.
  final _workspace = GlobalKey<_WorkspaceState>();

  @override
  void initState() {
    super.initState();
    unawaited(widget.model.initialize());
  }

  @override
  void dispose() {
    widget.settingsWindow?.dispose();
    if (widget.aiWindow != null) {
      widget.model.appearance.removeListener(widget.aiWindow!.refresh);
      widget.aiWindow!.dispose();
    }
    widget.model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SystemColorScope(
    child: ValueListenableBuilder<AppearancePreferences>(
      valueListenable: widget.model.appearance,
      builder: (context, appearance, _) => MaterialApp(
        title: 'Harbor SSH',
        locale: harborLocale,
        supportedLocales: harborSupportedLocales,
        localizationsDelegates: harborLocalizationDelegates,
        debugShowCheckedModeBanner: false,
        theme: harborTheme(
          dynamicScheme: SystemColorScope.of(context)?.light,
          color: appearance.color,
          reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
          acrylic: appearance.windowAcrylic && windowAcrylicSupported,
          frosted: appearance.frostedSurfaces,
        ),
        darkTheme: harborTheme(
          dynamicScheme: SystemColorScope.of(context)?.dark,
          color: appearance.color,
          brightness: Brightness.dark,
          reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
          acrylic: appearance.windowAcrylic && windowAcrylicSupported,
          frosted: appearance.frostedSurfaces,
        ),
        themeAnimationDuration:
            MediaQuery.maybeOf(context)?.disableAnimations == true
            ? Duration.zero
            : HarborMotion.effectsDuration,
        themeMode: flutterThemeMode(appearance.mode),
        // The frame sits above the navigator, so its shape must stay stable:
        // a changing ancestor would remount every page and terminal below it.
        builder: (context, child) => usesCustomTitleBar
            ? ListenableBuilder(
                listenable: widget.model,
                builder: (context, _) {
                  final wide =
                      MediaQuery.sizeOf(context).width >= _wideLayoutWidth;
                  final navigation = appearance.titleBarNavigation && wide;
                  final sessionTabs = appearance.titleBarSessions && wide;
                  return WindowsWindowFrame(
                    // With both in the bar there is no side panel to toggle.
                    leading: navigation && !sessionTabs
                        ? _sidebarToggle(widget.model, compact: true)
                        : null,
                    tabs: sessionTabs && widget.model.sessions.isNotEmpty
                        ? _TitleBarSessionTabs(
                            model: widget.model,
                            onPortForwards: (session) => _workspace.currentState
                                ?._openPortForwards(session),
                            onClose: (session) =>
                                _workspace.currentState?._closeSession(session),
                          )
                        : null,
                    actions: navigation
                        ? [
                            _returnTerminalButton(widget.model, compact: true),
                            for (final destination in _primaryDestinations(
                              widget.model,
                            ))
                              IconButton(
                                key: ValueKey('title-bar-${destination.id}'),
                                tooltip: destination.title,
                                visualDensity: VisualDensity.compact,
                                iconSize: 20,
                                isSelected: destination.selected,
                                onPressed: destination.open,
                                icon: Icon(destination.icon),
                              ),
                            _settingsButton(
                              context,
                              widget.model,
                              _openSettingsWindow,
                              compact: true,
                            ),
                            _themeButton(
                              context,
                              () => _toggleTheme(context),
                              compact: true,
                            ),
                          ]
                        : const [],
                    child: child!,
                  );
                },
              )
            : child!,
        home: Builder(
          builder: (context) => Workspace(
            key: _workspace,
            model: widget.model,
            aiWindow: widget.aiWindow,
            updaterFactory: widget.updaterFactory,
            onOpenSettings: _openSettingsWindow,
            onToggleTheme: () => _toggleTheme(context),
          ),
        ),
      ),
    ),
  );

  Future<void> Function()? get _openSettingsWindow =>
      widget.settingsWindow?.open;

  Future<void> _toggleTheme(BuildContext context) async {
    try {
      await widget.model.saveAppearance(
        widget.model.appearance.value.copyWith(
          mode: Theme.of(context).brightness == Brightness.dark
              ? AppThemeMode.light
              : AppThemeMode.dark,
        ),
      );
    } catch (_) {
      if (context.mounted) {
        showSettingsNotice(context, '主题设置保存失败，请重试', error: true);
      }
    }
  }
}

/// Width at which the workspace switches from the mobile layout to the
/// desktop sidebar layout.
const _wideLayoutWidth = 900.0;

/// A primary workspace page, shown in the sidebar or the title bar.
typedef _Destination = ({
  String id,
  IconData icon,
  String title,
  String count,
  bool selected,
  VoidCallback open,
});

List<_Destination> _primaryDestinations(WorkspaceModel model) {
  final home =
      model.activeSessionId == null &&
      !model.showingSettings &&
      !model.showingFiles &&
      !model.showingPortForwards;
  return [
    (
      id: 'all-hosts',
      icon: Icons.dns_rounded,
      title: '所有连接',
      count: '${model.hosts.length}',
      selected:
          home &&
          !model.showingUsers &&
          !model.favoritesOnly &&
          !model.ungroupedOnly &&
          model.selectedTag == null,
      open: () => model.filter(),
    ),
    (
      id: 'favorites',
      icon: Icons.star_rounded,
      title: '收藏',
      count: '${model.hosts.where((h) => h.favorite).length}',
      selected: home && !model.showingUsers && model.favoritesOnly,
      open: () => model.filter(favorites: true),
    ),
    (
      id: 'users',
      icon: Icons.vpn_key_rounded,
      title: '凭证',
      count: '${model.users.length}',
      selected: home && model.showingUsers,
      open: () => model.filter(users: true),
    ),
    (
      id: 'files',
      icon: Icons.folder_copy_rounded,
      title: 'SFTP',
      count: '',
      selected: model.showingFiles && !model.showingSettings,
      open: model.showFiles,
    ),
    (
      id: 'port-forwards',
      icon: Icons.alt_route_rounded,
      title: '端口转发',
      count: '',
      selected: model.showingPortForwards && !model.showingSettings,
      open: () => model.showPortForwards(),
    ),
  ];
}

Widget _sidebarToggle(WorkspaceModel model, {bool compact = false}) =>
    IconButton(
      key: const ValueKey('sidebar-toggle'),
      visualDensity: compact ? VisualDensity.compact : null,
      iconSize: compact ? 20 : null,
      onPressed: model.toggleSidebar,
      icon: Icon(
        model.sidebarCollapsed
            ? Icons.keyboard_double_arrow_right_rounded
            : Icons.keyboard_double_arrow_left_rounded,
        semanticLabel: model.sidebarCollapsed ? '展开侧栏' : '折叠侧栏',
      ),
    );

/// 回到切换页面前的终端；终端已在屏幕上或没有可返回的终端时置灰。
Widget _returnTerminalButton(WorkspaceModel model, {bool compact = false}) =>
    IconButton(
      key: const ValueKey('title-bar-return-terminal'),
      tooltip: '返回终端',
      visualDensity: compact ? VisualDensity.compact : null,
      iconSize: compact ? 20 : null,
      onPressed: model.canReturnToTerminal ? model.returnToTerminal : null,
      icon: const Icon(Icons.keyboard_return_rounded, semanticLabel: '返回终端'),
    );

Widget _themeButton(
  BuildContext context,
  VoidCallback onToggle, {
  bool compact = false,
}) => IconButton(
  onPressed: onToggle,
  tooltip: '切换浅色/深色主题',
  visualDensity: compact ? VisualDensity.compact : null,
  iconSize: compact ? 20 : null,
  icon: Icon(
    Theme.of(context).brightness == Brightness.dark
        ? Icons.light_mode_rounded
        : Icons.dark_mode_rounded,
  ),
);

/// Opens the separate settings window when there is one, otherwise the
/// in-workspace settings page.
Widget _settingsButton(
  BuildContext context,
  WorkspaceModel model,
  Future<void> Function()? openWindow, {
  bool compact = false,
}) => IconButton(
  key: const ValueKey('settings-button'),
  visualDensity: compact ? VisualDensity.compact : null,
  iconSize: compact ? 20 : null,
  onPressed: model.loading
      ? null
      : () async {
          if (openWindow == null) {
            model.showSettings();
            return;
          }
          try {
            await openWindow();
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('无法打开设置窗口，请重新启动应用后重试')),
              );
            }
          }
        },
  isSelected: model.showingSettings,
  selectedIcon: const Icon(Icons.settings_rounded, semanticLabel: '设置'),
  icon: const Icon(Icons.settings_outlined, semanticLabel: '设置'),
);

/// 会话显示的图标。连接快照保留建连时的身份，图标以已保存的主机配置为准，
/// 这样编辑图标后标题栏和侧栏无需重连即可更新；主机尚未保存时沿用快照。
IconData _sessionHostIcon(WorkspaceModel model, SshConnection session) =>
    sessionIcon(model.sessionHostIcon(session.host));

/// Actions shared by a session's sidebar item and its title bar tab.
List<Widget> _sessionMenuChildren(
  BuildContext context,
  SshConnection session, {
  required ValueChanged<SshConnection> onPortForwards,
  required ValueChanged<SshConnection> onClose,
}) => [
  if (Theme.of(context).windowBackdrop.frosted) const HarborSurfaceBlur(),
  MenuItemButton(
    onPressed: () => onPortForwards(session),
    leadingIcon: const Icon(Icons.alt_route_rounded, size: 20),
    child: const Text('端口转发'),
  ),
  MenuItemButton(
    onPressed:
        session.status == ConnectionStatus.connected ||
            session.status == ConnectionStatus.connecting
        ? session.close
        : null,
    leadingIcon: const Icon(Icons.link_off_rounded, size: 20),
    child: const Text('断开连接'),
  ),
  MenuItemButton(
    onPressed: () => onClose(session),
    leadingIcon: const Icon(Icons.close_rounded, size: 20),
    child: const Text('关闭会话'),
  ),
];

/// Open sessions as tabs on the left of the custom title bar, replacing the
/// sidebar's session section.
class _TitleBarSessionTabs extends StatelessWidget {
  const _TitleBarSessionTabs({
    required this.model,
    required this.onPortForwards,
    required this.onClose,
  });
  final WorkspaceModel model;
  final ValueChanged<SshConnection> onPortForwards, onClose;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('title-bar-sessions'),
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final session in model.sessions)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _tab(context, session),
          ),
      ],
    ),
  );

  Widget _tab(BuildContext context, SshConnection session) {
    final colors = Theme.of(context).colorScheme;
    final selected = model.showsTerminal && model.activeSessionId == session.id;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return MenuAnchor(
      key: ValueKey('title-bar-session-menu-${session.id}'),
      menuChildren: _sessionMenuChildren(
        context,
        session,
        onPortForwards: onPortForwards,
        onClose: onClose,
      ),
      builder: (context, controller, _) => GestureDetector(
        onSecondaryTapUp: (details) {
          final box = context.findRenderObject()! as RenderBox;
          controller.open(position: box.globalToLocal(details.globalPosition));
        },
        child: Tooltip(
          message: '${session.host.name} · ${session.statusLabel}',
          child: Semantics(
            selected: selected,
            button: true,
            child: Material(
              color: selected ? colors.secondaryContainer : Colors.transparent,
              shape: HarborShapes.pill,
              child: InkWell(
                key: ValueKey('title-bar-session-${session.id}'),
                customBorder: HarborShapes.pill,
                onTap: () => model.selectSession(session.id),
                child: SizedBox(
                  height: 30,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _sessionHostIcon(model, session),
                          size: 16,
                          color: session.status == ConnectionStatus.connected
                              ? (selected
                                    ? colors.onSecondaryContainer
                                    : colors.primary)
                              : foreground,
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 140),
                          child: Text(
                            session.host.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: foreground),
                          ),
                        ),
                        IconButton(
                          key: ValueKey(
                            'title-bar-session-close-${session.id}',
                          ),
                          onPressed: () => onClose(session),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          iconSize: 14,
                          color: foreground,
                          icon: Icon(
                            Icons.close_rounded,
                            semanticLabel: '关闭 ${session.host.name}',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Workspace extends StatefulWidget {
  const Workspace({
    super.key,
    required this.model,
    required this.onToggleTheme,
    this.onOpenSettings,
    this.aiWindow,
    this.updaterFactory,
  });
  final WorkspaceModel model;
  final VoidCallback onToggleTheme;
  final Future<void> Function()? onOpenSettings;
  final AiWindowHost? aiWindow;
  final AppUpdater Function()? updaterFactory;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  WorkspaceModel get model => widget.model;
  late final _search = TextEditingController(text: model.query);
  final _terminalController = TerminalPaneController();
  // Title bar navigation has no icon rail: collapsing hides the session list.
  bool get _sidebarCollapsed => model.sidebarCollapsed && !_titleBarNavigation;
  bool get _titleBarNavigation =>
      usesCustomTitleBar && model.appearance.value.titleBarNavigation;
  bool get _titleBarSessions =>
      usesCustomTitleBar && model.appearance.value.titleBarSessions;
  bool _hideAddresses = false;
  bool _settingsOpened = false;
  bool _portForwardsOpened = false;
  bool _sessionsOpen = false;
  final _settingsNavigation = SettingsNavigation();
  double _sidebarWidth = 264;

  // 虚拟默认分组：无标签主机的入口，不写入真实标签。
  static const _ungroupedLabel = '未分组';

  bool get _ungroupedSelected =>
      model.ungroupedOnly &&
      model.activeSessionId == null &&
      !model.showingSettings &&
      !model.showingFiles &&
      !model.showingPortForwards &&
      !model.showingUsers;

  /// 真实标签恰好同名时，仅在显示上加以区分。
  String _tagLabel(String tag) => tag == _ungroupedLabel ? '$tag（标签）' : tag;

  @override
  void initState() {
    super.initState();
    if (widget.updaterFactory != null) {
      model.addListener(_checkUpdatesOnce);
      _checkUpdatesOnce();
    }
  }

  @override
  void dispose() {
    model.removeListener(_checkUpdatesOnce);
    _updater?.cancel();
    _search.dispose();
    _settingsNavigation.dispose();
    super.dispose();
  }

  AppUpdater? _updater;

  /// Checks GitHub Releases once, after local preferences have loaded.
  /// Failures stay silent: the launch prompt is a convenience, and the About
  /// page reports errors when the user checks by hand.
  void _checkUpdatesOnce() {
    if (model.loading) return;
    model.removeListener(_checkUpdatesOnce);
    final preferences = model.updatePreferences;
    if (!preferences.autoCheck) return;
    final updater = _updater = widget.updaterFactory!();
    unawaited(() async {
      try {
        final check = await updater.check();
        if (!mounted ||
            !check.available ||
            check.release.version == model.updatePreferences.skippedVersion) {
          return;
        }
        await showAppUpdateDialog(
          context,
          check: check,
          updaterFactory: widget.updaterFactory!,
          onSkip: (version) => unawaited(
            model
                .saveUpdatePreferences(
                  model.updatePreferences.copyWith(skippedVersion: version),
                )
                .catchError((Object _) {}),
          ),
        );
      } catch (_) {
        // Offline or rate-limited launches simply skip the prompt.
      } finally {
        if (identical(_updater, updater)) _updater = null;
      }
    }());
  }

  bool _opening = false;
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) _message('操作失败，请检查本地存储权限后重试。');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _edit([Host? host]) async {
    if (_opening) return;
    _opening = true;
    try {
      final credentials = host == null
          ? null
          : await model.repository.credentials(host.id);
      final userCredentials = <String, Credentials>{};
      for (final user in model.users) {
        final value = await model.repository.userCredentials(user.id);
        if (value != null) userCredentials[user.id] = value;
      }
      if (!mounted) return;
      await showExpressiveDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => HostEditor(
          host: host,
          credentials: credentials,
          users: model.users,
          hosts: model.hosts,
          onlineHostIds: {
            for (final session in model.sessions)
              if (session.status == ConnectionStatus.connected) session.host.id,
          },
          userCredentials: userCredentials,
          onSave: model.saveHost,
          onTest: _testConnection,
        ),
      );
    } catch (_) {
      if (mounted) _message('无法读取安全存储，请检查系统权限。');
    } finally {
      _opening = false;
    }
  }

  Future<void> _editUser([SshUser? user]) async {
    if (_opening) return;
    _opening = true;
    try {
      final credentials = user == null
          ? null
          : await model.repository.userCredentials(user.id);
      if (!mounted) return;
      await showExpressiveDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UserEditor(
          user: user,
          credentials: credentials,
          onSave: model.saveUser,
        ),
      );
    } catch (_) {
      if (mounted) _message('无法读取安全存储，请检查系统权限。');
    } finally {
      _opening = false;
    }
  }

  void _add() {
    if (model.showingUsers) {
      unawaited(_editUser());
    } else {
      unawaited(_edit());
    }
  }

  Future<void> _connect(Host host) async {
    if (_opening) return;
    _opening = true;
    try {
      final credentials = await _loginCredentialsFor(host);
      if (!mounted) return;
      if (credentials == null) {
        _opening = false;
        await _requestMissingCredentials(host);
      } else if (mounted) {
        _start(host, credentials);
      }
    } catch (_) {
      if (mounted) _message('无法读取凭据，请检查系统安全存储权限。');
    } finally {
      _opening = false;
    }
  }

  Future<void> _reconnect(SshConnection session) async {
    if (_opening ||
        !model.sessions.contains(session) ||
        session.status == ConnectionStatus.connecting ||
        session.status == ConnectionStatus.connected) {
      return;
    }
    _opening = true;
    try {
      final host =
          model.hosts.where((host) => host.id == session.host.id).firstOrNull ??
          session.host;
      final credentials = await _loginCredentialsFor(host);
      if (!mounted || !model.sessions.contains(session)) return;
      if (credentials == null) {
        _opening = false;
        await _requestMissingCredentials(host);
        return;
      }
      await session.reconnect(
        credentials,
        model.repository,
        (type, fingerprint) => _trustHost(host, type, fingerprint),
        host: host,
        trustJumpHost: _trustHost,
        confirmJumpHostKeyChange: _confirmJumpHostKeyChange,
        confirmKeyChange: (type, fingerprint, previousKey) =>
            _trustHost(host, type, fingerprint, previousKey: previousKey),
      );
    } catch (_) {
      if (mounted) _message('重新连接失败，请检查凭据及系统安全存储权限。');
    } finally {
      _opening = false;
    }
  }

  Future<void> _testConnection(Host host, Credentials credentials) async {
    final connection = SshConnection(id: 'connection-test', host: host);
    try {
      await connection.connect(
        credentials,
        model.repository,
        (type, fingerprint) => _trustHost(host, type, fingerprint),
        openShell: false,
        trustJumpHost: _trustHost,
        confirmJumpHostKeyChange: _confirmJumpHostKeyChange,
        confirmKeyChange: (type, fingerprint, previousKey) =>
            _trustHost(host, type, fingerprint, previousKey: previousKey),
      );
      if (connection.status != ConnectionStatus.connected) {
        throw Exception(connection.error ?? '无法建立 SSH 连接');
      }
    } finally {
      connection.dispose();
    }
  }

  void _start(Host host, Credentials credentials) {
    model.connect(
      host,
      credentials,
      (type, fingerprint) => _trustHost(host, type, fingerprint),
      trustJumpHost: _trustHost,
      confirmJumpHostKeyChange: _confirmJumpHostKeyChange,
      confirmKeyChange: (type, fingerprint, previousKey) =>
          _trustHost(host, type, fingerprint, previousKey: previousKey),
    );
  }

  void _openPortForwards(SshConnection session) {
    if (_sessionsOpen) Navigator.of(context).pop();
    model.showPortForwards(sessionId: session.id);
  }

  Future<SshConnection?> _connectPortForwardHost(Host host) async {
    final previous = model.sessions.map((s) => s.id).toSet();
    await _connect(host);
    if (!mounted) return null;
    final session = model.sessions
        .where((s) => s.host.id == host.id && !previous.contains(s.id))
        .lastOrNull;
    model.showPortForwards(sessionId: session?.id);
    return session;
  }

  void _openSessionFiles(SshConnection session) {
    final files = model.fileWorkspace;
    final existing = files.panes[1].tabs
        .where((tab) => tab.session == session)
        .firstOrNull;
    if (existing == null) {
      files.add(
        1,
        name: session.host.name,
        files: session.files,
        initialPath: session.host.sftpStartPath,
        session: session,
      );
    } else {
      files.activate(1, existing.id);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    model.showFiles();
  }

  Future<SshConnection?> _connectFiles(Host host) async {
    final credentials = await _loginCredentialsFor(host);
    if (!mounted) return null;
    if (credentials == null) {
      await _requestMissingCredentials(host);
      return null;
    }
    final session = SshConnection(
      id: 'sftp-${DateTime.now().microsecondsSinceEpoch}',
      host: host,
    );
    await session.connect(
      credentials,
      model.repository,
      (type, fingerprint) => _trustHost(host, type, fingerprint),
      openShell: false,
      trustJumpHost: _trustHost,
      confirmJumpHostKeyChange: _confirmJumpHostKeyChange,
      confirmKeyChange: (type, fingerprint, previousKey) =>
          _trustHost(host, type, fingerprint, previousKey: previousKey),
    );
    if (!mounted || session.status != ConnectionStatus.connected) {
      final error = session.error;
      session.dispose();
      if (mounted) _message(error ?? 'SFTP 连接失败');
      return null;
    }
    return session;
  }

  Future<bool> _confirmJumpHostKeyChange(
    Host host,
    String type,
    String fingerprint,
    String previousKey,
  ) => _trustHost(host, type, fingerprint, previousKey: previousKey);

  Future<bool> _trustHost(
    Host host,
    String type,
    String fingerprint, {
    String? previousKey,
  }) async {
    if (!mounted) return false;
    return await showExpressiveDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => HostIdentityDialog(
            host: host,
            keyType: type,
            fingerprint: fingerprint,
            previousKey: previousKey,
          ),
        ) ??
        false;
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showExpressiveDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _hostAction(Host host, String action) async {
    switch (action) {
      case 'edit':
        await _edit(host);
      case 'delete':
        if (await _confirm(
          '删除连接？',
          '将删除「${host.name}」的配置与已保存凭据。现有会话不会被关闭。',
          '删除',
        )) {
          await _guard(() => model.deleteHost(host));
        }
      case 'forget':
        if (await _confirm(
          '重置主机指纹？',
          '请先核实服务器密钥变化的原因。下次连接 ${host.endpoint} 时将重新确认身份，同地址的连接共用此记录。',
          '重置指纹',
        )) {
          await _guard(() async {
            await model.repository.forgetHostKey(host);
            if (mounted) _message('已重置指纹，下次连接时请重新核对。');
          });
        }
    }
  }

  Future<void> _userAction(SshUser user, String action) async {
    switch (action) {
      case 'installKey':
        await _installPublicKey(user);
      case 'edit':
        await _editUser(user);
      case 'delete':
        if (await _confirm(
          '删除凭证？',
          '将删除「${user.name}」及其已保存凭据。已选用此凭证的连接会改为连接时再输入。',
          '删除',
        )) {
          await _guard(() => model.deleteUser(user));
        }
    }
  }

  /// 该主机已有的已连接会话：安装公钥时复用它，既不新建连接，也不动它的终端。
  ///
  /// 只有地址、端口与登录账户都与所选主机一致才算同一个目标：主机条目改过
  /// 地址或账户后，旧会话连的是另一台服务器，绝不能把公钥装到那里去。
  SshConnection? _connectedSessionFor(Host host) {
    for (final session in model.sessions) {
      if (session.status != ConnectionStatus.connected) continue;
      final live = session.host;
      if (live.id == host.id &&
          live.endpoint == host.endpoint &&
          live.username == host.username &&
          live.jumpHostId == host.jumpHostId) {
        return session;
      }
    }
    return null;
  }

  /// 目标服务器自己的登录凭证（连接级优先，其次继承凭证）。
  /// 被安装的公钥不参与登录，私钥也不会离开这份凭证。
  Future<Credentials?> _loginCredentialsFor(Host host) =>
      model.repository.loginCredentials(host);

  String _missingCredentialsMessage(Host host) {
    if (host.authMethod == AuthMethod.password) return '请填写连接密码。';
    if (host.userId.isEmpty) return '请为连接选择已保存的私钥凭证。';
    final user = model.users.where((u) => u.id == host.userId).firstOrNull;
    if (user == null) return '此连接引用的私钥凭证已不存在，请重新选择凭证。';
    return '已选择凭证「${user.name}」，但本机没有保存它的私钥。请从完整的同步备份恢复，或在凭证页导入私钥。';
  }

  Future<void> _requestMissingCredentials(Host host) async {
    _message(_missingCredentialsMessage(host));
    if (host.authMethod == AuthMethod.privateKey &&
        model.users.any((u) => u.id == host.userId)) {
      model.filter(users: true);
      return;
    }
    await _edit(host);
  }

  /// 把私钥凭证的公钥安装到用户选定的服务器：仅把公钥追加到目标账户的
  /// ~/.ssh/authorized_keys。优先复用该主机已连接的会话，否则用目标主机
  /// 自己的登录凭证临时建连（不打开终端），用完即断。
  /// 无论成败都不改动凭证、主机配置或登录来源。
  Future<void> _installPublicKey(SshUser user) async {
    final String publicKey;
    try {
      publicKey = validatedOpenSshPublicKey(user.publicKey);
    } on FormatException catch (error) {
      _message('「${user.name}」没有可安装的 OpenSSH 公钥：${error.message}');
      return;
    }
    if (!mounted) return;
    final hosts = model.hosts;
    final target = await PublicKeyTargetDialog.show(
      context,
      credential: user,
      publicKey: publicKey,
      hosts: hosts,
      // 弹窗只用它提示「会复用已连接的会话」，因此必须与复用条件完全一致：
      // 只按 host.id 提示会让用户以为公钥会装到那台旧服务器上。
      liveSessionHostIds: {
        for (final host in hosts)
          if (_connectedSessionFor(host) != null) host.id,
      },
    );
    if (target == null || !mounted) return;

    SshConnection? temporary;
    final existing = _connectedSessionFor(target);
    if (existing == null) {
      temporary = SshConnection(
        id: 'key-install-${DateTime.now().microsecondsSinceEpoch}',
        host: target,
      );
    }
    final connection = existing ?? temporary!;
    final targetPath = '${target.destination} 的 ~/.ssh/authorized_keys';
    // 复用已有会话时不必再连接，进度从一开始就说清写入目标。
    final status = ValueNotifier<String>(
      existing == null
          ? '正在连接 ${target.destination}…'
          : '正在通过已连接的会话写入 $targetPath…',
    );
    BuildContext? progressContext;
    final progress = showExpressiveDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        progressContext = dialogContext;
        return _InstallProgress(status: status);
      },
    );
    // 安装已发出后断线，与连接阶段失败的含义不同：前者可能已经写入。
    var installing = false;
    var declined = false;
    try {
      if (temporary != null) {
        final credentials = await _loginCredentialsFor(target);
        if (!mounted) return;
        if (credentials == null) {
          _message('「${target.name}」：${_missingCredentialsMessage(target)}');
          return;
        }
        await temporary.connect(
          credentials,
          model.repository,
          (type, fingerprint) async {
            final accepted = await _trustHost(target, type, fingerprint);
            declined = !accepted;
            return accepted;
          },
          openShell: false,
          trustJumpHost: (jump, type, fingerprint) async {
            final accepted = await _trustHost(jump, type, fingerprint);
            declined = !accepted;
            return accepted;
          },
          confirmJumpHostKeyChange:
              (jump, type, fingerprint, previousKey) async {
                final accepted = await _trustHost(
                  jump,
                  type,
                  fingerprint,
                  previousKey: previousKey,
                );
                declined = !accepted;
                return accepted;
              },
          confirmKeyChange: (type, fingerprint, previousKey) async {
            final accepted = await _trustHost(
              target,
              type,
              fingerprint,
              previousKey: previousKey,
            );
            declined = !accepted;
            return accepted;
          },
        );
        if (temporary.status != ConnectionStatus.connected) {
          throw Exception(temporary.error ?? '无法建立 SSH 连接');
        }
      }
      status.value = '正在写入 $targetPath…';
      installing = true;
      final installed = await connection.installPublicKey(publicKey);
      if (!mounted) return;
      _message(
        installed
            ? '已把「${user.name}」的公钥安装到 $targetPath。'
            : '该公钥已存在于 $targetPath，无需重复安装。',
      );
    } catch (error) {
      if (!mounted) return;
      if (declined) {
        _message('未确认 ${target.destination} 的主机身份，已取消安装。');
      } else if (_installResultUnknown(error, connection, installing)) {
        _message(
          '无法确认安装结果：${_installError(error)}。'
          '请稍后在服务器上核对 ~/.ssh/authorized_keys。',
        );
      } else if (!installing) {
        _message('未能连接 ${target.destination}，公钥未安装：${_installError(error)}');
      } else {
        _message('安装公钥失败：${_installError(error)}');
      }
    } finally {
      // 很快结束的安装（例如无可用的登录凭证）可能还没渲染出进度弹窗：
      // 先等它出现，再精确关闭自己，绝不留下永远转圈的遮罩。
      await WidgetsBinding.instance.endOfFrame;
      final dialogContext = progressContext;
      if (dialogContext != null && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
        await progress;
      }
      status.dispose();
      temporary?.dispose();
    }
  }

  /// 安装请求已发出后超时或断线，公钥可能已经写入、也可能没有：
  /// 既不宣称成功，也不断言失败，只提示用户去服务器核对。
  bool _installResultUnknown(
    Object error,
    SshConnection connection,
    bool installing,
  ) {
    if (error is PublicKeyInstallFailure) return error.unknown;
    if (!installing) return false;
    return error is TimeoutException ||
        connection.status != ConnectionStatus.connected;
  }

  String _installError(Object error) {
    if (error is PublicKeyInstallFailure) return error.message;
    final text = error.toString();
    for (final prefix in const ['Exception: ', 'StateError: ']) {
      if (text.startsWith(prefix)) return text.substring(prefix.length);
    }
    return text;
  }

  Future<void> _closeSession(SshConnection session) async {
    if (session.status == ConnectionStatus.connected &&
        !await _confirm(
          '关闭终端？',
          '这会断开「${session.host.name}」的 SSH 会话，正在前台运行的进程可能结束。',
          '断开并关闭',
        )) {
      return;
    }
    if (mounted) model.closeSession(session);
  }

  Future<void> _showSessions() async {
    if (_sessionsOpen) return;
    _sessionsOpen = true;
    try {
      await showExpressiveBottomSheet<void>(
        context: context,
        builder: (sheetContext) => FractionallySizedBox(
          heightFactor: 0.7,
          child: SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: model,
              builder: (context, _) {
                final sessions = model.sessions;
                return ListView(
                  key: const ValueKey('mobile-session-list'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      child: Text(
                        '会话 (${sessions.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (sessions.isEmpty)
                      const ListTile(
                        leading: Icon(Icons.terminal_rounded),
                        title: Text('暂无会话'),
                        subtitle: Text('连接主机后，可在这里查看和切换会话。'),
                      ),
                    for (final session in sessions)
                      _sessionNavItem(
                        session,
                        mobile: true,
                        onSelected: () {
                          Navigator.of(sheetContext).pop();
                          model.selectSession(session.id);
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    } finally {
      _sessionsOpen = false;
    }
  }

  void _navigate(VoidCallback action) {
    action();
  }

  void _backFromSettings() {
    if (_settingsNavigation.value != null) {
      _settingsNavigation.back();
    } else {
      model.closeSettings();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([model, _settingsNavigation]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideLayoutWidth;
        final sessionsOnly = wide && _titleBarNavigation;
        // Navigation and sessions both in the title bar leave nothing to show.
        final sidebarHidden =
            sessionsOnly && (model.sidebarCollapsed || _titleBarSessions);
        final maxSidebarWidth = (constraints.maxWidth - 540).clamp(
          220.0,
          400.0,
        );
        final sidebarWidth = _sidebarWidth.clamp(220.0, maxSidebarWidth);
        final colors = Theme.of(context).colorScheme;
        if (model.showingSettings) _settingsOpened = true;
        if (model.showingPortForwards) _portForwardsOpened = true;
        final terminalSession = model.showsTerminal
            ? model.activeSession
            : null;
        final canAdd = !model.loading && model.loadError == null;
        final nestedPage =
            model.showingSettings ||
            model.showingFiles ||
            model.showingPortForwards ||
            model.showingUsers ||
            terminalSession != null;
        return PopScope(
          canPop: !nestedPage,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (model.showingSettings) {
              _backFromSettings();
            } else if (terminalSession != null) {
              model.selectSession(null);
            } else {
              model.filter();
            }
          },
          child: Scaffold(
            appBar: wide
                ? null
                : AppBar(
                    automaticallyImplyLeading: false,
                    titleSpacing: terminalSession == null ? null : 0,
                    leading: model.showingSettings
                        ? IconButton(
                            key: ValueKey(
                              _settingsNavigation.value == null
                                  ? 'settings-back'
                                  : 'settings-category-back',
                            ),
                            onPressed: _backFromSettings,
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              semanticLabel: '返回',
                            ),
                          )
                        : terminalSession == null
                        ? null
                        : IconButton(
                            onPressed: () => model.selectSession(null),
                            icon: const Icon(Icons.arrow_back_rounded),
                            tooltip: '返回连接',
                          ),
                    title: Tooltip(
                      message: terminalSession == null ? '' : '切换会话',
                      child: InkWell(
                        key: const ValueKey('mobile-session-switcher'),
                        onTap: terminalSession == null ? null : _showSessions,
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          height: 48,
                          child: Row(
                            children: [
                              if (terminalSession != null) ...[
                                Icon(
                                  Icons.circle,
                                  size: 8,
                                  color:
                                      model.activeSession!.status ==
                                          ConnectionStatus.connected
                                      ? colors.primary
                                      : colors.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: Text(
                                  terminalSession?.host.name ??
                                      (model.showingSettings
                                          ? _settingsNavigation.title
                                          : model.showingPortForwards
                                          ? '端口转发'
                                          : model.showingFiles
                                          ? 'SFTP'
                                          : model.showingUsers
                                          ? '凭证'
                                          : model.favoritesOnly
                                          ? '收藏'
                                          : model.ungroupedOnly
                                          ? _ungroupedLabel
                                          : model.selectedTag == null
                                          ? '连接'
                                          : _tagLabel(model.selectedTag!)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (terminalSession != null)
                                const Icon(Icons.expand_more_rounded, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                    actions: [
                      _themeButton(context, widget.onToggleTheme),
                      if (terminalSession == null && !model.showingSettings)
                        _settingsButton(context, model, widget.onOpenSettings),
                      if (terminalSession != null)
                        FileBrowserButton(
                          session: model.activeSession!,
                          onOpen: () => _openSessionFiles(model.activeSession!),
                          onReturn: _terminalController.requestFocus,
                        ),
                      if (terminalSession != null)
                        IconButton(
                          key: const ValueKey('terminal-ai-mobile'),
                          onPressed: () =>
                              _terminalController.selectOption('ai'),
                          icon: const Icon(
                            Icons.auto_awesome_outlined,
                            semanticLabel: 'AI 助手',
                          ),
                        ),
                      if (terminalSession != null)
                        TerminalOptionsButton(
                          session: model.activeSession!,
                          controller: _terminalController,
                          canClose: true,
                          canForward: true,
                        ),
                      if (terminalSession == null &&
                          !model.showingSettings &&
                          !model.showingFiles &&
                          !model.showingPortForwards)
                        IconButton(
                          tooltip: model.favoritesOnly ? '显示全部连接' : '收藏',
                          isSelected: model.favoritesOnly,
                          icon: const Icon(Icons.star_outline_rounded),
                          selectedIcon: const Icon(Icons.star_rounded),
                          onPressed: () =>
                              model.filter(favorites: !model.favoritesOnly),
                        ),
                      const SizedBox(width: 8),
                    ],
                  ),
            floatingActionButton:
                !wide &&
                    terminalSession == null &&
                    !model.showingSettings &&
                    !model.showingFiles &&
                    !model.showingPortForwards &&
                    canAdd
                ? FloatingActionButton(
                    onPressed: _add,
                    child: Icon(
                      Icons.add_rounded,
                      semanticLabel: model.showingUsers ? '新建凭证' : '新建连接',
                    ),
                  )
                : null,
            bottomNavigationBar:
                !wide && terminalSession == null && !model.showingSettings
                ? NavigationBar(
                    selectedIndex: model.showingPortForwards
                        ? 3
                        : model.showingFiles
                        ? 2
                        : model.showingUsers
                        ? 1
                        : 0,
                    onDestinationSelected: (index) => index == 3
                        ? model.showPortForwards()
                        : index == 2
                        ? model.showFiles()
                        : model.filter(users: index == 1),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.dns_outlined),
                        selectedIcon: Icon(Icons.dns_rounded),
                        label: '连接',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.key_outlined),
                        selectedIcon: Icon(Icons.key_rounded),
                        label: '凭证',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.folder_copy_outlined),
                        selectedIcon: Icon(Icons.folder_copy_rounded),
                        label: 'SFTP',
                      ),
                      NavigationDestination(
                        key: ValueKey('mobile-port-forwards'),
                        icon: Icon(Icons.alt_route_outlined),
                        selectedIcon: Icon(Icons.alt_route_rounded),
                        label: '端口转发',
                      ),
                    ],
                  )
                : null,
            body: SafeArea(
              top: wide,
              child: Row(
                children: [
                  if (wide && !sidebarHidden) ...[
                    SizedBox(
                      key: const ValueKey('workspace-sidebar'),
                      width: _sidebarCollapsed ? 80 : sidebarWidth,
                      child: sessionsOnly ? _sessionSidebar() : _sidebar(),
                    ),
                    if (!_sidebarCollapsed)
                      _sidebarResizeHandle(sidebarWidth, maxSidebarWidth),
                  ],
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        sidebarHidden
                            ? 12
                            : wide && _sidebarCollapsed
                            ? 8
                            : 0,
                        wide ? 12 : 0,
                        wide ? 12 : 0,
                        wide ? 12 : 0,
                      ),
                      child: Material(
                        color: Theme.of(context).windowBackdrop
                            .sheet(colors.surface),
                        borderRadius: wide
                            ? BorderRadius.circular(32)
                            : BorderRadius.zero,
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            Expanded(
                              child: ExpressiveIndexedStack(
                                motion: wide
                                    ? ExpressivePageMotion.fadeThrough
                                    : ExpressivePageMotion.sharedAxis,
                                // Connection, favorites and credentials share
                                // the home child; animate their logical switch
                                // without replacing it or resetting its state.
                                transitionIndex: model.showingSettings
                                    ? 5
                                    : model.showingPortForwards
                                    ? 4
                                    : model.showingFiles
                                    ? 3
                                    : model.showingUsers
                                    ? 2
                                    : model.favoritesOnly
                                    ? 1
                                    : 0,
                                index: model.showingSettings
                                    ? 2
                                    : model.showingPortForwards
                                    ? 3
                                    : model.showingFiles
                                    ? 1
                                    : 0,
                                children: [
                                  ExcludeFocus(
                                    excluding:
                                        model.showingSettings ||
                                        model.showingFiles ||
                                        model.showingPortForwards,
                                    child: ExpressiveIndexedStack(
                                      // Opening a terminal goes one level
                                      // deeper than the connection list.
                                      motion: ExpressivePageMotion.sharedAxis,
                                      index: model.activeSession == null
                                          ? 0
                                          : 1,
                                      children: [
                                        _home(wide),
                                        ExcludeFocus(
                                          excluding:
                                              model.activeSession == null,
                                          child: TerminalWorkspace(
                                            sessions: model.sessions,
                                            aiSettings: () => model.aiSettings,
                                            aiHistoryStore:
                                                model.aiHistoryStore,
                                            aiWindow: widget.aiWindow,
                                            onAiSettings: () async {
                                              if (widget.onOpenSettings !=
                                                  null) {
                                                try {
                                                  await widget
                                                      .onOpenSettings!();
                                                } catch (_) {
                                                  if (mounted) {
                                                    _message('无法打开设置窗口，请重试');
                                                  }
                                                }
                                              } else {
                                                _settingsNavigation.value = 3;
                                                model.showSettings();
                                              }
                                            },
                                            activeSession: model.activeSession,
                                            hosts: model.hosts,
                                            fontSize: model
                                                .appearance
                                                .value
                                                .terminalFontSize
                                                .toDouble(),
                                            terminalWrap: model
                                                .appearance
                                                .value
                                                .terminalWrap,
                                            statusRefreshSeconds: model
                                                .appearance
                                                .value
                                                .statusRefreshSeconds,
                                            desktop: wide,
                                            visible: model.showsTerminal,
                                            mobileController:
                                                _terminalController,
                                            onSelect: model.selectSession,
                                            onConnect: _connect,
                                            onReconnect: _reconnect,
                                            onClose: _closeSession,
                                            onFiles: _openSessionFiles,
                                            onPortForward: _openPortForwards,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  ExcludeFocus(
                                    excluding:
                                        !model.showingFiles ||
                                        model.showingSettings,
                                    child: FileWorkspace(
                                      model: model.fileWorkspace,
                                      hosts: model.hosts,
                                      sessions: model.sessions,
                                      onConnect: _connectFiles,
                                      onSetBookmark: model.setSftpBookmark,
                                      localBookmarks: model.localBookmarks,
                                      onSetLocalBookmark:
                                          model.setLocalBookmark,
                                      sameLocalPath:
                                          WorkspaceModel.sameLocalPath,
                                      showTitle: false,
                                      acceptExternalDrops:
                                          !model.loading &&
                                          model.showingFiles &&
                                          !model.showingSettings,
                                      initializeLocal:
                                          !model.loading &&
                                          model.showingFiles &&
                                          !model.showingSettings,
                                    ),
                                  ),
                                  ExcludeFocus(
                                    excluding: !model.showingSettings,
                                    child: _settingsOpened
                                        ? SettingsPage(
                                            model: model,
                                            desktop: wide,
                                            navigation: _settingsNavigation,
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                  ExcludeFocus(
                                    excluding:
                                        !model.showingPortForwards ||
                                        model.showingSettings,
                                    child: _portForwardsOpened && !model.loading
                                        ? PortForwardWorkspace(
                                            hosts: model.hosts,
                                            sessions: model.sessions,
                                            preferences:
                                                model.repository.preferences,
                                            requestedSessionId:
                                                model.portForwardSessionId,
                                            request: model.portForwardRequest,
                                            onConnect: _connectPortForwardHost,
                                            onHosts: () => model.filter(),
                                            showTitle: wide,
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _sidebarResizeHandle(double width, double maxWidth) {
    void resize(double next) => setState(() {
      _sidebarWidth = next.clamp(220.0, maxWidth);
    });
    return Semantics(
      label: '调整侧栏宽度',
      value: '${width.round()}',
      increasedValue: '${(width + 16).clamp(220.0, maxWidth).round()}',
      decreasedValue: '${(width - 16).clamp(220.0, maxWidth).round()}',
      onIncrease: () => resize(width + 16),
      onDecrease: () => resize(width - 16),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          key: const ValueKey('sidebar-resize-handle'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _sidebarWidth = width,
          onHorizontalDragUpdate: (details) =>
              resize(_sidebarWidth + details.delta.dx),
          onDoubleTap: () => resize(264),
          child: SizedBox(
            width: 8,
            height: double.infinity,
            child: Center(
              child: Container(
                width: 3,
                height: 32,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidebar() {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    return SafeArea(
      child: ColoredBox(
        color: Theme.of(context).windowBackdrop
            .chrome(colors.surfaceContainerLow),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
                children: [
                  if (_sidebarCollapsed)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 28),
                      child: Center(
                        child: ExpressiveMark(size: 48, flower: true),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 28),
                      child: Row(
                        children: [
                          const ExpressiveMark(size: 48, flower: true),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Harbor',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: type.headlineSmall,
                                ),
                                Text(
                                  'SSH 工作空间',
                                  style: type.labelMedium?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final destination in _primaryDestinations(model))
                    _navItem(
                      destination.icon,
                      destination.title,
                      destination.count,
                      destination.selected,
                      destination.open,
                      key: destination.id == 'port-forwards'
                          ? const ValueKey('sidebar-port-forwards')
                          : null,
                      bottomSpacing: destination.count.isEmpty ? 4 : 0,
                    ),
                  _sectionLabel('标签'),
                  _navItem(
                    Icons.sell_outlined,
                    _ungroupedLabel,
                    '',
                    _ungroupedSelected,
                    () => model.filter(ungrouped: true),
                    key: const ValueKey('sidebar-ungrouped'),
                  ),
                  if (model.tags.isEmpty && !_sidebarCollapsed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '添加连接时创建标签',
                        style: type.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final tag in model.tags)
                    _navItem(
                      Icons.sell_outlined,
                      _tagLabel(tag),
                      '',
                      model.selectedTag == tag &&
                          !model.showingSettings &&
                          !model.showingFiles &&
                          !model.showingPortForwards &&
                          model.activeSessionId == null &&
                          !model.showingUsers,
                      () => model.filter(tag: tag),
                    ),
                  if (!_titleBarSessions) ...[
                    _sectionLabel('会话'),
                    ..._sessionItems(),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Flex(
                direction: _sidebarCollapsed ? Axis.vertical : Axis.horizontal,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sidebarToggle(model),
                  if (!_sidebarCollapsed) const Spacer(),
                  _settingsButton(context, model, widget.onOpenSettings),
                  _themeButton(context, widget.onToggleTheme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Title bar navigation mode: pages and window actions live in the title
  /// bar, so the panel lists open sessions only.
  Widget _sessionSidebar() => SafeArea(
    child: ColoredBox(
      color: Theme.of(context).windowBackdrop
          .chrome(Theme.of(context).colorScheme.surfaceContainerLow),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [_sectionLabel('会话'), ..._sessionItems()],
      ),
    ),
  );

  List<Widget> _sessionItems() => [
    if (model.sessions.isEmpty && !_sidebarCollapsed)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          '连接主机后，会话会显示在这里。',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    for (final session in model.sessions) _sessionNavItem(session),
  ];

  Widget _sectionLabel(String label) => _sidebarCollapsed
      ? const Padding(
          padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Divider(height: 1),
        )
      : Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );

  Widget _sessionNavItem(
    SshConnection session, {
    bool mobile = false,
    VoidCallback? onSelected,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected =
        model.activeSessionId == session.id &&
        !model.showingSettings &&
        !model.showingFiles &&
        !model.showingPortForwards;
    final select = onSelected ?? () => model.selectSession(session.id);
    return MenuAnchor(
      key: ValueKey('session-menu-${session.id}'),
      menuChildren: _sessionMenuChildren(
        context,
        session,
        onPortForwards: _openPortForwards,
        onClose: _closeSession,
      ),
      builder: (context, controller, child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (details) {
          final box = context.findRenderObject()! as RenderBox;
          controller.open(position: box.globalToLocal(details.globalPosition));
        },
        onLongPress: mobile ? () => controller.open() : null,
        child: mobile
            ? ListTile(
                key: ValueKey('mobile-session-${session.id}'),
                selected: selected,
                selectedTileColor: colors.secondaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: Icon(
                  _sessionHostIcon(model, session),
                  color: session.status == ConnectionStatus.connected
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
                title: Text(
                  session.host.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(session.statusLabel),
                onTap: select,
                trailing: IconButton(
                  tooltip: '管理会话',
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              )
            : _navItem(
                _sessionHostIcon(model, session),
                session.host.name,
                '',
                selected,
                select,
              ),
      ),
    );
  }

  Widget _navItem(
    IconData icon,
    String title,
    String count,
    bool selected,
    VoidCallback action, {
    Key? key,
    double bottomSpacing = 4,
  }) => SidebarNavigationItem(
    key: key,
    icon: icon,
    title: title,
    count: count,
    selected: selected,
    collapsed: _sidebarCollapsed,
    bottomSpacing: bottomSpacing,
    onTap: () => _navigate(action),
  );

  Widget _filterChip(
    String label, {
    Key? key,
    required bool selected,
    required VoidCallback onSelected,
  }) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: FilterChip(
      key: key,
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    ),
  );

  Widget _home(bool wide) {
    if (model.loading) return const Center(child: CircularProgressIndicator());
    if (model.loadError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(model.loadError!),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: model.initialize,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final colors = Theme.of(context).colorScheme;
        final type = Theme.of(context).textTheme;
        final usersMode = model.showingUsers;
        final hosts = model.filteredHosts;
        final users = model.filteredUsers;
        final count = usersMode ? users.length : hosts.length;
        final empty = usersMode ? model.users.isEmpty : model.hosts.isEmpty;
        final scaled = MediaQuery.textScalerOf(context).scale(16) > 20;
        final grid = constraints.maxWidth >= 680 && !scaled;
        final inset = constraints.maxWidth < 600 ? 20.0 : 28.0;
        final Widget hostCollection = grid
            ? ReorderableHostGridSliver(
                hosts: hosts,
                width: constraints.maxWidth - inset * 2,
                cardBuilder: _hostCards(hosts, hosts.length, asCard: true),
                enabled: _canReorder,
                onReorder: _reorder,
              )
            : ReorderableHostSliver(
                hosts: hosts,
                cardBuilder: _hostCards(hosts, hosts.length),
                enabled: _canReorder,
                onReorder: _reorder,
              );
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, wide ? 20 : 12, inset, 16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide) ...[
                      _workspaceHeader(wide, constraints.maxWidth < 700),
                      const SizedBox(height: 16),
                    ],
                    if (!usersMode &&
                        !model.favoritesOnly &&
                        model.hosts.isEmpty) ...[
                      _welcome(constraints.maxWidth < 700 || scaled),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      style: type.bodyLarge,
                      onChanged: model.search,
                      decoration: InputDecoration(
                        hintText: usersMode ? '搜索凭证名称' : '搜索主机、地址或标签',
                        prefixIcon: const Icon(Icons.search_rounded),
                        constraints: const BoxConstraints(minHeight: 56),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        hoverColor: colors.onSurface.withValues(alpha: 0.08),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(32),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(32),
                          borderSide: BorderSide(
                            color: colors.primary,
                            width: 2,
                          ),
                        ),
                        suffixIcon: model.query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _search.clear();
                                  model.search('');
                                },
                              ),
                      ),
                    ),
                    if (!usersMode) ...[
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _filterChip(
                              '所有标签',
                              selected:
                                  model.selectedTag == null &&
                                  !model.ungroupedOnly,
                              onSelected: () =>
                                  model.filter(favorites: model.favoritesOnly),
                            ),
                            _filterChip(
                              _ungroupedLabel,
                              key: const ValueKey('filter-ungrouped'),
                              selected: model.ungroupedOnly,
                              onSelected: () => model.filter(
                                favorites: model.favoritesOnly,
                                ungrouped: true,
                              ),
                            ),
                            for (final tag in model.tags)
                              _filterChip(
                                _tagLabel(tag),
                                selected:
                                    !model.ungroupedOnly &&
                                    model.selectedTag == tag,
                                onSelected: () => model.filter(
                                  favorites: model.favoritesOnly,
                                  tag: tag,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                usersMode ? '凭证列表' : '主机列表',
                                style: type.titleMedium,
                              ),
                              Text(
                                '$count',
                                style: type.labelLarge?.copyWith(
                                  color: colors.primary,
                                ),
                              ),
                              if (count > 0 && usersMode)
                                Text(
                                  '点按编辑 · 更多选项管理',
                                  style: type.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (!wide && !usersMode)
                          IconButton(
                            key: const ValueKey('host-sessions'),
                            tooltip: '会话',
                            onPressed: _showSessions,
                            icon: Badge.count(
                              count: model.sessions.length,
                              isLabelVisible: model.sessions.isNotEmpty,
                              child: const Icon(Icons.terminal_outlined),
                            ),
                          ),
                        if (!usersMode)
                          IconButton(
                            key: const ValueKey('toggle-host-addresses'),
                            tooltip: _hideAddresses ? '显示 IP 地址' : '隐藏 IP 地址',
                            onPressed: () => setState(
                              () => _hideAddresses = !_hideAddresses,
                            ),
                            icon: Icon(
                              _hideAddresses
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (count == 0)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverToBoxAdapter(
                  child: _emptyState(usersMode, empty),
                ),
              ),
            if (count > 0 && !grid)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: usersMode
                    ? SliverList.separated(
                        itemCount: count,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: HarborShapes.listGap),
                        itemBuilder: (_, index) => _userCard(
                          users[index],
                          slot: HarborShapes.listSlot(index, count),
                        ),
                      )
                    : hostCollection,
              ),
            if (count > 0 && grid)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: usersMode
                    ? _userCardGrid(
                        users: users,
                        count: count,
                        available: constraints.maxWidth - inset * 2,
                      )
                    : hostCollection,
              ),
            SliverToBoxAdapter(child: SizedBox(height: wide ? 28 : 128)),
          ],
        );
      },
    );
  }

  static const _cardGap = 8.0;
  static const _cardMinHeight = 112.0;

  /// Credential cards keep the plain row grid: only hosts are reorderable, and
  /// a credential carries a single badge line.
  Widget _userCardGrid({
    required List<SshUser> users,
    required int count,
    required double available,
  }) {
    var columns = (available / (380 + _cardGap)).ceil();
    if (columns < 1) columns = 1;
    final rows = (count + columns - 1) ~/ columns;
    return SliverList.separated(
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: _cardGap),
      itemBuilder: (_, row) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var column = 0; column < columns; column++) ...[
            if (column > 0) const SizedBox(width: _cardGap),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _cardMinHeight),
                child: row * columns + column < count
                    ? _userCard(users[row * columns + column], asCard: true)
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _workspaceHeader(bool wide, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final users = model.showingUsers;
    final title = users
        ? '你的连接凭证'
        : model.favoritesOnly
        ? '收藏连接'
        : model.ungroupedOnly
        ? _ungroupedLabel
        : model.selectedTag == null
        ? '连接工作空间'
        : _tagLabel(model.selectedTag!);
    final active = model.sessions
        .where((s) => s.status == ConnectionStatus.connected)
        .length;
    final inlineAction =
        wide && !compact && MediaQuery.textScalerOf(context).scale(16) <= 20;
    final add = FilledButton.icon(
      onPressed: _add,
      icon: const Icon(Icons.add_rounded),
      label: Text(users ? '新建凭证' : '新建连接'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(title, style: type.headlineSmall),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    users
                        ? '${model.users.length} 份凭证'
                        : '${model.hosts.length} 台主机 · $active 个已连接会话',
                    style: type.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (inlineAction) ...[const SizedBox(width: 20), add],
          ],
        ),
        if (wide && !inlineAction) ...[const SizedBox(height: 12), add],
      ],
    );
  }

  Widget _welcome(bool compact) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.primaryContainer,
      shape: HarborShapes.superellipse(HarborShapes.hero),
      child: Padding(
        padding: EdgeInsets.all(compact ? 22 : 28),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        color: colors.onPrimaryContainer,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '为每一次远程连接，留一个港口',
                          style: TextStyle(
                            color: colors.onPrimaryContainer,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '熟悉的终端。\n随行的工作空间。',
                    style: TextStyle(
                      color: colors.onPrimaryContainer,
                      fontSize: compact ? 24 : 30,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '管理主机，切换会话，专注眼前的工作。',
                    style: TextStyle(
                      color: colors.onPrimaryContainer.withValues(alpha: 0.8),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 24),
              Material(
                color: colors.surface.withValues(alpha: 0.72),
                shape: HarborShapes.superellipse(),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: SizedBox(
                    width: 210,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.circle, color: colors.error, size: 8),
                            const SizedBox(width: 6),
                            Icon(Icons.circle, color: colors.tertiary, size: 8),
                            const SizedBox(width: 6),
                            Icon(Icons.circle, color: colors.primary, size: 8),
                            const Spacer(),
                            Text(
                              'QUICK START',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '01  添加你的主机',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '02  核对主机指纹',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '03  开始远程工作  ▌',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(bool users, bool sourceEmpty) {
    final colors = Theme.of(context).colorScheme;
    final type = Theme.of(context).textTheme;
    final favorites = !users && model.favoritesOnly;
    final noFavorites = favorites && !model.hosts.any((host) => host.favorite);
    final ungrouped = !users && model.ungroupedOnly;
    final noUngrouped =
        ungrouped && !model.hosts.any((host) => host.tags.isEmpty);
    return Material(
      color: colors.surfaceContainerLow,
      shape: HarborShapes.superellipse(HarborShapes.tile),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            ExpressiveMark(
              size: 64,
              flower: true,
              icon: noUngrouped
                  ? Icons.folder_outlined
                  : noFavorites
                  ? Icons.star_outline_rounded
                  : sourceEmpty
                  ? (users ? Icons.key_rounded : Icons.add_to_queue_rounded)
                  : Icons.search_rounded,
              color: colors.secondaryContainer,
              foreground: colors.onSecondaryContainer,
            ),
            const SizedBox(height: 20),
            Text(
              noUngrouped
                  ? '暂无未分组主机'
                  : noFavorites
                  ? '暂无收藏连接'
                  : sourceEmpty
                  ? (users ? '先保存一份凭证' : '从第一台服务器开始')
                  : (users
                        ? '没有匹配的凭证'
                        : favorites
                        ? '没有匹配的收藏连接'
                        : '没有匹配的连接'),
              textAlign: TextAlign.center,
              style: type.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              noUngrouped
                  ? (model.hosts.isEmpty
                        ? '新建连接且不设置标签，主机会自动归入这里'
                        : '未设置标签的主机会自动归入这里；当前主机都已设置标签')
                  : noFavorites
                  ? '右键或长按连接卡片，选择“收藏”'
                  : sourceEmpty
                  ? (users ? '新建凭证，生成密钥对或导入 SSH 私钥' : '新建连接，填写主机地址，即可开启终端')
                  : '试试其他关键词，或切换标签',
              textAlign: TextAlign.center,
              style: type.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (!sourceEmpty && !noFavorites && !noUngrouped) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  _search.clear();
                  model.search('');
                  model.filter(
                    users: users,
                    favorites: favorites,
                    ungrouped: ungrouped,
                  );
                },
                child: const Text('清除筛选'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Cards for a reorder宿主. The宿主 owns the key, the drag and the menu
  /// hand-off; the card itself only draws and reports taps.
  HostCardBuilder _hostCards(
    List<Host> hosts,
    int count, {
    bool asCard = false,
  }) =>
      (context, index, menu) => ExpressiveHostCard(
        host: hosts[index],
        slot: asCard
            ? HarborListSlot.single
            : HarborShapes.listSlot(index, count),
        asCard: asCard,
        hideAddress: _hideAddresses,
        menuController: menu,
        onConnect: () => _connect(hosts[index]),
        onFavorite: model.saving
            ? null
            : () => _guard(() => model.toggleFavorite(hosts[index])),
        onAction: (action) => _hostAction(hosts[index], action),
      );

  /// Reordering is off while the model loads or writes an order.
  bool get _canReorder => !model.saving && !model.loading;

  /// One write per drop, and none for a long press that never moved.
  void _reorder(Host source, Host target) =>
      _guard(() => model.reorderHost(source.id, target.id));

  Widget _userCard(
    SshUser user, {
    HarborListSlot slot = HarborListSlot.single,
    bool asCard = false,
  }) => ExpressiveUserCard(
    user: user,
    slot: slot,
    asCard: asCard,
    onOpen: () => _editUser(user),
    onAction: (action) => _userAction(user, action),
  );
}

/// 安装公钥期间的进度弹窗：不能手动关闭，安装一结束就由调用方移除。
class _InstallProgress extends StatelessWidget {
  const _InstallProgress({required this.status});

  final ValueListenable<String> status;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, value, _) => Text(value),
            ),
          ),
        ],
      ),
    ),
  );
}
