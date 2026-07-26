import 'package:flutter/material.dart';
import 'package:animations/animations.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import 'home_screen.dart'; // MovieHomeScreen
import 'books_home_screen.dart';
import 'music_home_screen.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppMode>(
      valueListenable: AppModeService().currentMode,
      builder: (context, mode, child) {
        return PageTransitionSwitcher(
          transitionBuilder: (
            Widget child,
            Animation<double> primaryAnimation,
            Animation<double> secondaryAnimation,
          ) {
            return FadeThroughTransition(
              animation: primaryAnimation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            );
          },
          child: _buildScreen(mode),
        );
      },
    );
  }

  Widget _buildScreen(AppMode mode) {
    switch (mode) {
      case AppMode.movies:
        return const MovieHomeScreen();
      case AppMode.books:
        return const BooksHomeScreen();
      case AppMode.music:
        return const MusicHomeScreen();
    }
  }
}
