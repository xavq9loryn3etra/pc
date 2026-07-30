import 'package:flutter/material.dart';
import '../services/movie_tab_service.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'favorites_screen.dart';
import 'settings_screen.dart';

const _kTabFadeDuration = Duration(milliseconds: 200);

/// Hosts the four movies-mode tabs, keeping every tab's widget alive so
/// switching preserves scroll position, search text, etc. and never
/// refetches data. Uses a Stack of per-tab AnimatedOpacity instead of a
/// plain IndexedStack (which keeps state too, but swaps instantly with no
/// transition) so switching still cross-fades like the old navigation did.
class MovieTabShell extends StatelessWidget {
  const MovieTabShell({super.key});

  static const _screens = [
    MovieHomeScreen(),
    SearchScreen(),
    FavoritesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BottomNavTab>(
      valueListenable: MovieTabService().currentTab,
      builder: (context, activeTab, _) {
        return Stack(
          children: [
            for (var i = 0; i < _screens.length; i++)
              IgnorePointer(
                ignoring: BottomNavTab.values[i] != activeTab,
                child: AnimatedOpacity(
                  opacity: BottomNavTab.values[i] == activeTab ? 1.0 : 0.0,
                  duration: _kTabFadeDuration,
                  curve: Curves.easeOut,
                  child: _screens[i],
                ),
              ),
          ],
        );
      },
    );
  }
}
