import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Whether the app is running on a TV (Android TV, Google TV, Fire TV):
/// driven with a remote, no touchscreen, and a screen that never turns.
/// Known from the start of main(), before the first frame.
class TvDevice {
  TvDevice._();

  static bool _isTv = false;

  static bool get isTv => _isTv;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      _isTv = await const MethodChannel('popcorn/device')
              .invokeMethod<bool>('isTv') ??
          false;
    } catch (_) {
      // Older app shell or no answer: treat it as a phone.
    }
  }
}
