import 'dart:async';

import 'package:flutter/material.dart';

import '../data/ssh_connection.dart';
import '../domain/host.dart';
import '../domain/appearance.dart';
import 'host_editor.dart';
import 'host_identity_dialog.dart';
import 'expressive_widgets.dart';
import 'reorderable_host_collection.dart';
import 'terminal_pane.dart';
import 'terminal_workspace.dart';
import 'theme.dart';
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
  const HarborApp({super.key, required this.model, this.settingsWindow});
  final WorkspaceModel model;
  final SettingsWindowHost? settingsWindow;
  @override
  State<HarborApp> createState() => _HarborAppState();
}

class _HarborAppState extends State<HarborApp> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.model.initialize());
  }

  @override
  void dispose() {
    widget.settingsWindow?.dispose();
    widget.model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SystemColorScope(
    child: ValueListenableBuilder<AppearancePreferences>(
      valueListenable: widget.model.appearance,
      builder: (context, appearance, _) => MaterialApp(
        title: 'Harbor SSH',
        debugShowCheckedModeBanner: false,
        theme: harborTheme(
          dynamicScheme: SystemColorScope.of(context)?.light,
          color: appearance.color,
          reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
        ),
        darkTheme: harborTheme(
          dynamicScheme: SystemColorScope.of(context)?.dark,
          color: appearance.color,
          brightness: Brightness.dark,
          reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
        ),
        themeAnimationDuration:
            MediaQuery.maybeOf(context)?.disableAnimations == true
            ? Duration.zero
            : HarborMotion.effectsDuration,
        themeMode: flutterThemeMode(appearance.mode),
        builder: (context, child) =>
            usesCustomTitleBar ? WindowsWindowFrame(child: child!) : child!,
        home: Builder(
          builder: (context) => Workspace(
            model: widget.model,
            onOpenSettings: widget.settingsWindow == null
                ? null
                : () => widget.settingsWindow!.open(),
            onToggleTheme: () async {
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
            },
          ),
        ),
      ),
    ),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({
    super.key,
    required this.model,
    required this.onToggleTheme,
    this.onOpenSettings,
  });
  final WorkspaceModel model;
  final VoidCallback onToggleTheme;
  final Future<void> Function()? onOpenSettings;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  WorkspaceModel get model => widget.model;
  late final _search = TextEditingController(text: model.query);
  final _terminalController = TerminalPaneController();
  bool _sidebarCollapsed = false;
  bool _hideAddresses = false;
  bool _settingsOpened = false;
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
      !model.showingUsers;

  /// 真实标签恰好同名时，仅在显示上加以区分。
  String _tagLabel(String tag) => tag == _ungroupedLabel ? '$tag（标签）' : tag;

  @override
  void dispose() {
    _search.dispose();
    _settingsNavigation.dispose();
    super.dispose();
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
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => HostEditor(
          host: host,
          credentials: credentials,
          users: model.users,
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
      await showDialog<void>(
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
      final stored = await model.repository.credentials(host.id);
      if (!mounted) return;
      final inherited = host.userId.isEmpty
          ? null
          : await model.repository.userCredentials(host.userId);
      if (!mounted) return;
      final credentials = stored ?? inherited;
      if (credentials == null) {
        _message(
          host.authMethod == AuthMethod.password
              ? '请填写连接密码。'
              : '请为连接选择已保存的私钥凭证。',
        );
        _opening = false;
        await _edit(host);
      } else if (mounted) {
        _start(host, credentials);
      }
    } catch (_) {
      if (mounted) _message('无法读取凭据，请检查系统安全存储权限。');
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
    );
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
        session: session,
      );
    } else {
      files.activate(1, existing.id);
    }
    FocusManager.instance.primaryFocus?.unfocus();
    model.showFiles();
  }

  Future<SshConnection?> _connectFiles(Host host) async {
    final stored = await model.repository.credentials(host.id);
    final credentials =
        stored ??
        (host.userId.isEmpty
            ? null
            : await model.repository.userCredentials(host.userId));
    if (!mounted) return null;
    if (credentials == null) {
      _message('请先为连接保存密码或选择私钥凭证');
      await _edit(host);
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
    );
    if (!mounted || session.status != ConnectionStatus.connected) {
      final error = session.error;
      session.dispose();
      if (mounted) _message(error ?? 'SFTP 连接失败');
      return null;
    }
    return session;
  }

  Future<bool> _trustHost(Host host, String type, String fingerprint) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => HostIdentityDialog(
            host: host,
            keyType: type,
            fingerprint: fingerprint,
          ),
        ) ??
        false;
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
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
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
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
      _settingsNavigation.value = null;
    } else {
      model.closeSettings();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([model, _settingsNavigation]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final maxSidebarWidth = (constraints.maxWidth - 540).clamp(
          220.0,
          400.0,
        );
        final sidebarWidth = _sidebarWidth.clamp(220.0, maxSidebarWidth);
        final colors = Theme.of(context).colorScheme;
        if (model.showingSettings) _settingsOpened = true;
        final terminalSession = model.showingFiles || model.showingSettings
            ? null
            : model.activeSession;
        final canAdd = !model.loading && model.loadError == null;
        final nestedPage =
            model.showingSettings ||
            model.showingFiles ||
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
                      _themeButton(),
                      if (terminalSession == null && !model.showingSettings)
                        _settingsButton(),
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
                        ),
                      if (terminalSession == null &&
                          !model.showingSettings &&
                          !model.showingFiles)
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
                    selectedIndex: model.showingFiles
                        ? 2
                        : model.showingUsers
                        ? 1
                        : 0,
                    onDestinationSelected: (index) => index == 2
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
                    ],
                  )
                : null,
            body: SafeArea(
              top: wide,
              child: Row(
                children: [
                  if (wide) ...[
                    SizedBox(
                      key: const ValueKey('workspace-sidebar'),
                      width: _sidebarCollapsed ? 80 : sidebarWidth,
                      child: _sidebar(),
                    ),
                    if (!_sidebarCollapsed)
                      _sidebarResizeHandle(sidebarWidth, maxSidebarWidth),
                  ],
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide && _sidebarCollapsed ? 8 : 0,
                        wide ? 12 : 0,
                        wide ? 12 : 0,
                        wide ? 12 : 0,
                      ),
                      child: Material(
                        color: colors.surface,
                        borderRadius: wide
                            ? BorderRadius.circular(32)
                            : BorderRadius.zero,
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            Expanded(
                              child: IndexedStack(
                                index: model.showingSettings
                                    ? 2
                                    : model.showingFiles
                                    ? 1
                                    : 0,
                                children: [
                                  ExcludeFocus(
                                    excluding:
                                        model.showingSettings ||
                                        model.showingFiles,
                                    child: IndexedStack(
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
                                            desktop: wide,
                                            visible:
                                                !model.showingSettings &&
                                                !model.showingFiles &&
                                                model.activeSession != null,
                                            mobileController:
                                                _terminalController,
                                            onSelect: model.selectSession,
                                            onConnect: _connect,
                                            onClose: _closeSession,
                                            onFiles: _openSessionFiles,
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
                                      showTitle: false,
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

  Widget _themeButton() => IconButton(
    onPressed: widget.onToggleTheme,
    tooltip: '切换浅色/深色主题',
    icon: Icon(
      Theme.of(context).brightness == Brightness.dark
          ? Icons.light_mode_rounded
          : Icons.dark_mode_rounded,
    ),
  );

  Widget _settingsButton() => IconButton(
    key: const ValueKey('settings-button'),
    onPressed: model.loading
        ? null
        : () async {
            if (widget.onOpenSettings == null) {
              model.showSettings();
              return;
            }
            try {
              await widget.onOpenSettings!();
            } catch (_) {
              if (mounted) _message('无法打开设置窗口，请重新启动应用后重试');
            }
          },
    isSelected: model.showingSettings,
    selectedIcon: const Icon(Icons.settings_rounded, semanticLabel: '设置'),
    icon: const Icon(Icons.settings_outlined, semanticLabel: '设置'),
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
        color: colors.surfaceContainerLow,
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
                  _navItem(
                    Icons.dns_rounded,
                    '所有连接',
                    '${model.hosts.length}',
                    model.activeSessionId == null &&
                        !model.showingSettings &&
                        !model.showingFiles &&
                        !model.showingUsers &&
                        !model.favoritesOnly &&
                        !model.ungroupedOnly &&
                        model.selectedTag == null,
                    () => model.filter(),
                    bottomSpacing: 0,
                  ),
                  _navItem(
                    Icons.star_rounded,
                    '收藏',
                    '${model.hosts.where((h) => h.favorite).length}',
                    model.activeSessionId == null &&
                        !model.showingSettings &&
                        !model.showingFiles &&
                        !model.showingUsers &&
                        model.favoritesOnly,
                    () => model.filter(favorites: true),
                    bottomSpacing: 0,
                  ),
                  _navItem(
                    Icons.vpn_key_rounded,
                    '凭证',
                    '${model.users.length}',
                    model.activeSessionId == null &&
                        model.showingUsers &&
                        !model.showingSettings &&
                        !model.showingFiles,
                    () => model.filter(users: true),
                    bottomSpacing: 0,
                  ),
                  _navItem(
                    Icons.folder_copy_rounded,
                    'SFTP',
                    '',
                    model.showingFiles && !model.showingSettings,
                    model.showFiles,
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
                          model.activeSessionId == null &&
                          !model.showingUsers,
                      () => model.filter(tag: tag),
                    ),
                  _sectionLabel('会话'),
                  if (model.sessions.isEmpty && !_sidebarCollapsed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '连接主机后，会话会显示在这里。',
                        style: type.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final session in model.sessions)
                    _sessionNavItem(session),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Flex(
                direction: _sidebarCollapsed ? Axis.vertical : Axis.horizontal,
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('sidebar-toggle'),
                    onPressed: () => setState(() {
                      _sidebarCollapsed = !_sidebarCollapsed;
                    }),
                    icon: Icon(
                      _sidebarCollapsed
                          ? Icons.keyboard_double_arrow_right_rounded
                          : Icons.keyboard_double_arrow_left_rounded,
                      semanticLabel: _sidebarCollapsed ? '展开侧栏' : '折叠侧栏',
                    ),
                  ),
                  if (!_sidebarCollapsed) const Spacer(),
                  _settingsButton(),
                  _themeButton(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
        !model.showingFiles;
    final select = onSelected ?? () => model.selectSession(session.id);
    return MenuAnchor(
      key: ValueKey('session-menu-${session.id}'),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainer),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        elevation: const WidgetStatePropertyAll(2),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
      menuChildren: [
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
          onPressed: () => _closeSession(session),
          leadingIcon: const Icon(Icons.close_rounded, size: 20),
          child: const Text('关闭会话'),
        ),
      ],
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
                  Icons.terminal_rounded,
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
                Icons.terminal_rounded,
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
              Text(model.loadError!),
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
