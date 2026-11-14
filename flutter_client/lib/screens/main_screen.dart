import 'package:flutter/material.dart';
import '../widgets/app_message.dart';
import 'package:flutter/services.dart';
import 'package:animations/animations.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/movie_tab_service.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import '../widgets/tv_focus.dart';
import 'movie_tab_shell.dart';

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
    // A TV remote inside a group (Ask's bar): out of it first (TvGroup).
    if (TvBack.handle()) return;
    // A wide layout's side column (see MovieTabShell) has its own pages,
    // which Back never reached: a TV remote's Back left a popup or a
    // title open in it. Those close first, then the column itself.
    final tabs = MovieTabService();
    final column = tabs.columnNavigator.currentState;
    if (column != null) {
      if (column.canPop()) {
        column.maybePop();
        return;
      }
      if (tabs.currentTab.value != BottomNavTab.home) {
        tabs.currentTab.value = BottomNavTab.home;
        tabs.restoreFocus();
        return;
      }
    }

    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < _kExitPressWindow) {
      SystemNavigator.pop();
      return;
    }

    _lastBackPress = now;
    showAppMessage(
      context,
      'Press back again to exit',
      aboveNavBar: true,
      duration: _kExitPressWindow,
    );
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
    return MovieTabShell(key: ValueKey(mode));
  }
}

/// MainScreen's route: a quick fade in from the mode selector, and when a
/// page slides in over it, the slide aside to the left that a sliding page
/// gives the one beneath it — drawn here, in a widget structure that
/// never changes. Left to the framework, that slide is wrapped around
/// this route's page by the page coming in (its delegatedTransition) and
/// unwrapped once it's gone, and each change of shape rebuilt the whole
/// main screen, every tab, as each page opened and closed: a ~50ms freeze
/// at both ends. The framework only wraps a route whose own
/// delegatedTransition differs from the incoming page's, so this one
/// takes on the incoming page's.
class MainScreenRoute extends PageRouteBuilder<void> {
  MainScreenRoute()
      : super(
          pageBuilder: (_, __, ___) => const MainScreen(),
          // Kept brief rather than instant purely so it doesn't read as a
          // rendering glitch (see ModeSelectorScreen._selectMode).
          transitionDuration: const Duration(milliseconds: 150),
        );

  // As CupertinoPageTransition.delegatedTransition slides it.
  static final _asideTween =
      Tween<Offset>(begin: Offset.zero, end: const Offset(-1.0 / 3.0, 0.0));

  // The page over this one's delegatedTransition (see above). Nothing is
  // under this route to take it up: it replaces the mode selector.
  DelegatedTransitionBuilder? _pageOverTransition;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _pageOverTransition;

  // Whether the page over this one slides it aside.
  bool get _slideAside => _pageOverTransition != null;

  void _takeTransitionOf(Route<dynamic>? pageOver) {
    _pageOverTransition = pageOver is PageRoute<dynamic> && canTransitionTo(pageOver)
        ? pageOver.delegatedTransition
        : null;
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    _takeTransitionOf(nextRoute);
    super.didChangeNext(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _takeTransitionOf(nextRoute);
    super.didPopNext(nextRoute);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: _slideAside
          ? CurvedAnimation(
              parent: secondaryAnimation,
              curve: Curves.linearToEaseOut,
              reverseCurve: Curves.easeInToLinear,
            ).drive(_asideTween)
          : const AlwaysStoppedAnimation(Offset.zero),
      transformHitTests: false,
      child: FadeTransition(opacity: animation, child: child),
    );
  }
}
