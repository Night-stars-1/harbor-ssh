enum AppThemeMode { system, light, dark }

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
  });
  final AppThemeMode mode;
  final AppThemeColor color;
  final int terminalFontSize;

  /// When false, the terminal keeps each logical line intact and scrolls
  /// horizontally. Stored only on this device.
  final bool terminalWrap;

  AppearancePreferences copyWith({
    AppThemeMode? mode,
    AppThemeColor? color,
    int? terminalFontSize,
    bool? terminalWrap,
  }) => AppearancePreferences(
    mode: mode ?? this.mode,
    color: color ?? this.color,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    terminalWrap: terminalWrap ?? this.terminalWrap,
  );

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'color': color.name,
    'terminalFontSize': terminalFontSize,
    'terminalWrap': terminalWrap,
  };

  factory AppearancePreferences.fromJson(Map<dynamic, dynamic> json) =>
      AppearancePreferences(
        mode:
            AppThemeMode.values
                .where((v) => v.name == json['mode'])
                .firstOrNull ??
            AppThemeMode.system,
        color:
            AppThemeColor.values
                .where((v) => v.name == json['color'])
                .firstOrNull ??
            AppThemeColor.defaultColor,
        terminalFontSize: _fontSize(json['terminalFontSize']),
        terminalWrap: json['terminalWrap'] != false,
      );
  static int _fontSize(Object? value) {
    final size = value is num ? value.round() : int.tryParse('$value');
    return size == null ? 14 : size.clamp(10, 24).toInt();
  }
}
