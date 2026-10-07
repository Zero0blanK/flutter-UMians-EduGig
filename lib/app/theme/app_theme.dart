import 'package:flutter/material.dart';

/// Red Lily uses five base colors. Surface and dark-mode tones are derived
/// from these anchors; feature screens consume semantic ColorScheme roles.
class AppTheme {
  const AppTheme._();

  static const radiusCard = 20.0;
  static const radiusPanel = 28.0;
  static const radiusControl = 16.0;

  static const crimson = Color(0xFFB4123B);
  static const slate = Color(0xFF20262E);
  static const white = Color(0xFFFFFFFF);
  static const green = Color(0xFF2F6B4F);
  static const amber = Color(0xFF8A5A00);

  static ThemeData light() => _base(_scheme(Brightness.light));
  static ThemeData dark() => _base(_scheme(Brightness.dark));

  // A single neutral ramp keeps surfaces free of decorative brand tint.
  static Color _neutral(double lightness) =>
      Color.lerp(slate, white, lightness)!;

  static Color categoryTint(Brightness brightness) =>
      _neutral(brightness == Brightness.dark ? 0.72 : 0.28);

  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    Color accent(Color base) => dark ? Color.lerp(base, white, 0.60)! : base;
    Color container(Color base) =>
        Color.lerp(base, dark ? slate : white, dark ? 0.78 : 0.92)!;
    return ColorScheme(
      brightness: brightness,
      primary: accent(crimson),
      onPrimary: dark ? slate : white,
      primaryContainer: container(crimson),
      onPrimaryContainer: dark ? white : crimson,
      secondary: accent(green),
      onSecondary: dark ? slate : white,
      secondaryContainer: container(green),
      onSecondaryContainer: dark ? white : green,
      tertiary: accent(amber),
      onTertiary: dark ? slate : white,
      tertiaryContainer: container(amber),
      onTertiaryContainer: dark ? white : amber,
      error: accent(crimson),
      onError: dark ? slate : white,
      errorContainer: container(crimson),
      onErrorContainer: dark ? white : crimson,
      surface: dark ? slate : _neutral(0.97),
      onSurface: dark ? _neutral(0.94) : slate,
      onSurfaceVariant: categoryTint(brightness),
      surfaceContainerLowest: dark ? slate : white,
      surfaceContainerLow: _neutral(dark ? 0.025 : 0.99),
      surfaceContainer: _neutral(dark ? 0.05 : 0.95),
      surfaceContainerHigh: _neutral(dark ? 0.08 : 0.92),
      surfaceContainerHighest: _neutral(dark ? 0.12 : 0.88),
      outline: _neutral(dark ? 0.52 : 0.40),
      outlineVariant: _neutral(dark ? 0.20 : 0.82),
      shadow: slate,
      scrim: slate,
      inverseSurface: dark ? _neutral(0.94) : slate,
      onInverseSurface: dark ? slate : white,
      inversePrimary: dark ? crimson : Color.lerp(crimson, white, 0.60)!,
      surfaceTint: Colors.transparent,
    );
  }

  static ThemeData _base(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final text = _textTheme(scheme);

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusCard),
      side: dark ? BorderSide(color: scheme.outlineVariant) : BorderSide.none,
    );
    const pill = StadiumBorder();

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      splashColor: scheme.primary.withValues(alpha: 0.12),
      highlightColor: scheme.primary.withValues(alpha: 0.06),
      hoverColor: scheme.primary.withValues(alpha: 0.04),
      fontFamily: _body,
      splashFactory: InkSparkle.splashFactory,
      textTheme: text,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: dark ? 0 : 3,
        shadowColor: scheme.shadow.withValues(alpha: dark ? 0 : 0.08),
        clipBehavior: Clip.antiAlias,
        color: dark ? scheme.surfaceContainer : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: cardShape,
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: dark
            ? scheme.surfaceContainer
            : scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        helperStyle: text.bodySmall,
        border: _inputBorder(scheme.outlineVariant),
        enabledBorder: _inputBorder(scheme.outlineVariant),
        focusedBorder: _inputBorder(scheme.primary, width: 1.8),
        errorBorder: _inputBorder(scheme.error),
        focusedErrorBorder: _inputBorder(scheme.error, width: 1.8),
      ),
      // Buttons are pills. The filled one is the single red action on a
      // screen; tonal and outlined ones are the quiet company it keeps.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          elevation: 0,
          shape: pill,
          textStyle: const TextStyle(
            fontFamily: _body,
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: 0,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 50),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: pill,
          side: BorderSide(color: scheme.outlineVariant, width: 1.4),
          foregroundColor: scheme.onSurface,
          textStyle: const TextStyle(
            fontFamily: _body,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: pill,
          textStyle: const TextStyle(
            fontFamily: _body,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
      ),
      chipTheme: ChipThemeData(
        labelStyle: TextStyle(
          fontFamily: _body,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: TextStyle(
          fontFamily: _body,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimaryContainer,
        ),
        backgroundColor: dark
            ? scheme.surfaceContainer
            : scheme.surfaceContainerLowest,
        selectedColor: scheme.primaryContainer,
        checkmarkColor: scheme.onPrimaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: pill,
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 76,
        backgroundColor: dark
            ? scheme.surfaceContainerLow
            : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: pill,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: _body,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark
            ? scheme.surfaceContainerLow
            : scheme.surfaceContainerLowest,
        indicatorColor: scheme.primaryContainer,
        indicatorShape: pill,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          fontFamily: _body,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: _body,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
        labelType: NavigationRailLabelType.all,
        useIndicator: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          fontFamily: _body,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusControl),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 32,
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.titleSmall,
        subtitleTextStyle: text.bodySmall,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: dark
              ? scheme.surfaceContainer
              : scheme.surfaceContainerLowest,
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
          foregroundColor: scheme.onSurfaceVariant,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(
            fontFamily: _body,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
          shape: pill,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 3,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: pill,
        extendedTextStyle: const TextStyle(
          fontFamily: _body,
          fontWeight: FontWeight.w700,
          fontSize: 14.5,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.titleLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusPanel),
        ),
        barrierColor: scheme.scrim.withValues(alpha: 0.55),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(radiusPanel),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant,
      ),
      tabBarTheme: TabBarThemeData(
        labelStyle: const TextStyle(
          fontFamily: _body,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: _body,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: scheme.outlineVariant,
        indicatorSize: TabBarIndicatorSize.label,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusControl),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  // ---------------------------------------------------------------------
  // Type
  // ---------------------------------------------------------------------

  /// Headlines. Bricolage Grotesque: slightly narrow, cut terminals, enough
  /// personality to keep a student marketplace from reading as a bank.
  static const _display = 'Bricolage';

  /// Everything read at size. Plus Jakarta Sans: tall x-height, open
  /// counters, comfortable at 12–14px on a phone.
  static const _body = 'Jakarta';

  static TextTheme _textTheme(ColorScheme scheme) {
    final ink = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    return TextTheme(
      displaySmall: TextStyle(
        fontFamily: _display,
        fontSize: 38,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        height: 1.05,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: _display,
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.9,
        height: 1.1,
        color: ink,
      ),
      headlineSmall: TextStyle(
        fontFamily: _display,
        fontSize: 25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.15,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontFamily: _display,
        fontSize: 21,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        height: 1.2,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontFamily: _body,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.15,
        height: 1.3,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontFamily: _body,
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: ink,
      ),
      bodyLarge: TextStyle(
        fontFamily: _body,
        fontSize: 15.5,
        height: 1.5,
        color: ink,
      ),
      bodyMedium: TextStyle(
        fontFamily: _body,
        fontSize: 14,
        height: 1.5,
        color: ink,
      ),
      bodySmall: TextStyle(
        fontFamily: _body,
        fontSize: 12.5,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
      labelLarge: TextStyle(
        fontFamily: _body,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      labelMedium: TextStyle(
        fontFamily: _body,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: muted,
      ),
      labelSmall: TextStyle(
        fontFamily: _body,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: muted,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Brand accents that are not colour-scheme roles
  // ---------------------------------------------------------------------

  /// Neutral tabular prices keep green reserved for financial success.
  static TextStyle price(BuildContext context, {double size = 19}) {
    final scheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontFamily: _body,
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      height: 1.1,
      color: scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// Ratings share the amber semantic accent.
  static Color rating(BuildContext context) =>
      Theme.of(context).colorScheme.tertiary;

  /// A solid brand header preserves the existing hero API and white text.
  static LinearGradient hero(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? Color.lerp(crimson, slate, 0.45)! : crimson;
    return LinearGradient(colors: [color, color]);
  }

  /// A neutral shadow for surfaces that float (action bars, sheets).
  static List<BoxShadow> lift(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark) return const [];
    return [
      BoxShadow(
        color: slate.withValues(alpha: 0.10),
        blurRadius: 24,
        offset: const Offset(0, -6),
      ),
    ];
  }
}
