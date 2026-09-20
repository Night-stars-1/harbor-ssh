import 'package:flutter/material.dart';

import '../domain/appearance.dart';

ThemeMode flutterThemeMode(AppThemeMode mode) => switch (mode) {
  AppThemeMode.system => ThemeMode.system,
  AppThemeMode.light => ThemeMode.light,
  AppThemeMode.dark => ThemeMode.dark,
};

final _harborSchemes = <(Brightness, AppThemeColor), ColorScheme>{};

ColorScheme harborColorScheme({
  Brightness brightness = Brightness.light,
  AppThemeColor color = AppThemeColor.defaultColor,
}) => _harborSchemes.putIfAbsent(
  (brightness, color),
  () => ColorScheme.fromSeed(
    seedColor: Color(color.seed),
    brightness: brightness,
    dynamicSchemeVariant:
        color == AppThemeColor.defaultColor || color == AppThemeColor.dynamic
        ? DynamicSchemeVariant.expressive
        : DynamicSchemeVariant.tonalSpot,
  ),
);

enum HarborListSlot { single, first, middle, last }

abstract final class HarborShapes {
  static const Radius xs = Radius.circular(8);
  static const Radius sm = Radius.circular(12);
  static const Radius md = Radius.circular(16);
  static const Radius lg = Radius.circular(20);
  static const Radius xl = Radius.circular(28);
  static const Radius xxl = Radius.circular(40);
  static const double listGap = 2;

  static const BorderRadius card = BorderRadius.all(lg);
  static const BorderRadius tile = BorderRadius.all(xl);
  static const BorderRadius dialog = BorderRadius.all(xl);
  static const BorderRadius hero = BorderRadius.only(
    topLeft: xxl,
    topRight: md,
    bottomLeft: md,
    bottomRight: xxl,
  );
  static const StadiumBorder pill = StadiumBorder();

  static HarborListSlot listSlot(int index, int length) {
    if (length <= 1) return HarborListSlot.single;
    if (index == 0) return HarborListSlot.first;
    if (index == length - 1) return HarborListSlot.last;
    return HarborListSlot.middle;
  }

  static BorderRadius listItem(HarborListSlot slot) => switch (slot) {
    HarborListSlot.single => const BorderRadius.all(xl),
    HarborListSlot.first => const BorderRadius.only(
      topLeft: xl,
      topRight: xl,
      bottomLeft: xs,
      bottomRight: xs,
    ),
    HarborListSlot.middle => const BorderRadius.all(xs),
    HarborListSlot.last => const BorderRadius.only(
      topLeft: xs,
      topRight: xs,
      bottomLeft: xl,
      bottomRight: xl,
    ),
  };

  static RoundedSuperellipseBorder superellipse([BorderRadius radius = card]) =>
      RoundedSuperellipseBorder(borderRadius: radius);
}

ThemeData harborTheme({
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  AppThemeColor color = AppThemeColor.defaultColor,
  ColorScheme? dynamicScheme,
}) {
  final colors = color == AppThemeColor.dynamic && dynamicScheme != null
      ? dynamicScheme
      : harborColorScheme(brightness: brightness, color: color);
  const fallbacks = [
    'Roboto',
    'PingFang SC',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'sans-serif',
  ];
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    brightness: brightness,
    fontFamily: 'Segoe UI',
    fontFamilyFallback: fallbacks,
    visualDensity: VisualDensity.standard,
  );
  TextStyle buttonType({required FontWeight weight}) => TextStyle(
    fontFamily: 'Segoe UI',
    fontFamilyFallback: fallbacks,
    fontSize: 14,
    fontWeight: weight,
  );
  final pill = const WidgetStatePropertyAll<OutlinedBorder>(HarborShapes.pill);
  final buttonShape = WidgetStateProperty.resolveWith<OutlinedBorder>(
    (states) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(
        states.contains(WidgetState.pressed) ? 16 : 32,
      ),
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: colors.surfaceContainerLow,
    textTheme: base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        height: 1.2,
      ),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        height: 1.25,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'Segoe UI',
        fontFamilyFallback: fallbacks,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: colors.surfaceContainerLow,
      indicatorColor: colors.secondaryContainer,
      indicatorShape: HarborShapes.pill,
      tileHeight: 56,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surfaceContainer,
      indicatorColor: colors.secondaryContainer,
      indicatorShape: HarborShapes.pill,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: colors.onSurface,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: HarborShapes.superellipse(),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHighest),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed) ||
            states.contains(WidgetState.focused)) {
          return colors.onSurface.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.hovered)) {
          return colors.onSurface.withValues(alpha: 0.08);
        }
        return Colors.transparent;
      }),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: colors.primary, width: 2)
            : BorderSide.none,
      ),
      hintStyle: WidgetStatePropertyAll(
        TextStyle(color: colors.onSurfaceVariant),
      ),
      textStyle: WidgetStatePropertyAll(TextStyle(color: colors.onSurface)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18),
      ),
      shape: const WidgetStatePropertyAll(HarborShapes.pill),
      constraints: const BoxConstraints(minHeight: 56),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.error, width: 2),
      ),
      labelStyle: TextStyle(color: colors.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            minimumSize: const Size(64, 48),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            textStyle: buttonType(weight: FontWeight.w700),
          ).copyWith(
            shape: buttonShape,
            animationDuration: reduceMotion
                ? Duration.zero
                : HarborMotion.effectsDuration,
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            minimumSize: const Size(64, 48),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            side: BorderSide(color: colors.outline),
            shape: HarborShapes.pill,
            textStyle: buttonType(weight: FontWeight.w600),
          ).copyWith(
            shape: buttonShape,
            animationDuration: reduceMotion
                ? Duration.zero
                : HarborMotion.effectsDuration,
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style:
          TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: HarborShapes.pill,
          ).copyWith(
            shape: buttonShape,
            animationDuration: reduceMotion
                ? Duration.zero
                : HarborMotion.effectsDuration,
          ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style:
          IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedSuperellipseBorder(borderRadius: HarborShapes.card),
          ).copyWith(
            animationDuration: reduceMotion
                ? Duration.zero
                : HarborMotion.effectsDuration,
            shape: WidgetStateProperty.resolveWith(
              (states) => RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  states.contains(WidgetState.pressed) ? 12 : 24,
                ),
              ),
            ),
          ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: colors.primaryContainer,
      foregroundColor: colors.onPrimaryContainer,
      elevation: 0,
      hoverElevation: 0,
      focusElevation: 0,
      disabledElevation: 0,
      highlightElevation: 0,
      shape: RoundedSuperellipseBorder(borderRadius: HarborShapes.card),
      extendedSizeConstraints: const BoxConstraints(minHeight: 56),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: pill,
        minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
        visualDensity: VisualDensity.standard,
        side: WidgetStatePropertyAll(BorderSide(color: colors.outlineVariant)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.secondaryContainer
              : colors.surfaceContainerLow,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.onSecondaryContainer
              : colors.onSurfaceVariant,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surfaceContainerHighest,
      selectedColor: colors.secondaryContainer,
      labelStyle: base.textTheme.labelLarge?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
      ),
      shape: HarborShapes.pill,
      side: BorderSide.none,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceContainerHigh,
      shape: HarborShapes.superellipse(HarborShapes.dialog),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceContainerHigh,
      shape: HarborShapes.superellipse(HarborShapes.tile),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.inverseSurface,
      contentTextStyle: TextStyle(color: colors.onInverseSurface),
      shape: HarborShapes.superellipse(),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.primary,
      linearTrackColor: colors.secondaryContainer,
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, space: 1),
  );
}

Duration expressiveDuration(BuildContext context, {bool emphasized = false}) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: emphasized ? 500 : 280);

const Curve expressiveCurve = Easing.emphasizedDecelerate;

abstract final class HarborMotion {
  // Spatial changes can gently overshoot; color/opacity transitions cannot.
  static final spatial = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 500,
    ratio: 0.78,
  );
  static const effectsDuration = Duration(milliseconds: 180);
  static Duration effects(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : effectsDuration;
}
