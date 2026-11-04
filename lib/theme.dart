import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const accent = Color(0xFFE5484D);

/// The palette both themes are built from: neutral greys, one red accent.
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.sidebar,
  });

  final Color bg;
  final Color surface;
  final Color raised;
  final Color line;
  final Color text;
  final Color muted;
  final Color sidebar;

  static const dark = Palette(
    bg: Color(0xFF0C0D10),
    surface: Color(0xFF15171C),
    raised: Color(0xFF1D2027),
    line: Color(0xFF2A2E37),
    text: Color(0xFFECEEF2),
    muted: Color(0xFF8D94A1),
    sidebar: Color(0xFF111317),
  );

  static const light = Palette(
    bg: Color(0xFFF4F5F7),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFF0F1F4),
    line: Color(0xFFE2E4E9),
    text: Color(0xFF15171C),
    muted: Color(0xFF69707D),
    sidebar: Color(0xFFFFFFFF),
  );

  static Palette of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
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
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    fontFamily: 'Microsoft YaHei UI',
    fontFamilyFallback: const ['Microsoft YaHei', 'Segoe UI', 'PingFang SC'],
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    hintColor: p.muted,
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
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
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      selectedColor: accent.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.12),
      side: BorderSide(color: p.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.line),
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
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: p.line),
        selectedBackgroundColor: accent.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.12),
        selectedForegroundColor: brightness == Brightness.dark ? const Color(0xFFFFB3B5) : const Color(0xFFB4232A),
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
      backgroundColor: brightness == Brightness.dark ? const Color(0xFF2A2E37) : const Color(0xFF1D2027),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: radius),
      width: 420,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: const Color(0xEE1D2027), borderRadius: BorderRadius.circular(6)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(title, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: p.text, letterSpacing: 0.2)),
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
