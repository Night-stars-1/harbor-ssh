import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

/// How surfaces that sit directly on the window are painted. With window
/// acrylic the system backdrop shows through the window chrome, and content
/// sheets keep a translucent tint so text stays legible. [frosted] floating
/// surfaces (menus, dialogs, sheets) are translucent and blur the app content
/// below them; it is independent of window acrylic.
@immutable
class HarborWindowBackdrop extends ThemeExtension<HarborWindowBackdrop> {
  const HarborWindowBackdrop({
    this.acrylic = false,
    this.frosted = false,
    this.sheetOpacity = 1,
  });
  final bool acrylic;
  final bool frosted;
  final double sheetOpacity;

  /// Title bar, side panels and page backgrounds.
  Color chrome(Color color) => acrylic ? Colors.transparent : color;

  /// Content sheets laid on the window backdrop.
  Color sheet(Color color) =>
      acrylic ? color.withValues(alpha: sheetOpacity) : color;

  /// Floating surfaces painted over a [HarborSurfaceBlur]. The blur already
  /// flattens the backdrop's contrast, so a light tint keeps text legible; an
  /// opaque fill would hide the blur entirely. Without frosting they are fully
  /// opaque, even when window acrylic made the scheme role translucent.
  Color floating(Color color) => color.withValues(alpha: frosted ? .5 : 1);

  @override
  HarborWindowBackdrop copyWith({
    bool? acrylic,
    bool? frosted,
    double? sheetOpacity,
  }) => HarborWindowBackdrop(
    acrylic: acrylic ?? this.acrylic,
    frosted: frosted ?? this.frosted,
    sheetOpacity: sheetOpacity ?? this.sheetOpacity,
  );

  @override
  HarborWindowBackdrop lerp(HarborWindowBackdrop? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

extension HarborWindowTheme on ThemeData {
  HarborWindowBackdrop get windowBackdrop =>
      extension<HarborWindowBackdrop>() ?? const HarborWindowBackdrop();
}

ThemeData harborTheme({
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  AppThemeColor color = AppThemeColor.defaultColor,
  ColorScheme? dynamicScheme,
  bool acrylic = false,
  bool frosted = false,
}) {
  final opaque = color == AppThemeColor.dynamic && dynamicScheme != null
      ? dynamicScheme
      : harborColorScheme(brightness: brightness, color: color);
  final backdrop = HarborWindowBackdrop(
    acrylic: acrylic,
    frosted: frosted,
    sheetOpacity: brightness == Brightness.dark ? .5 : .6,
  );
  final floating = backdrop.floating(opaque.surfaceContainerHigh);
  // Surface roles also reach custom panels, editor popups and nested cards.
  // Keep foreground/ANSI/accent roles opaque: transparency belongs to the
  // background, never the text or the entire widget subtree.
  final colors = acrylic
      ? opaque.copyWith(
          surface: backdrop.sheet(opaque.surface),
          surfaceDim: backdrop.sheet(opaque.surfaceDim),
          surfaceBright: backdrop.sheet(opaque.surfaceBright),
          surfaceContainerLowest: backdrop.sheet(opaque.surfaceContainerLowest),
          surfaceContainerLow: backdrop.sheet(opaque.surfaceContainerLow),
          surfaceContainer: backdrop.sheet(opaque.surfaceContainer),
          surfaceContainerHigh: opaque.surfaceContainerHigh.withValues(
            alpha: .72,
          ),
          surfaceContainerHighest: opaque.surfaceContainerHighest.withValues(
            alpha: .8,
          ),
          inverseSurface: opaque.inverseSurface.withValues(alpha: .9),
        )
      : opaque;
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
    extensions: [backdrop],
    scaffoldBackgroundColor: backdrop.chrome(colors.surfaceContainerLow),
    // Pushed pages share the M3 fade-forward motion on every platform.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: FadeForwardsPageTransitionsBuilder(
            backgroundColor: backdrop.chrome(colors.surface),
          ),
      },
    ),
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
      backgroundColor: backdrop.chrome(colors.surface),
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
      backgroundColor: backdrop.chrome(colors.surfaceContainer),
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
      backgroundColor: floating,
      surfaceTintColor: backdrop.frosted ? Colors.transparent : null,
      shape: HarborShapes.superellipse(HarborShapes.dialog),
    ),
    // Under window acrylic the default sheet colour is a translucent scheme
    // role, so sheets need the explicit floating fill either way.
    bottomSheetTheme: acrylic || backdrop.frosted
        ? BottomSheetThemeData(
            backgroundColor: floating,
            modalBackgroundColor: floating,
            surfaceTintColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
          )
        : null,
    tooltipTheme: acrylic
        ? TooltipThemeData(
            decoration: ShapeDecoration(
              color: colors.inverseSurface.withValues(alpha: frosted ? .9 : 1),
              shape: HarborShapes.superellipse(BorderRadius.circular(8)),
            ),
            textStyle: base.textTheme.bodySmall?.copyWith(
              color: colors.onInverseSurface,
            ),
          )
        : null,
    popupMenuTheme: PopupMenuThemeData(
      color: floating,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: HarborShapes.superellipse(HarborShapes.tile),
      menuPadding: const EdgeInsets.all(8),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(floating),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          HarborShapes.superellipse(HarborShapes.tile),
        ),
        elevation: const WidgetStatePropertyAll(2),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
    ),
    dropdownMenuTheme: frosted
        ? const DropdownMenuThemeData(
            // Replaces DropdownMenu's default style, so keep its sizing.
            menuStyle: MenuStyle(
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
              minimumSize: WidgetStatePropertyAll(Size(112, 0)),
              maximumSize: WidgetStatePropertyAll(Size.infinite),
              visualDensity: VisualDensity.standard,
            ),
          )
        : null,
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          HarborShapes.superellipse(const BorderRadius.all(HarborShapes.sm)),
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)) {
            return Color.alphaBlend(
              colors.primary.withValues(alpha: .12),
              floating,
            );
          }
          return null;
        }),
      ),
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

/// Blurs the already painted background up to the nearest ancestor clip.
/// Floating surfaces must clip their Material to its outline, not this child:
/// that lets a zero-height first menu entry frost the whole menu (including
/// its padding) once, before any text or hover highlight is painted.
class HarborSurfaceBlur extends StatelessWidget {
  const HarborSurfaceBlur({super.key, this.child = const SizedBox.shrink()});
  final Widget child;

  static final _light = _material(target: .9);
  static final _dark = _material(target: .14);

  /// Acrylic-style material: a wide blur removes text-sized detail, then the
  /// colours are re-saturated and their luminance pulled toward [target], so
  /// whatever lies below reads as one even surface rather than a grey smear.
  static ui.ImageFilter _material({required double target}) {
    const saturation = 1.6, contrast = .55;
    const lr = .2126, lg = .7152, lb = .0722;
    const s = saturation, k = contrast;
    final o = (1 - k) * target * 255;
    List<double> row(double r, double g, double b) => [
      r * k,
      g * k,
      b * k,
      0,
      o,
    ];
    return ui.ImageFilter.compose(
      outer: ui.ColorFilter.matrix([
        ...row(lr * (1 - s) + s, lg * (1 - s), lb * (1 - s)),
        ...row(lr * (1 - s), lg * (1 - s) + s, lb * (1 - s)),
        ...row(lr * (1 - s), lg * (1 - s), lb * (1 - s) + s),
        0,
        0,
        0,
        1,
        0,
      ]),
      inner: ui.ImageFilter.blur(
        sigmaX: 30,
        sigmaY: 30,
        tileMode: TileMode.mirror,
      ),
    );
  }

  /// The backdrop filter for [context]'s theme, or null without frosting.
  static ui.ImageFilter? filterOf(BuildContext context) {
    final theme = Theme.of(context);
    if (!theme.windowBackdrop.frosted) return null;
    return theme.brightness == Brightness.dark ? _dark : _light;
  }

  /// Replaces rather than covers the backdrop inside the clip. With window
  /// acrylic the app paints over transparent pixels, so the blurred copy is
  /// itself translucent; source-over would leave the sharp original showing
  /// through it. Where the backdrop is opaque both modes paint the same.
  static const blendMode = BlendMode.src;

  @override
  Widget build(BuildContext context) {
    final filter = filterOf(context);
    return filter == null
        ? child
        : BackdropFilter(filter: filter, blendMode: blendMode, child: child);
  }
}

/// Frosts the first shaped [Material] below it, for dialog and bottom sheet
/// routes. Those widgets build their Material internally, so a blur cannot sit
/// inside it; this paints one clipped to the surface outline (following route
/// transforms) and then the route on top, leaving the scrim around it sharp.
class HarborFrostedRoute extends SingleChildRenderObjectWidget {
  const HarborFrostedRoute({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFrostedRoute(HarborSurfaceBlur.filterOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderFrostedRoute).filter = HarborSurfaceBlur.filterOf(
        context,
      );
}

class _RenderFrostedRoute extends RenderProxyBox {
  _RenderFrostedRoute(this._filter);
  ui.ImageFilter? _filter;
  set filter(ui.ImageFilter? value) {
    if (value == _filter) return;
    final compositing = (value == null) != (_filter == null);
    _filter = value;
    _blur.layer?.filter = value;
    if (compositing) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipPathLayer>();
  final _blur = LayerHandle<BackdropFilterLayer>();

  @override
  bool get alwaysNeedsCompositing => _filter != null && child != null;

  static RenderPhysicalShape? _surface(RenderObject? node) {
    if (node is RenderPhysicalShape) return node;
    RenderPhysicalShape? found;
    node?.visitChildren((child) => found ??= _surface(child));
    return found;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final filter = _filter;
    final surface = filter != null ? _surface(child) : null;
    final outline = surface != null && surface.hasSize
        ? surface.clipper?.getClip(surface.size)
        : null;
    if (outline == null) {
      _clip.layer = null;
      _blur.layer = null;
    } else {
      final path = outline.transform(surface!.getTransformTo(this).storage);
      _clip.layer = context.pushClipPath(
        true,
        offset,
        path.getBounds(),
        path,
        (context, offset) => context.pushLayer(
          _blur.layer ??= BackdropFilterLayer(
            filter: filter,
            blendMode: HarborSurfaceBlur.blendMode,
          ),
          (_, _) {},
          offset,
        ),
        oldLayer: _clip.layer,
      );
    }
    super.paint(context, offset);
  }

  @override
  void dispose() {
    _clip.layer = null;
    _blur.layer = null;
    super.dispose();
  }
}

/// Non-interactive first entry for legacy popup menus. Height zero preserves
/// keyboard navigation, selected-item positioning and all action hit targets.
class HarborPopupMenuBackdrop<T> extends PopupMenuEntry<T> {
  const HarborPopupMenuBackdrop({super.key});

  @override
  double get height => 0;
  @override
  bool represents(T? value) => false;
  @override
  State<HarborPopupMenuBackdrop<T>> createState() =>
      _HarborPopupMenuBackdropState<T>();
}

class _HarborPopupMenuBackdropState<T>
    extends State<HarborPopupMenuBackdrop<T>> {
  @override
  Widget build(BuildContext context) => const HarborSurfaceBlur();
}

/// DropdownMenu owns its MenuAnchor. Use each button's public backgroundBuilder
/// so filtering or scrolling out the first entry cannot remove the blur. Row
/// clips never overlap; one shared backdrop key samples before any row text.
/// The button Material paints its fill before the builder, so the shared
/// sample would capture (and smear) a highlighted row: row fills are painted
/// above the blur instead, resolved the way DropdownMenu would.
///
/// A blur inside the menu's scroll view never reaches the panel padding, which
/// would show as an unfrosted frame. Frosted themes zero that padding
/// ([harborTheme]'s dropdownMenuTheme) and each row carries the inset instead.
List<DropdownMenuEntry<T>> harborDropdownEntries<T>(
  BuildContext context,
  List<DropdownMenuEntry<T>> entries,
) {
  final filter = HarborSurfaceBlur.filterOf(context);
  if (filter == null || entries.isEmpty) {
    return entries;
  }
  final key = BackdropKey();
  final themeStyle = MenuButtonTheme.of(context).style;
  final focusedFill = Theme.of(context).colorScheme.onSurface
      .withValues(alpha: .12);
  return [
    for (final entry in entries)
      DropdownMenuEntry<T>(
        value: entry.value,
        label: entry.label,
        labelWidget: entry.labelWidget,
        leadingIcon: entry.leadingIcon,
        trailingIcon: entry.trailingIcon,
        enabled: entry.enabled,
        style: (entry.style ?? const ButtonStyle()).copyWith(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundBuilder: (context, states, child) {
            final fill =
                (entry.style?.backgroundColor ?? themeStyle?.backgroundColor)
                    ?.resolve(states) ??
                (states.contains(WidgetState.focused) ? focusedFill : null);
            final shape = (entry.style?.shape ?? themeStyle?.shape)?.resolve(
              states,
            );
            final content =
                entry.style?.backgroundBuilder?.call(context, states, child) ??
                child!;
            return ClipRect(
              child: BackdropFilter(
                filter: filter,
                blendMode: HarborSurfaceBlur.blendMode,
                backdropGroupKey: key,
                child: Padding(
                  padding: _frostedMenuRowInset,
                  child: fill == null
                      ? content
                      : DecoratedBox(
                          decoration: ShapeDecoration(
                            color: fill,
                            shape: shape ?? const RoundedRectangleBorder(),
                          ),
                          child: content,
                        ),
                ),
              ),
            );
          },
        ),
      ),
  ];
}

/// Panel padding moved onto frosted dropdown rows: the same horizontal inset
/// as [MenuThemeData] and the 2px row gap of [HarborPopupMenuItem].
const _frostedMenuRowInset = EdgeInsets.symmetric(horizontal: 8, vertical: 2);

/// A popup item with the same inset, rounded hover and focus treatment as
/// [MenuItemButton]. Keep popup and anchored menus visually consistent.
class HarborPopupMenuItem<T> extends PopupMenuItem<T> {
  const HarborPopupMenuItem({
    super.key,
    super.value,
    required super.child,
    super.enabled,
    super.onTap,
    super.padding,
    super.height = 44,
  });

  @override
  PopupMenuItemState<T, HarborPopupMenuItem<T>> createState() =>
      _HarborPopupMenuItemState<T>();
}

class _HarborPopupMenuItemState<T>
    extends PopupMenuItemState<T, HarborPopupMenuItem<T>> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final highlighted = widget.enabled && (_hovered || _focused);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        skipTraversal: true,
        onFocusChange: (value) => setState(() => _focused = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Material(
            color: highlighted
                ? Color.alphaBlend(
                    colors.primary.withValues(alpha: .12),
                    theme.windowBackdrop.floating(colors.surfaceContainerHigh),
                  )
                : Colors.transparent,
            shape: HarborShapes.superellipse(
              const BorderRadius.all(HarborShapes.sm),
            ),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: theme.copyWith(
                hoverColor: Colors.transparent,
                focusColor: Colors.transparent,
              ),
              child: Builder(
                builder: (innerContext) => super.build(innerContext),
              ),
            ),
          ),
        ),
      ),
    );
  }
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

  /// Popup menus open almost instantly; Flutter's 300 ms default feels laggy.
  static AnimationStyle popup(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 120),
          reverseDuration: Duration(milliseconds: 80),
        );
}
