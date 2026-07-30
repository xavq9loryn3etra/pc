import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animations/animations.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import 'movie_tab_shell.dart';
import 'books_home_screen.dart';
import 'music_home_screen.dart';

// MainScreen is the app's first/only route (ModeSelectorScreen replaces
// itself with this via pushReplacement), so there's nothing left to pop —
// the back button would otherwise hand straight to the OS and close the
// app on a single press. Require a second press within this window instead.
const _kExitPressWindow = Duration(seconds: 2);

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  DateTime? _lastBackPress;

  void _handleBackPress() {
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < _kExitPressWindow) {
      SystemNavigator.pop();
      return;
    }

    _lastBackPress = now;
    // The movies tab's FloatingBottomNavBar is painted as a Positioned
    // sibling above the Scaffold (not inside it), so a default bottom
    // SnackBar renders underneath it and is invisible. Floating it with
    // enough bottom margin to clear the nav bar (~108px + safe area, same
    // figure the tab screens already reserve for scroll content) fixes that.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Press back again to exit'),
        duration: _kExitPressWindow,
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, 110 + bottomInset),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackPress();
      },
      child: ValueListenableBuilder<AppMode>(
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
      ),
    );
  }

  Widget _buildScreen(AppMode mode) {
    switch (mode) {
      case AppMode.movies:
        return const MovieTabShell();
      case AppMode.books:
        return const BooksHomeScreen();
      case AppMode.music:
        return const MusicHomeScreen();
    }
  }
}
