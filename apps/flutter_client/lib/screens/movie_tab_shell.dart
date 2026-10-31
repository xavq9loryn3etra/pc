import 'package:flutter/material.dart';
import '../enums/app_mode.dart';
import '../services/app_mode_service.dart';
import '../services/movie_tab_service.dart';
import '../widgets/floating_bottom_nav_bar.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'favorites_screen.dart';
import 'settings_screen.dart';
import 'books_home_screen.dart';
import 'book_search_screen.dart';
import 'music_home_screen.dart';

const _kTabFadeDuration = Duration(milliseconds: 200);

/// Hosts the four mode tabs (Home, Search, Favorites, Settings), keeping
/// every tab's widget alive per mode so switching preserves scroll position,
/// search text, etc. and never refetches data. Uses a Stack of per-tab
/// AnimatedOpacity so switching cross-fades smoothly.
///
/// The bottom nav bar is one for all the tabs, over them, so it stays put
/// while they cross-fade under it. With a bar per tab, two see-through bars
/// faded over each other on every switch — the glass flickered lighter —
/// and the bar's own slide between the Home and Search layouts never ran.
class MovieTabShell extends StatelessWidget {
  const MovieTabShell({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppMode>(
      valueListenable: AppModeService().currentMode,
      builder: (context, mode, _) {
        final screens = _getScreensForMode(mode);

        return ValueListenableBuilder<BottomNavTab>(
          valueListenable: MovieTabService().currentTab,
          builder: (context, activeTab, _) {
            return Stack(
              children: [
                for (var i = 0; i < screens.length; i++)
                  IgnorePointer(
                    ignoring: BottomNavTab.values[i] != activeTab,
                    child: AnimatedOpacity(
                      opacity: BottomNavTab.values[i] == activeTab ? 1.0 : 0.0,
                      duration: _kTabFadeDuration,
                      curve: Curves.easeOut,
                      child: screens[i],
                    ),
                  ),
                _navBar(mode, activeTab),
              ],
            );
          },
        );
      },
    );
  }

  Widget _navBar(AppMode mode, BottomNavTab activeTab) {
    return ValueListenableBuilder<bool>(
      valueListenable: MovieHomeScreen.revealed,
      builder: (context, homeRevealed, _) {
        final onHome = activeTab == BottomNavTab.home;
        // Not built until the movie home has loaded: the bar plays a
        // staggered pop-in the first time it's built, which should show
        // as the home's skeleton fades rather than happen while it loads.
        if (onHome && mode == AppMode.movies && !homeRevealed) {
          return const SizedBox.shrink();
        }
        // Hidden, but kept, over the wide (desktop) home, which has no
        // bottom nav.
        final wide = MediaQuery.sizeOf(context).width > 800;
        return Positioned.fill(
          child: Visibility(
            visible: !(onHome && wide),
            maintainState: true,
            child: Stack(
              children: [FloatingBottomNavBar(activeTab: activeTab)],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _getScreensForMode(AppMode mode) {
    switch (mode) {
      case AppMode.movies:
        return const [
          MovieHomeScreen(),
          SearchScreen(),
          FavoritesScreen(),
          SettingsScreen(),
        ];
      case AppMode.books:
        return const [
          BooksHomeScreen(),
          BookSearchScreen(),
          FavoritesScreen(),
          SettingsScreen(),
        ];
      case AppMode.music:
        return const [
          MusicHomeScreen(),
          SearchScreen(),
          FavoritesScreen(),
          SettingsScreen(),
        ];
    }
  }
}
