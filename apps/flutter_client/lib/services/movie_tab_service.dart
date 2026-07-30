import 'package:flutter/foundation.dart';
import '../widgets/floating_bottom_nav_bar.dart';

/// Tracks which movies-mode tab (Home/Search/Favorites/Settings) is active.
///
/// A singleton rather than widget state because FloatingBottomNavBar can be
/// reached from a screen pushed on top of MovieTabShell (e.g. the desktop
/// home layout's own search/favorites icons), which isn't a descendant of
/// the shell in the widget tree -- it needs a way to switch tabs that
/// doesn't depend on widget ancestry.
class MovieTabService {
  static final MovieTabService _instance = MovieTabService._internal();
  factory MovieTabService() => _instance;
  MovieTabService._internal();

  final ValueNotifier<BottomNavTab> currentTab =
      ValueNotifier(BottomNavTab.home);
}
