import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum AppMode {
  movies,
  books,
  music;

  Color get accentColor {
    switch (this) {
      case AppMode.movies:
        return AppTheme.primaryColor;
      case AppMode.music:
        return const Color(0xFFE91E63);
      case AppMode.books:
        return const Color(0xFFD4A574);
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
    }
  }
}
