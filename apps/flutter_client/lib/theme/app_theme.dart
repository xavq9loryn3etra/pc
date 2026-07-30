import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Brand Colors
  static const Color primaryColor = Color(0xFFFDEDAD); // Cream Yellow
  static const Color scaffoldColor = Colors.black; // True Black
  static const Color surfaceColor = Color(0xFF181818); // Dark Grey Surface
  static const Color accentColor = Color(
    0xFFB5966E,
  ); // Gold/Bronzish accent from Desktop

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
  static final ThemeData darkTheme = _buildDarkTheme();

  static ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: scaffoldColor,
      primaryColor: primaryColor,

      // Color Scheme
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        secondary: accentColor,
        surface: surfaceColor,
        background: scaffoldColor,
        onSurface: Colors.white,
      ),

      // Typography
      textTheme: GoogleFonts.outfitTextTheme(
        ThemeData.dark().textTheme.apply(
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
      ),

      // App Bar
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),

      // Card
      cardTheme: CardThemeData(
        color: surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
