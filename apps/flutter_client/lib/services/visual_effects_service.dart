import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's "Reduce glass effects" setting: when on, frosted-glass
/// surfaces (see GlassBlur) skip their live blur and use a plain
/// translucent tint instead — for slower phones, where re-blurring the
/// background every frame while scrolling drops frames.
class VisualEffectsService {
  static final VisualEffectsService _instance =
      VisualEffectsService._internal();
  static const String _storageKey = 'reduce_glass_effects';

  factory VisualEffectsService() => _instance;

  VisualEffectsService._internal();

  final ValueNotifier<bool> reduceGlass = ValueNotifier(false);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    reduceGlass.value = prefs.getBool(_storageKey) ?? false;
  }

  Future<void> setReduceGlass(bool value) async {
    reduceGlass.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, value);
  }
}
