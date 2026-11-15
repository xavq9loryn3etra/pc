import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';

class AppTheme {
  // Brand Colors
  static const Color primaryColor = Color(0xFFFDEDAD); // Cream Yellow
  static const Color scaffoldColor = Colors.black; // True Black
  static const Color surfaceColor = Color(0xFF181818); // Dark Grey Surface
  static const Color accentColor = Color(
    0xFFB5966E,
  ); // Gold/Bronzish accent from Desktop

  // System bars: transparent status and navigation bars (no Android
  // scrims — contrast enforcement off, so 3-button navigation doesn't get
  // a translucent backdrop either) with light icons, so every screen's
  // content runs edge to edge. Applied app-wide in main.dart; screens can
  // override parts of it with an AnnotatedRegion.
  static const SystemUiOverlayStyle systemUiStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light, // Android
    statusBarBrightness: Brightness.dark, // iOS
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  // Gradients
  static const LinearGradient verticalFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, Colors.black],
    stops: [0.0, 1.0],
  );

  // Computed once and cached — this used to be a `static get` that rebuilt
  // the whole ThemeData (including the GoogleFonts.outfitTextTheme call)
  // every time MaterialApp's theme was read, i.e. on every MyApp rebuild.
  static final ThemeData darkTheme = _buildDarkTheme(primaryColor);

  // Ramen's: the same, in its orange.
  static final ThemeData _ramenTheme = _buildDarkTheme(AppMode.ramenOrange);

  /// The theme for [mode]: Ramen's in its orange, the rest Popcorn's cream.
  static ThemeData themeFor(AppMode mode) =>
      mode == AppMode.anime ? _ramenTheme : darkTheme;

  /// The open mode's accent for what's watched: the player's progress
  /// bar, progress on posters and episodes, the liked heart. Ramen's
  /// orange in Ramen, Popcorn's cream otherwise.
  static Color get accent => AppModeService().currentMode.value == AppMode.anime
      ? AppMode.ramenOrange
      : primaryColor;

  static ThemeData _buildDarkTheme(Color primary) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: scaffoldColor,
      primaryColor: primary,

      // One way of moving between screens everywhere, Apple's: a slide in
      // from the side, and back with a swipe from the left edge. Pages
      // opened with a plain MaterialPageRoute zoomed in, Android-style,
      // while those opened as CupertinoPageRoute slid. Players and the book
      // reader fade instead (see PlayerRoute).
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        },
      ),

      // Color Scheme
      colorScheme: ColorScheme.dark(
        primary: primary,
        secondary: accentColor,
        surface: surfaceColor,
        background: scaffoldColor,
        onSurface: Colors.white,
      ),

      // A white cursor in every text field (Ask, Search, the Gemini key…),
      // with the white send and search buttons; the selection handles keep
      // the accent.
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Colors.white,
      ),

      // Typography
      textTheme: GoogleFonts.outfitTextTheme(
        ThemeData.dark().textTheme.apply(
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
      ),

      // App Bar
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          height: 1.0,
        ).copyWith(leadingDistribution: TextLeadingDistribution.even),
      ),

      // Card
      cardTheme: CardThemeData(
        color: surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),

      // The hand pointer over everything clickable, on a computer too.
      // Flutter's buttons show the plain arrow there by default (as native
      // desktop apps do); the app's own glass buttons and rows ask for it
      // themselves (see clickCursor).
      iconButtonTheme: const IconButtonThemeData(style: _clickable),
      textButtonTheme: const TextButtonThemeData(style: _clickable),
      elevatedButtonTheme: const ElevatedButtonThemeData(style: _clickable),
      filledButtonTheme: const FilledButtonThemeData(style: _clickable),
      outlinedButtonTheme: const OutlinedButtonThemeData(style: _clickable),
      listTileTheme:
          const ListTileThemeData(mouseCursor: WidgetStateMouseCursor.clickable),
    );
  }

  static const ButtonStyle _clickable =
      ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable);
}
