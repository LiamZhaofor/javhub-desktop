import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'motion.dart';
import 'platform.dart';

const accent = Color(0xFFE5484D);

/// The palette both themes are built from: Apple's system greys, one red accent (the web
/// UI's tokens, app.css :root).
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.sidebar,
    required this.fill,
    required this.fill2,
    required this.hair,
    required this.segOn,
    required this.cardShadow,
    required this.liftShadow,
  });

  final Color bg;
  final Color surface;
  final Color raised;
  final Color line;
  final Color text;
  final Color muted;
  final Color sidebar;

  /// A borderless button's / a tag's grey (and, hovered, a little more of it).
  final Color fill;
  final Color fill2;

  /// The faint edge round a card or a poster.
  final Color hair;

  /// The chosen segment of a pill group.
  final Color segOn;

  /// A poster at rest, and lifted under the pointer (same number of shadows: they animate).
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> liftShadow;

  static const dark = Palette(
    bg: Color(0xFF0A0A0C),
    surface: Color(0xFF1C1C1E),
    raised: Color(0xFF2C2C2E),
    line: Color(0xFF2E2E32),
    text: Color(0xFFF5F5F7),
    muted: Color(0xFF98989F),
    sidebar: Color(0xFF111113),
    fill: Color(0x3D787880),
    fill2: Color(0x57787880),
    hair: Color(0x12FFFFFF),
    segOn: Color(0xFF48484C),
    cardShadow: [
      BoxShadow(color: Color(0x73000000), blurRadius: 8, offset: Offset(0, 2)),
      BoxShadow(color: Color(0x00000000), blurRadius: 10, offset: Offset(0, 4)),
    ],
    liftShadow: [
      BoxShadow(color: Color(0x99000000), blurRadius: 36, offset: Offset(0, 16)),
      BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 4)),
    ],
  );

  static const light = Palette(
    bg: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFE9E9EE),
    line: Color(0xFFE1E1E6),
    text: Color(0xFF111113),
    muted: Color(0xFF6C6C74),
    // a shade under the page, so the chosen (white) item stands out of it
    sidebar: Color(0xFFE8E8ED),
    fill: Color(0x1F787880),
    fill2: Color(0x33787880),
    hair: Color(0x0F000000),
    segOn: Color(0xFFFFFFFF),
    cardShadow: [
      BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 6)),
    ],
    liftShadow: [
      BoxShadow(color: Color(0x2E000000), blurRadius: 30, offset: Offset(0, 14)),
      BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 4)),
    ],
  );

  static Palette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// A page comes in by fading and rising a little out of a slightly smaller size; the page
/// under it settles back. (Material's default slides the whole page on Android and does
/// nothing much on the desktop.)
class SmoothPageTransitions extends PageTransitionsBuilder {
  const SmoothPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 380);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final inA = CurvedAnimation(parent: animation, curve: Motion.standard, reverseCurve: Motion.exit);
    final outA = CurvedAnimation(parent: secondaryAnimation, curve: Motion.standard, reverseCurve: Motion.exit);
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.55).animate(outA),
      child: ScaleTransition(
        scale: Tween(begin: 1.0, end: 0.965).animate(outA),
        child: FadeTransition(
          opacity: inA,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.035), end: Offset.zero).animate(inA),
            child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(inA), child: child),
          ),
        ),
      ),
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: Colors.white,
    primaryContainer: accent.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.12),
    onPrimaryContainer: brightness == Brightness.dark ? const Color(0xFFFFB3B5) : const Color(0xFFB4232A),
    secondary: const Color(0xFF3B82F6),
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFF3B82F6).withValues(alpha: 0.15),
    onSecondaryContainer: brightness == Brightness.dark ? const Color(0xFFBFD7FF) : const Color(0xFF1D4ED8),
    error: const Color(0xFFE5484D),
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: p.raised,
    outline: p.line,
    outlineVariant: p.line,
  );
  final radius = BorderRadius.circular(10);
  return ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      // the phone: the new page slides over from the right, the one under it drifts left and
      // dims; a swipe from the left edge takes it back, following the finger
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: SmoothPageTransitions(),
      TargetPlatform.linux: SmoothPageTransitions(),
      TargetPlatform.macOS: SmoothPageTransitions(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    // Windows: YaHei; Android: the system font (YaHei is not there, and the fallback
    // landed on a serif)
    // Android: the system's own sans-serif (OEMs replace Roboto - ColorOS has no Roboto,
    // and Flutter asking for it fell back to a serif)
    // Linux: the desktop's own sans (fontconfig picks Noto Sans CJK SC for the Han on Fedora)
    fontFamily: Platform.isWindows ? 'Microsoft YaHei UI' : Platform.isLinux ? null : 'sans-serif',
    fontFamilyFallback: Platform.isWindows
        ? const ['Microsoft YaHei', 'Segoe UI', 'PingFang SC']
        : Platform.isLinux
        ? const ['Noto Sans CJK SC', 'Noto Sans SC', 'Source Han Sans SC', 'WenQuanYi Micro Hei']
        : null,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    hintColor: p.muted,
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.hair)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: p.text,
      titleTextStyle: TextStyle(color: p.text, fontSize: 17, fontWeight: FontWeight.w700),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.raised,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.line)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: const BorderSide(color: accent, width: 1.4)),
    ),
    // tags and filters: grey pills, no outline (a chosen one takes the accent's tint)
    chipTheme: ChipThemeData(
      backgroundColor: p.fill,
      selectedColor: accent.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.12),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: p.text, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: brightness == Brightness.dark ? const Color(0xFFFFB3B5) : const Color(0xFFB4232A), fontSize: 13),
      checkmarkColor: accent,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    // the secondary buttons: a grey fill, no outline (the web's .btn)
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        backgroundColor: p.fill,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    // a grey track, the chosen segment raised out of it (the web's pill nav)
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: p.fill, width: 0.5),
        backgroundColor: p.fill,
        foregroundColor: p.muted,
        selectedBackgroundColor: p.segOn,
        selectedForegroundColor: p.text,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.surface),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: p.line))),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: p.line)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: radius),
      width: 420,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: const Color(0xEE1C1C1E), borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : p.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : p.raised),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : p.line),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.muted.withValues(alpha: 0.35)),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
  );
}

/// Light / dark / follow Windows, remembered.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.system);

  static final instance = ThemeController();
  static const _key = 'ui.theme';

  Future<void> restore() async {
    final v = (await SharedPreferences.getInstance()).getString(_key);
    value = ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    value = mode;
    await (await SharedPreferences.getInstance()).setString(_key, mode.name);
  }

  /// The sidebar button: system -> light -> dark -> system.
  Future<void> cycle() => set(switch (value) {
    ThemeMode.system => ThemeMode.light,
    ThemeMode.light => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.system,
  });
}

/// A page's title row: big title, a quiet subtitle, actions on the right.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.actions = const [], this.trailing});

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (isCompact(context)) {
      // a phone: title (and subtitle) on top, the actions below at full width
      return Padding(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text(title, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: p.text, letterSpacing: -0.4)),
            if (trailing != null) trailing!,
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: TextStyle(color: p.muted, fontSize: 12.5), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                // a width-limited action (the search box) takes the rest of the row
                actions[i] is SizedBox && (actions[i] as SizedBox).width != null && (actions[i] as SizedBox).width! > 100
                    ? Expanded(child: (actions[i] as SizedBox).child ?? const SizedBox())
                    : actions[i],
              ],
            ]),
          ],
        ]),
      );
    }
    return Padding(
      // (+ the custom title bar's band on Windows)
      padding: EdgeInsets.fromLTRB(28, 24 + MediaQuery.paddingOf(context).top, 28, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(title, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: p.text, letterSpacing: -0.5)),
          if (subtitle != null) ...[
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle!, style: TextStyle(color: p.muted, fontSize: 13)),
            ),
          ],
          if (trailing != null) trailing!,
          const Spacer(),
          for (final a in actions) ...[const SizedBox(width: 8), a],
        ],
      ),
    );
  }
}
