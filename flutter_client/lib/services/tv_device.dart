import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the app is running on a TV (Android TV, Google TV, Fire TV):
/// driven with a remote, no touchscreen, and a screen that never turns.
/// Known from the start of main(), before the first frame.
class TvDevice {
  TvDevice._();

  static bool _isTv = false;
  static bool _lowMemory = false;

  static bool get isTv => _isTv;

  /// A TV with little memory (2 GB or less, or one Android itself calls
  /// low-memory — e.g. a Panasonic with 1.5 GB that switched itself off
  /// scrolling Search's posters and a title page, 24 Nov 2026): it gets
  /// lighter pictures — a smaller store of them, the next size down for
  /// backgrounds, logos and photos, posters decoded at the size they're
  /// drawn, and the Home slideshow held while another tab's open. A TV
  /// with more memory runs as before. `--dart-define=LOW_MEMORY_TEST=true`
  /// makes any device act as one (off in real builds), to try it out.
  static bool get isLowMemory => _lowMemory;

  /// A TV whose screen (as the app draws it) is HD or less: a 4K picture
  /// is wasted there, and a 1280-wide one fills it.
  static bool get hdScreen {
    if (!_isTv) return false;
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return false;
    final width = views.first.physicalSize.width;
    return width > 0 && width <= 1400;
  }

  static const _lowMemoryTest = bool.fromEnvironment('LOW_MEMORY_TEST');

  /// For tests: as on a TV (true) or not.
  @visibleForTesting
  static set debugIsTv(bool value) => _isTv = value;

  /// For tests: as a weak TV (true) or not.
  @visibleForTesting
  static set debugIsLowMemory(bool value) => _lowMemory = value;

  static Future<void> init() async {
    if (_lowMemoryTest) _lowMemory = true;
    if (!Platform.isAndroid) return;
    const channel = MethodChannel('popcorn/device');
    try {
      _isTv = await channel.invokeMethod<bool>('isTv') ?? false;
    } catch (_) {
      // Older app shell or no answer: treat it as a phone.
    }
    if (!_isTv) return;
    try {
      final memory = await channel.invokeMapMethod<String, Object?>('memory');
      final total = (memory?['totalBytes'] as num?)?.toDouble() ?? 0;
      final lowRam = memory?['lowRam'] == true;
      final perApp = (memory?['memoryClassMb'] as num?)?.toInt() ?? 0;
      // Android counts a little less than the box says (a "2 GB" TV
      // reports about 1.9 GB; a "3 GB" one about 2.8).
      _lowMemory = _lowMemory ||
          lowRam ||
          (total > 0 && total < 2.4e9) ||
          (perApp > 0 && perApp <= 128);
      print('[device] TV memory: ${(total / 1e9).toStringAsFixed(1)} GB, '
          'low-RAM ${lowRam ? 'yes' : 'no'}, $perApp MB per app '
          '→ ${_lowMemory ? 'light pictures' : 'full pictures'}');
    } catch (_) {
      // An older app shell: as before.
    }
  }
}
