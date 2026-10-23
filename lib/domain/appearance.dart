enum AppThemeMode { system, light, dark }

const statusRefreshIntervalOptions = [2, 5, 10, 30];

enum AppThemeColor {
  dynamic('动态', 0xFF6750A4),
  defaultColor('默认', 0xFF6750A4),
  teal('青绿', 0xFF008577),
  blue('蓝色', 0xFF1565C0),
  purple('紫色', 0xFF7E57C2),
  pink('玫红', 0xFFB53678),
  orange('橙色', 0xFFB85C00),
  green('绿色', 0xFF438344);

  const AppThemeColor(this.label, this.seed);
  final String label;
  final int seed;
}

class AppearancePreferences {
  const AppearancePreferences({
    this.mode = AppThemeMode.system,
    this.color = AppThemeColor.defaultColor,
    this.terminalFontSize = 14,
    this.terminalWrap = true,
    this.statusRefreshSeconds = 5,
    this.titleBarNavigation = false,
    this.windowAcrylic = false,
    this.frostedSurfaces = false,
  });
  final AppThemeMode mode;
  final AppThemeColor color;
  final int terminalFontSize;

  /// When false, the terminal keeps each logical line intact and scrolls
  /// horizontally. Stored only on this device.
  final bool terminalWrap;

  /// Remote status sampling cadence. Stored only on this device.
  final int statusRefreshSeconds;

  /// Desktop only: navigation icons live in the custom title bar and the side
  /// panel lists sessions only. Stored only on this device.
  final bool titleBarNavigation;

  /// Desktop only: the window shows the native system backdrop through
  /// translucent app surfaces. Windows uses acrylic material, macOS uses
  /// vibrancy, and Linux uses KDE/KWin background blur when available.
  /// Stored only on this device.
  final bool windowAcrylic;

  /// Menus, dialogs and sheets are translucent and blur the app content
  /// below them. Independent of [windowAcrylic]. Stored only on this device.
  final bool frostedSurfaces;

  AppearancePreferences copyWith({
    AppThemeMode? mode,
    AppThemeColor? color,
    int? terminalFontSize,
    bool? terminalWrap,
    int? statusRefreshSeconds,
    bool? titleBarNavigation,
    bool? windowAcrylic,
    bool? frostedSurfaces,
  }) => AppearancePreferences(
    mode: mode ?? this.mode,
    color: color ?? this.color,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    terminalWrap: terminalWrap ?? this.terminalWrap,
    statusRefreshSeconds: statusRefreshSeconds ?? this.statusRefreshSeconds,
    titleBarNavigation: titleBarNavigation ?? this.titleBarNavigation,
    windowAcrylic: windowAcrylic ?? this.windowAcrylic,
    frostedSurfaces: frostedSurfaces ?? this.frostedSurfaces,
  );

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'color': color.name,
    'terminalFontSize': terminalFontSize,
    'terminalWrap': terminalWrap,
    'statusRefreshSeconds': statusRefreshSeconds,
    'titleBarNavigation': titleBarNavigation,
    'windowAcrylic': windowAcrylic,
    'frostedSurfaces': frostedSurfaces,
  };

  factory AppearancePreferences.fromJson(
    Map<dynamic, dynamic> json,
  ) => AppearancePreferences(
    mode:
        AppThemeMode.values.where((v) => v.name == json['mode']).firstOrNull ??
        AppThemeMode.system,
    color:
        AppThemeColor.values
            .where((v) => v.name == json['color'])
            .firstOrNull ??
        AppThemeColor.defaultColor,
    terminalFontSize: _fontSize(json['terminalFontSize']),
    terminalWrap: json['terminalWrap'] != false,
    statusRefreshSeconds: _statusRefreshSeconds(json['statusRefreshSeconds']),
    titleBarNavigation: json['titleBarNavigation'] == true,
    windowAcrylic: json['windowAcrylic'] == true,
    frostedSurfaces: json['frostedSurfaces'] == true,
  );
  static int _fontSize(Object? value) {
    final size = value is num ? value.round() : int.tryParse('$value');
    return size == null ? 14 : size.clamp(10, 24).toInt();
  }

  static int _statusRefreshSeconds(Object? value) {
    final seconds = value is num ? value.round() : int.tryParse('$value');
    return statusRefreshIntervalOptions.contains(seconds) ? seconds! : 5;
  }
}
