import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'expressive_widgets.dart';
import 'theme.dart';

bool get usesWindowsTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get usesMacosTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

bool get usesLinuxTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

bool get usesCustomTitleBar =>
    usesWindowsTitleBar || usesMacosTitleBar || usesLinuxTitleBar;

const _macosTrafficLightInset = 78.0;

const _windowEffect = MethodChannel('harbor/window_effect');

/// Whether this window can show the native system backdrop: Windows 11 22H2
/// or later, macOS, or a Linux desktop whose compositor exposes KDE/KWin
/// background blur. Resolved by [initializeWindowsWindow]; unsupported
/// platforms and missing window-effect channels keep windows opaque.
bool windowAcrylicSupported = false;

/// Main window size on macOS when the side panel is hidden: the default
/// 1280-wide window minus the 264-wide sidebar and its 8-wide resize handle.
const macosSidebarlessWindowSize = Size(1008, 800);

Future<void> initializeWindowsWindow({
  bool settings = false,
  bool ai = false,
  Size? size,
}) async {
  if (!usesCustomTitleBar) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: settings
          ? '设置 · Harbor SSH'
          : ai
          ? 'AI 助手 · Harbor SSH'
          : 'Harbor SSH',
      // Applied while the window is still hidden, then centred so the smaller
      // window does not sit off to one side of where the larger one was.
      size: size,
      center: size != null ? true : null,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: usesMacosTitleBar,
      minimumSize: settings
          ? const Size(360, 560)
          : ai
          ? const Size(480, 520)
          : const Size(320, 480),
    ),
  );
  if (usesMacosTitleBar) {
    // MainFlutterWindow hides the native window until configuration is ready.
    await windowManager.show();
    await windowManager.focus();
  }
  if (usesWindowsTitleBar || usesMacosTitleBar || usesLinuxTitleBar) {
    try {
      windowAcrylicSupported =
          await _windowEffect.invokeMethod<bool>('supported') == true;
    } on PlatformException {
      windowAcrylicSupported = false;
    } on MissingPluginException {
      // Desktop runners without a window-effect channel stay opaque.
      windowAcrylicSupported = false;
    }
  }
}

/// Lives outside the navigator so dialogs keep the window controls accessible.
class WindowsWindowFrame extends StatefulWidget {
  const WindowsWindowFrame({
    super.key,
    required this.child,
    this.title = 'Harbor SSH',
    this.leading,
    this.tabs,
    this.actions = const [],
  });
  final Widget child;
  final String title;

  /// Shown before the app mark, e.g. a side panel toggle.
  final Widget? leading;

  /// Shown after the app mark in place of the title, e.g. session tabs. The
  /// empty space after them still drags the window.
  final Widget? tabs;

  /// Shown before the window buttons, e.g. workspace navigation.
  final List<Widget> actions;

  @override
  State<WindowsWindowFrame> createState() => _WindowsWindowFrameState();
}

class _WindowsWindowFrameState extends State<WindowsWindowFrame>
    with WindowListener {
  bool _maximized = false;
  bool _focused = true;
  bool _fullScreen = false;
  Brightness? _brightness;
  bool _acrylic = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_refreshState());
  }

  Future<void> _refreshState() async {
    final states = await Future.wait([
      windowManager.isMaximized(),
      windowManager.isFocused(),
      windowManager.isFullScreen(),
    ]);
    if (!mounted) return;
    setState(() {
      _maximized = states[0];
      _focused = states[1];
      _fullScreen = states[2];
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final brightnessChanged = _brightness != brightness;
    if (brightnessChanged) {
      _brightness = brightness;
      unawaited(windowManager.setBrightness(brightness));
    }
    final acrylic = theme.windowBackdrop.acrylic;
    if (acrylic != _acrylic || (acrylic && brightnessChanged)) {
      _acrylic = acrylic;
      _applyAcrylic();
    }
  }

  /// The native side tints the backdrop with the app theme brightness.
  void _applyAcrylic() => unawaited(_setNativeAcrylic());

  Future<void> _setNativeAcrylic() async {
    try {
      await _windowEffect.invokeMethod<bool>('setAcrylic', {
        'enabled': _acrylic,
        'dark': _brightness == Brightness.dark,
      });
    } on MissingPluginException {
      // A desktop runner without the effect channel cannot blur; the theme
      // only enables acrylic after [windowAcrylicSupported] succeeded.
      return;
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);
  @override
  void onWindowFocus() => setState(() => _focused = true);
  @override
  void onWindowBlur() => setState(() => _focused = false);
  @override
  void onWindowEnterFullScreen() => setState(() => _fullScreen = true);
  @override
  void onWindowLeaveFullScreen() {
    setState(() => _fullScreen = false);
    // Leaving full screen resets the DWM frame the backdrop shows through.
    if (_acrylic && usesWindowsTitleBar) _applyAcrylic();
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Widget _button({
    required String name,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    bool close = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      key: ValueKey('window-$name'),
      onPressed: onPressed,
      icon: Icon(icon, size: 17, semanticLabel: label),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 32)),
        maximumSize: const WidgetStatePropertyAll(Size(44, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll(
          HarborShapes.superellipse(BorderRadius.circular(10)),
        ),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (close && states.contains(WidgetState.hovered)) {
            return colors.onErrorContainer;
          }
          return _focused ? colors.onSurface : colors.onSurfaceVariant;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return close
                ? colors.errorContainer
                : colors.primary.withValues(alpha: .16);
          }
          if (states.contains(WidgetState.hovered)) {
            return close
                ? colors.errorContainer
                : colors.onSurface.withValues(alpha: .08);
          }
          return null;
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Navigation hosted in the bar must stay reachable in full screen.
    final hostsNavigation =
        widget.leading != null ||
        widget.tabs != null ||
        widget.actions.isNotEmpty;
    final titleInset = usesMacosTitleBar || widget.leading != null ? 0.0 : 14.0;
    final frame = Column(
      children: [
        if (!_fullScreen || hostsNavigation)
          Material(
            key: const ValueKey('windows-title-bar'),
            color: Theme.of(context).windowBackdrop
                .chrome(colors.surfaceContainerLow),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  if (usesMacosTitleBar && !_fullScreen)
                    const SizedBox(
                      key: ValueKey('macos-traffic-light-inset'),
                      width: _macosTrafficLightInset,
                    ),
                  if (widget.leading != null)
                    Padding(
                      padding: EdgeInsets.only(left: usesMacosTitleBar ? 0 : 6),
                      child: widget.leading,
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('window-drag-area'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => windowManager.startDragging(),
                            onDoubleTap: _toggleMaximize,
                            onSecondaryTap: usesMacosTitleBar
                                ? null
                                : windowManager.popUpWindowMenu,
                            child: Padding(
                              padding: EdgeInsets.only(left: titleInset),
                              child: Row(
                                children: [
                                  const ExpressiveMark(size: 24, flower: true),
                                  const SizedBox(width: 8),
                                  if (widget.tabs == null)
                                    Expanded(
                                      child: Text(
                                        widget.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              color: _focused
                                                  ? colors.onSurface
                                                  : colors.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Above the drag area: the tabs take their own clicks
                        // while the bar around them keeps dragging the window.
                        if (widget.tabs != null)
                          Padding(
                            padding: EdgeInsets.only(left: titleInset + 32),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: widget.tabs,
                            ),
                          ),
                      ],
                    ),
                  ),
                  ...widget.actions,
                  if (widget.actions.isNotEmpty) const SizedBox(width: 6),
                  if (!usesMacosTitleBar) ...[
                    _button(
                      name: 'minimize',
                      label: '最小化',
                      icon: Icons.horizontal_rule_rounded,
                      onPressed: windowManager.minimize,
                    ),
                    _button(
                      name: 'maximize',
                      label: _maximized ? '还原窗口' : '最大化',
                      icon: _maximized
                          ? Icons.filter_none_rounded
                          : Icons.crop_square_rounded,
                      onPressed: _toggleMaximize,
                    ),
                    _button(
                      name: 'close',
                      label: '关闭窗口',
                      icon: Icons.close_rounded,
                      onPressed: windowManager.close,
                      close: true,
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
        Expanded(child: Semantics(container: true, child: widget.child)),
      ],
    );
    // Title bar tooltips need an overlay; the navigator's sits below the bar.
    // Always present so toggling bar content never remounts the app below.
    final overlaid = Overlay.wrap(child: frame);
    if (!usesLinuxTitleBar) return overlaid;
    // Linux has no native resize border once the header bar is hidden, so the
    // shared frame is wrapped in Flutter-drawn resize edges. The wrapper adds
    // no visible border and is disabled while maximized or full screen.
    return DragToResizeArea(
      key: const ValueKey('linux-resize-area'),
      enableResizeEdges: _maximized || _fullScreen
          ? const <ResizeEdge>[]
          : null,
      child: overlaid,
    );
  }
}
