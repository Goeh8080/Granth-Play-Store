import 'package:flutter/material.dart';

/// Exact palette from the original web app (`@layer theme` in index.html).
class GColors {
  GColors._();
  static const saffron = Color(0xFFE8821A);
  static const saffronDark = Color(0xFFC06A10);
  static const maroon = Color(0xFF7B1F2E);
  static const maroonLight = Color(0xFFA0293D);
  static const gold = Color(0xFFC9A84C);
  static const goldLight = Color(0xFFE2C97E);
  static const cream = Color(0xFFFDF6E3);
  static const creamDark = Color(0xFFF5E6C8);
  static const brown = Color(0xFF4A2C0A);
  static const text = Color(0xFF3D1F00);
  static const muted = Color(0xFF8B6A4A);
  static const paper = Color(0xFFFFFDF7);

  // color-mix() results used by the CSS.
  static const syncStrip = Color(0xFFF7EBD3);
  static const pill = Color(0xFFF5EFDF);
  static const pillMaroon = Color(0xFFF2E9EA);
  static const pillTopic = Color(0xFFFCEEDF);
  static const stickyBar = Color(0xFFFDF7E6);
  static const meterTrack = Color(0xFFECE1C0);
  static const lightbox = Color(0xFF3D2408);
  static const online = Color(0xFF2F7D32);

  static Color shadow(double a) => brown.withValues(alpha: a);
}

/// Font stacks: --font-sans, --font-display, --font-script.
class GFonts {
  GFonts._();
  static const sans = 'NotoDeva';
  static const sansFallback = ['DMSans', 'NotoDevaFull'];
  static const display = 'YatraOne';
  static const displayFallback = ['YatraOneLatin', 'NotoDeva', 'NotoDevaFull'];
  static const script = 'TiroDevanagari';
  static const scriptFallback = ['NotoDeva', 'DMSans', 'NotoDevaFull'];
}

class GText {
  GText._();
  static TextStyle sans({double size = 16, FontWeight weight = FontWeight.w400, Color color = GColors.text, double? height, double? letterSpacing}) => TextStyle(
        fontFamily: GFonts.sans,
        fontFamilyFallback: GFonts.sansFallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  static TextStyle display({double size = 22, Color color = GColors.maroon, double? height, double? letterSpacing, List<Shadow>? shadows}) => TextStyle(
        fontFamily: GFonts.display,
        fontFamilyFallback: GFonts.displayFallback,
        fontSize: size,
        fontWeight: FontWeight.w400,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        shadows: shadows,
      );

  static TextStyle script({double size = 18, Color color = GColors.maroon, double height = 1.45}) => TextStyle(
        fontFamily: GFonts.script,
        fontFamilyFallback: GFonts.scriptFallback,
        fontSize: size,
        fontWeight: FontWeight.w400,
        color: color,
        height: height,
      );
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: GColors.maroon, primary: GColors.maroon, surface: GColors.cream),
    scaffoldBackgroundColor: GColors.cream,
    fontFamily: GFonts.sans,
    fontFamilyFallback: GFonts.sansFallback,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: GColors.text, displayColor: GColors.text, fontFamily: GFonts.sans),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: GColors.saffron, selectionHandleColor: GColors.saffron),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
