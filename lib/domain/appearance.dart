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
  });
  final AppThemeMode mode;
  final AppThemeColor color;

  AppearancePreferences copyWith({AppThemeMode? mode, AppThemeColor? color}) =>
      AppearancePreferences(
        mode: mode ?? this.mode,
        color: color ?? this.color,
      );

  Map<String, String> toJson() => {'mode': mode.name, 'color': color.name};

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
      );
}
