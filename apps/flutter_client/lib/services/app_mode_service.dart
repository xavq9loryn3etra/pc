import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../enums/app_mode.dart';

class AppModeService {
  static final AppModeService _instance = AppModeService._internal();
  static const String _storageKey = 'selected_app_mode';

  factory AppModeService() => _instance;

  AppModeService._internal();

  final ValueNotifier<AppMode> currentMode = ValueNotifier(AppMode.movies);

  Future<void> init() async {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_storageKey, mode.index);
  }
}
