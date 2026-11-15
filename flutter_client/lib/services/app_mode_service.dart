import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../enums/app_mode.dart';

import '../widgets/floating_bottom_nav_bar.dart';
import 'movie_tab_service.dart';
import 'tv_device.dart';

class AppModeService {
  static final AppModeService _instance = AppModeService._internal();
  static const String _storageKey = 'selected_app_mode';

  factory AppModeService() => _instance;

  AppModeService._internal();

  final ValueNotifier<AppMode> currentMode = ValueNotifier(AppMode.movies);

  /// Books and Music are switched off everywhere for now, so every device
  /// is Popcorn only: no three-mode introduction, no mode selector after
  /// the splash, no mode switch in Settings, and a movies-only welcome.
  /// Turn this back on to bring them back to phones and iPads.
  static const bool booksAndMusic = false;

  /// Where the modes would be when [booksAndMusic] is on: not in the
  /// desktop app (Windows; a native Mac or Linux build) or on a TV
  /// (TvDevice.init runs before this is first read). An iPad or the iPad
  /// app on a Mac has them.
  static final bool canSwitchMode = booksAndMusic &&
      (kIsWeb ||
          !(Platform.isWindows ||
              Platform.isMacOS ||
              Platform.isLinux ||
              TvDevice.isTv));

  Future<void> init() async {
    if (!canSwitchMode) {
      currentMode.value = AppMode.movies;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final savedModeIndex = prefs.getInt(_storageKey);
    if (savedModeIndex != null &&
        savedModeIndex >= 0 &&
        savedModeIndex < AppMode.values.length) {
      currentMode.value = AppMode.values[savedModeIndex];
    }
  }

  Future<void> setMode(AppMode mode) async {
    currentMode.value = mode;
    MovieTabService().currentTab.value = BottomNavTab.home;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_storageKey, mode.index);
  }
}
