import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

// Saved by index (AppModeService): new modes go at the end.
enum AppMode {
  movies,
  books,
  music,
  // Ramen: anime. Popcorn's films and shows, Japanese animation only,
  // with the same player, title pages and Ask.
  anime;

  /// Ramen's orange (the logo's).
  static const ramenOrange = Color(0xFFFD5602);

  Color get accentColor {
    switch (this) {
      case AppMode.movies:
        return AppTheme.primaryColor;
      case AppMode.music:
        return const Color(0xFFE91E63);
      case AppMode.books:
        return const Color(0xFFD4A574);
      case AppMode.anime:
        return ramenOrange;
    }
  }

  Color get gradientColor {
    switch (this) {
      case AppMode.movies:
        return const Color(0xFF2A1800);
      case AppMode.music:
        return const Color(0xFF420420);
      case AppMode.books:
        return const Color(0xFF2D1B0E);
      case AppMode.anime:
        return const Color(0xFF3A1300);
    }
  }

  String get label {
    switch (this) {
      case AppMode.movies:
        return 'Popcorn';
      case AppMode.music:
        return 'Groovy';
      case AppMode.books:
        return 'Library';
      case AppMode.anime:
        return 'Ramen';
    }
  }

  String get logoAsset {
    switch (this) {
      case AppMode.movies:
        return 'assets/logo.svg';
      case AppMode.music:
        return 'assets/music-app-logo.svg';
      case AppMode.books:
        return 'assets/book-app-logo.svg';
      case AppMode.anime:
        return 'assets/ramen-app-logo.svg';
    }
  }

  /// A short line on what it has: beside the logo on the chosen mode's
  /// card in the mode switch (ModeSwitchRow).
  String get tagline {
    switch (this) {
      case AppMode.movies:
        return 'Movies & TV shows';
      case AppMode.music:
        return 'Music';
      case AppMode.books:
        return 'Books';
      case AppMode.anime:
        return 'Anime series & films';
    }
  }

  /// Whether the logo is drawn in its own colours (Ramen's bowl), rather
  /// than one shape tinted with [accentColor].
  bool get logoHasOwnColors => this == AppMode.anime;

  /// Films and shows to watch: Popcorn and Ramen, which share the player,
  /// title pages, search and Ask.
  bool get isVideo => this == AppMode.movies || this == AppMode.anime;
}
