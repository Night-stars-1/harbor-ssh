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
    this.titleBarSessions = false,
    this.windowAcrylic = false,
    this.frostedSurfaces = false,
    this.aiPanelWidth,
    this.sidebarWidth = defaultSidebarWidth,
    this.terminalSplitRatio = defaultTerminalSplitRatio,
  });
  final AppThemeMode mode;
  final AppThemeColor color;
  final int terminalFontSize;

  /// Width the AI side panel was last dragged (or nudged) to, or null while
  /// the panel keeps its automatic share of the terminal pane. Stored only on
  /// this device.
  final double? aiPanelWidth;

  /// Width of the desktop navigation sidebar. Renderers clamp the value they
  /// draw against the window, but keep this preference intact so shrinking a
  /// window and widening it again restores the width the user chose.
  final double sidebarWidth;

  /// Share of a fresh terminal split given to its first pane, 0.1 - 0.9.
  /// Changing it never recreates an existing split.
  final double terminalSplitRatio;

  /// Defaults for [sidebarWidth] and [terminalSplitRatio]; also the values a
  /// double-click reset returns to.
  static const double defaultSidebarWidth = 264;
  static const double defaultTerminalSplitRatio = .5;
  static const double minSidebarWidth = 220;
  static const double maxSidebarWidth = 400;
  static const double minAiPanelWidth = 320;
  static const double maxAiPanelWidth = 720;

  /// When false, the terminal keeps each logical line intact and scrolls
  /// horizontally. Stored only on this device.
  final bool terminalWrap;

  /// Remote status sampling cadence. Stored only on this device.
  final int statusRefreshSeconds;

  /// Desktop only: navigation icons live in the custom title bar and the side
  /// panel lists sessions only. Stored only on this device.
  final bool titleBarNavigation;

  /// Desktop only: open sessions are tabs on the left of the custom title bar
  /// instead of a side panel section. Stored only on this device.
  final bool titleBarSessions;

  /// Navigation and sessions both live in the title bar, so wide desktop
  /// layouts show no side panel at all.
  bool get sidebarHidden => titleBarNavigation && titleBarSessions;

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
    bool? titleBarSessions,
    bool? windowAcrylic,
    bool? frostedSurfaces,
    double? aiPanelWidth,
    bool clearAiPanelWidth = false,
    double? sidebarWidth,
    double? terminalSplitRatio,
  }) => AppearancePreferences(
    mode: mode ?? this.mode,
    color: color ?? this.color,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    terminalWrap: terminalWrap ?? this.terminalWrap,
    statusRefreshSeconds: statusRefreshSeconds ?? this.statusRefreshSeconds,
    titleBarNavigation: titleBarNavigation ?? this.titleBarNavigation,
    titleBarSessions: titleBarSessions ?? this.titleBarSessions,
    windowAcrylic: windowAcrylic ?? this.windowAcrylic,
    frostedSurfaces: frostedSurfaces ?? this.frostedSurfaces,
    aiPanelWidth: clearAiPanelWidth
        ? null
        : _aiPanelWidth(aiPanelWidth) ?? this.aiPanelWidth,
    sidebarWidth: _sidebarWidth(sidebarWidth) ?? this.sidebarWidth,
    terminalSplitRatio:
        _terminalSplitRatio(terminalSplitRatio) ?? this.terminalSplitRatio,
  );

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'color': color.name,
    'terminalFontSize': terminalFontSize,
    'terminalWrap': terminalWrap,
    'statusRefreshSeconds': statusRefreshSeconds,
    'titleBarNavigation': titleBarNavigation,
    'titleBarSessions': titleBarSessions,
    'windowAcrylic': windowAcrylic,
    'frostedSurfaces': frostedSurfaces,
    // Layout widths are written only once the user settles them, so the
    // default-valued entries are omitted and older builds read these files
    // unchanged.
    'aiPanelWidth': ?aiPanelWidth,
    if (sidebarWidth != defaultSidebarWidth) 'sidebarWidth': sidebarWidth,
    if (terminalSplitRatio != defaultTerminalSplitRatio)
      'terminalSplitRatio': terminalSplitRatio,
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
    titleBarSessions: json['titleBarSessions'] == true,
    windowAcrylic: json['windowAcrylic'] == true,
    frostedSurfaces: json['frostedSurfaces'] == true,
    aiPanelWidth: _aiPanelWidth(json['aiPanelWidth']),
    sidebarWidth: _sidebarWidth(json['sidebarWidth']) ?? defaultSidebarWidth,
    terminalSplitRatio:
        _terminalSplitRatio(json['terminalSplitRatio']) ??
        defaultTerminalSplitRatio,
  );
  static int _fontSize(Object? value) {
    final size = value is num ? value.round() : int.tryParse('$value');
    return size == null ? 14 : size.clamp(10, 24).toInt();
  }

  static double? _aiPanelWidth(Object? value) {
    final width = _dimension(value);
    return width?.clamp(minAiPanelWidth, maxAiPanelWidth).toDouble();
  }

  static double? _sidebarWidth(Object? value) {
    final width = _dimension(value);
    return width?.clamp(minSidebarWidth, maxSidebarWidth).toDouble();
  }

  static double? _terminalSplitRatio(Object? value) {
    final ratio = _dimension(value);
    return ratio?.clamp(.1, .9).toDouble();
  }

  static double? _dimension(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    return number == null || !number.isFinite ? null : number;
  }

  static int _statusRefreshSeconds(Object? value) {
    final seconds = value is num ? value.round() : int.tryParse('$value');
    return statusRefreshIntervalOptions.contains(seconds) ? seconds! : 5;
  }
}
