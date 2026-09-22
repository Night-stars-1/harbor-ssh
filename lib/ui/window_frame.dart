import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'expressive_widgets.dart';
import 'theme.dart';

bool get usesWindowsTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get usesMacosTitleBar =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

bool get usesCustomTitleBar => usesWindowsTitleBar || usesMacosTitleBar;

const _macosTrafficLightInset = 78.0;

Future<void> initializeWindowsWindow({bool settings = false}) async {
  if (!usesCustomTitleBar) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: settings ? '设置 · Harbor SSH' : 'Harbor SSH',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: usesMacosTitleBar,
      minimumSize: settings ? const Size(360, 560) : const Size(320, 480),
    ),
  );
  if (usesMacosTitleBar) {
    // MainFlutterWindow hides the native window until configuration is ready.
    await windowManager.show();
    await windowManager.focus();
  }
}

/// Lives outside the navigator so dialogs keep the window controls accessible.
class WindowsWindowFrame extends StatefulWidget {
  const WindowsWindowFrame({
    super.key,
    required this.child,
    this.title = 'Harbor SSH',
  });
  final Widget child;
  final String title;

  @override
  State<WindowsWindowFrame> createState() => _WindowsWindowFrameState();
}

class _WindowsWindowFrameState extends State<WindowsWindowFrame>
    with WindowListener {
  bool _maximized = false;
  bool _focused = true;
  bool _fullScreen = false;
  Brightness? _brightness;

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
    final brightness = Theme.of(context).brightness;
    if (_brightness != brightness) {
      _brightness = brightness;
      unawaited(windowManager.setBrightness(brightness));
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
  void onWindowLeaveFullScreen() => setState(() => _fullScreen = false);

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
    return Column(
      children: [
        if (!_fullScreen)
          Material(
            key: const ValueKey('windows-title-bar'),
            color: colors.surfaceContainerLow,
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  if (usesMacosTitleBar)
                    const SizedBox(
                      key: ValueKey('macos-traffic-light-inset'),
                      width: _macosTrafficLightInset,
                    ),
                  Expanded(
                    child: GestureDetector(
                      key: const ValueKey('window-drag-area'),
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => windowManager.startDragging(),
                      onDoubleTap: _toggleMaximize,
                      onSecondaryTap: usesMacosTitleBar
                          ? null
                          : windowManager.popUpWindowMenu,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: usesMacosTitleBar ? 0 : 14,
                        ),
                        child: Row(
                          children: [
                            const ExpressiveMark(size: 24, flower: true),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
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
  }
}
