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

  /// The desktop app (Windows; a native Mac or Linux build) is Popcorn
  /// only: no mode selector after the splash, no mode switch in Settings.
  /// An iPad or the iPad app on a Mac still has them. A TV is Popcorn only
  /// too (TvDevice.init runs before this is first read).
  static final bool canSwitchMode = kIsWeb ||
      !(Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux ||
          TvDevice.isTv);

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
