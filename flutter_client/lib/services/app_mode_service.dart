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

  /// Ramen, the anime mode: on phones, iPads and in the Windows app; not
  /// yet on a TV, which has no mode switch.
  static const bool ramen = true;

  /// The modes there are, in the order the switch shows them.
  static const List<AppMode> modes = [
    AppMode.movies,
    if (ramen) AppMode.anime,
    if (booksAndMusic) ...[AppMode.music, AppMode.books],
  ];

  /// Where the modes are, when there's more than Popcorn: phones, iPads
  /// (and the iPad app on a Mac) and the Windows app. Not on a TV
  /// (TvDevice.init runs before this is first read), or a native Mac or
  /// Linux build, which there isn't.
  static final bool canSwitchMode = modes.length > 1 &&
      (kIsWeb ||
          !(Platform.isMacOS || Platform.isLinux || TvDevice.isTv));

  /// Whether anime is Ramen's alone: where Ramen is, Popcorn leaves anime
  /// out (its home, search, My List, Continue Watching and Ask). A TV has
  /// no Ramen yet, so Popcorn keeps anime there.
  static final bool splitsAnime =
      canSwitchMode && modes.contains(AppMode.anime);

  /// Whether a title marked anime (or not) belongs in [mode]: Ramen shows
  /// only anime, Popcorn everything else (or everything, without Ramen).
  static bool belongsIn(AppMode mode, {required bool isAnime}) {
    if (!splitsAnime) return true;
    if (mode == AppMode.anime) return isAnime;
    if (mode == AppMode.movies) return !isAnime;
    return true;
  }

  /// [belongsIn] for the mode that's open.
  bool shows({required bool isAnime}) =>
      belongsIn(currentMode.value, isAnime: isAnime);

  Future<void> init() async {
    if (!canSwitchMode) {
      currentMode.value = AppMode.movies;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final savedModeIndex = prefs.getInt(_storageKey);
    if (savedModeIndex != null &&
        savedModeIndex >= 0 &&
        savedModeIndex < AppMode.values.length &&
        // One that's switched off now (Books, Music) opens Popcorn.
        modes.contains(AppMode.values[savedModeIndex])) {
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
