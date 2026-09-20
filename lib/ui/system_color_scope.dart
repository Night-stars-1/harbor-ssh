import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const systemColorChannel = MethodChannel('harbor/system_colors');

/// Each engine reads the same OS palette; user preferences remain in the main engine.
class SystemColorScope extends StatefulWidget {
  const SystemColorScope({super.key, required this.child});
  final Widget child;

  static SystemColorPalette? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SystemColorPalette>();

  @override
  State<SystemColorScope> createState() => _SystemColorScopeState();
}

class _SystemColorScopeState extends State<SystemColorScope>
    with WidgetsBindingObserver {
  ColorScheme? _light, _dark;
  bool _loaded = false, _refreshing = false, _pending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    systemColorChannel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await _refresh();
    });
    unawaited(_refresh());
  }

  Future<(ColorScheme?, ColorScheme?)> _read() async {
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        return (
          palette.toColorScheme(),
          palette.toColorScheme(brightness: Brightness.dark),
        );
      }
    } on PlatformException {
      // Try the desktop accent API if the platform has no wallpaper palette.
    }
    try {
      final accent = await DynamicColorPlugin.getAccentColor();
      if (accent != null) {
        return (
          ColorScheme.fromSeed(seedColor: accent),
          ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
        );
      }
    } on PlatformException {
      // Unsupported devices use the app's default palette.
    }
    return (null, null);
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _pending = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _pending = false;
        final (light, dark) = await _read();
        if (!mounted) return;
        if (!_loaded || light != _light || dark != _dark) {
          setState(() {
            _light = light;
            _dark = dark;
            _loaded = true;
          });
        }
      } while (_pending && mounted);
    } finally {
      _refreshing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void didChangePlatformBrightness() => unawaited(_refresh());

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    systemColorChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SystemColorPalette(
    light: _light,
    dark: _dark,
    loaded: _loaded,
    child: widget.child,
  );
}

class SystemColorPalette extends InheritedWidget {
  const SystemColorPalette({
    super.key,
    required this.light,
    required this.dark,
    required this.loaded,
    required super.child,
  });
  final ColorScheme? light, dark;
  final bool loaded;
  bool get available => light != null && dark != null;

  @override
  bool updateShouldNotify(SystemColorPalette oldWidget) =>
      light != oldWidget.light ||
      dark != oldWidget.dark ||
      loaded != oldWidget.loaded;
}
