import 'package:flutter/material.dart';

/// "Paper" — a design built for e-ink first, phones second.
///
/// A large share of readers run this on an e-ink reader (Boox, Bigme, Hisense
/// and the like), so every rule here follows from what that panel can and
/// cannot do:
///
/// - **Two tones, not a palette.** Most panels are 16-level grayscale and the
///   colour ones (Kaleido) are washed out, so state is never carried by hue.
///   Pure ink on pure paper, one muted gray for secondary text, and emphasis
///   by weight, borders and inversion (white on black).
/// - **Nothing moves.** Every frame is a panel refresh, and animation leaves
///   ghosting behind. No page transitions, no ripples, no spinners, no
///   overscroll glow. Busy states are words, not motion.
/// - **No translucency or shadow.** Alpha blends and elevation dither into a
///   muddy gray on e-ink. Surfaces are separated by rules (1.5px lines).
/// - **Big targets.** E-ink touch layers are less precise and slower to
///   respond; controls are at least 52px tall.
class AppTheme {
  static const Color ink = Color(0xFF000000);
  static const Color paper = Color(0xFFFFFFFF);

  /// Secondary text. Dark enough to stay crisp on a 16-level panel — lighter
  /// grays dither and read as noise rather than as "less important".
  static const Color inkMuted = Color(0xFF4A4A4A);

  /// Disabled controls. The only light gray in the system, used where low
  /// contrast is the point.
  static const Color inkFaint = Color(0xFF9E9E9E);

  static const double ruleWidth = 1.5;
  static const double heavyRuleWidth = 2.5;
  static const double radius = 4;
  static const double controlHeight = 52;

  /// Titles use the platform serif (Noto Serif on Android) so the chrome
  /// reads like a book rather than a dashboard, without bundling a font.
  static const String serif = 'serif';

  static const BorderSide rule = BorderSide(color: ink, width: ruleWidth);

  static const TextStyle display = TextStyle(
    fontFamily: serif,
    fontSize: 36,
    fontWeight: FontWeight.w700,
    height: 1.15,
    color: ink,
  );

  static const TextStyle title = TextStyle(
    fontFamily: serif,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: ink,
  );

  /// Small capitals-style label above a section ("MEMBERS", "ROOM CODE").
  static const TextStyle overline = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: ink,
  );

  static const TextStyle body = TextStyle(fontSize: 16, color: ink);

  static const TextStyle caption = TextStyle(fontSize: 14, color: inkMuted);

  static ThemeData get paperTheme {
    const colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: ink,
      onPrimary: paper,
      secondary: ink,
      onSecondary: paper,
      error: ink,
      onError: paper,
      surface: paper,
      onSurface: ink,
      onSurfaceVariant: inkMuted,
      outline: ink,
      outlineVariant: inkMuted,
      surfaceTint: Colors.transparent,
      shadow: Colors.transparent,
      inverseSurface: ink,
      onInverseSurface: paper,
    );

    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
    );
    const buttonText = TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    const minimumSize = Size(64, controlHeight);
    const padding = EdgeInsets.symmetric(horizontal: 24);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: paper,
      canvasColor: paper,
      dividerColor: ink,
      // Ripples and hover washes are animations; on e-ink they are smears.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      // Route changes snap instead of sliding or zooming.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _NoTransitionsBuilder(),
          TargetPlatform.iOS: _NoTransitionsBuilder(),
          TargetPlatform.linux: _NoTransitionsBuilder(),
          TargetPlatform.macOS: _NoTransitionsBuilder(),
          TargetPlatform.windows: _NoTransitionsBuilder(),
          TargetPlatform.fuchsia: _NoTransitionsBuilder(),
        },
      ),
      textTheme: const TextTheme(
        displaySmall: display,
        titleLarge: title,
        titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        bodyLarge: body,
        bodyMedium: TextStyle(fontSize: 15),
        labelLarge: buttonText,
      ).apply(bodyColor: ink, displayColor: ink),
      iconTheme: const IconThemeData(color: ink, size: 24),
      dividerTheme: const DividerThemeData(
        color: ink,
        thickness: ruleWidth,
        space: ruleWidth,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: title,
        shape: Border(bottom: rule),
      ),
      cardTheme: const CardThemeData(
        color: paper,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: rule,
          borderRadius: BorderRadius.all(Radius.circular(radius)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          elevation: const WidgetStatePropertyAll(0),
          minimumSize: const WidgetStatePropertyAll(minimumSize),
          padding: const WidgetStatePropertyAll(padding),
          shape: const WidgetStatePropertyAll(shape),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          // Disabled keeps the outline so the control stays findable; it
          // only loses its fill.
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? paper : ink,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? inkFaint : paper,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.disabled) ? inkFaint : ink,
              width: ruleWidth,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(minimumSize),
          padding: const WidgetStatePropertyAll(padding),
          shape: const WidgetStatePropertyAll(shape),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: const WidgetStatePropertyAll(paper),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? inkFaint : ink,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.disabled) ? inkFaint : ink,
              width: ruleWidth,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
            ),
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? inkFaint : ink,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(52, 52)),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? inkFaint : ink,
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: paper,
        labelStyle: TextStyle(color: ink, fontWeight: FontWeight.w700),
        floatingLabelStyle: TextStyle(color: ink, fontWeight: FontWeight.w700),
        hintStyle: TextStyle(color: inkMuted),
        prefixIconColor: ink,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
          borderSide: rule,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
          borderSide: rule,
        ),
        // Focus is a heavier line, not a colour change.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
          borderSide: BorderSide(color: ink, width: heavyRuleWidth),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
          borderSide: BorderSide(color: ink, width: heavyRuleWidth),
        ),
        errorStyle: TextStyle(color: ink, fontWeight: FontWeight.w700),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: ink,
        selectionColor: Color(0xFFD0D0D0),
        selectionHandleColor: ink,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: TextStyle(
          color: paper,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        actionTextColor: paper,
        elevation: 0,
        behavior: SnackBarBehavior.fixed,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        modalBarrierColor: Color(0x00000000),
        showDragHandle: false,
        shape: Border(top: BorderSide(color: ink, width: heavyRuleWidth)),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: ink, width: heavyRuleWidth),
          borderRadius: BorderRadius.all(Radius.circular(radius)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ink,
        linearTrackColor: paper,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? paper : ink,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? ink : paper,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(ink),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    );
  }
}

/// Routes appear in a single frame: one panel refresh instead of a dozen.
class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

/// Clamps scrolling and drops the overscroll glow/stretch, both of which keep
/// the panel refreshing after the finger has lifted.
class PaperScrollBehavior extends MaterialScrollBehavior {
  const PaperScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }
}
