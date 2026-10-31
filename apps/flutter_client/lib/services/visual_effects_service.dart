import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/glass_probe.dart';

/// Whether frosted-glass surfaces (see GlassBlur) skip their live blur and
/// use a plain translucent tint instead ([reduceGlass]). Decided by the app
/// itself, as no setting could be trusted to be found by the people who
/// need it: plain on phones too slow for the blur, and while battery saver
/// is on.
///
/// How fast the phone is gets measured twice over:
///  * once per app version, out of sight, by GlassProbe behind the mode
///    selector — so a slow phone has plain glass before its first page
///    with glass on it ([needsProbe], [probeResult]);
///  * all along, from the frames the app really draws ([_watch]): a phone
///    clearly struggling switches at once; one only slightly behind, in
///    two separate sessions — a phone can just be busy or hot for a while.
class VisualEffectsService {
  static final VisualEffectsService _instance =
      VisualEffectsService._internal();
  factory VisualEffectsService() => _instance;
  VisualEffectsService._internal();

  static const _decisionKey = 'glass_decision_v1';
  static const _strikesKey = 'glass_strikes_v1';

  final ValueNotifier<bool> reduceGlass = ValueNotifier(false);

  // Plain because the phone's too slow for the blur.
  bool _tooSlow = false;
  bool _powerSave = false;
  String? _version;

  /// Whether this version of the app has yet to measure the blur on this
  /// phone (see GlassProbe).
  bool get needsProbe => _needsProbe;
  bool _needsProbe = false;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    // The old "Reduce glass effects" setting, now decided automatically.
    unawaited(prefs.remove('reduce_glass_effects'));
    try {
      final info = await PackageInfo.fromPlatform();
      _version = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    final decision = _readJson(prefs.getString(_decisionKey));
    if (decision != null &&
        decision['version'] == _version &&
        decision['probe'] == GlassProbe.version) {
      _tooSlow = decision['plain'] == true;
    } else {
      // New install, a new version or a new probe: measure again — a phone
      // once too slow gets another chance as the app gets lighter.
      _needsProbe = true;
    }
    _update();
    _followPowerSave();
    // Not straight away: the first seconds after launch (loading the
    // home, decoding its pictures) are slow on any phone.
    Timer(const Duration(seconds: 5), _watch);
  }

  /// GlassProbe's verdict: whether the blur was too slow on this phone.
  Future<void> probeResult({required bool tooSlow}) async {
    _needsProbe = false;
    await _decide(tooSlow: tooSlow);
  }

  Future<void> _decide({required bool tooSlow}) async {
    _tooSlow = tooSlow;
    _update();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _decisionKey,
        jsonEncode({
          'version': _version,
          'probe': GlassProbe.version,
          'plain': tooSlow,
        }));
    if (tooSlow) await prefs.remove(_strikesKey);
  }

  void _update() => reduceGlass.value = _tooSlow || _powerSave;

  // ── Battery saver ──

  static const _powerSaveEvents = EventChannel('popcorn/power_save');

  void _followPowerSave() {
    if (!Platform.isAndroid) return;
    _powerSaveEvents.receiveBroadcastStream().listen((on) {
      _powerSave = on == true;
      _update();
    }, onError: (_) {});
  }

  // ── Watching the frames the app draws ──

  // Frames drawn one after another (an animation, a scroll) — a frame
  // more than this many frame-lengths after the last starts a new run.
  static const _gapFrames = 2.5;
  // How many frames in a row make up one judgement.
  static const _window = 60;
  // Late frames in a window: at least this share is clearly too slow,
  // and switches at once…
  static const _clearlySlow = 0.25;
  // …and at least this share is borderline: a strike for this session.
  static const _borderline = 0.10;

  final List<FrameTiming> _run = [];
  bool _struckThisSession = false;

  void _watch() => SchedulerBinding.instance.addTimingsCallback(_onTimings);

  void _onTimings(List<FrameTiming> timings) {
    // Only glass that's blurring can be too slow; battery saver aside.
    if (_tooSlow) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      return;
    }
    if (_powerSave) {
      _run.clear();
      return;
    }
    final frameUs = frameMicros();
    for (final t in timings) {
      if (_run.isNotEmpty &&
          t.timestampInMicroseconds(FramePhase.vsyncStart) -
                  _run.last.timestampInMicroseconds(FramePhase.vsyncStart) >
              frameUs * _gapFrames) {
        _run.clear();
      }
      _run.add(t);
      if (_run.length == _window) {
        _judge(_run, frameUs);
        _run.clear();
      }
    }
  }

  void _judge(List<FrameTiming> window, double frameUs) {
    final late = window
        .where((t) =>
            t.buildDuration.inMicroseconds > frameUs ||
            t.rasterDuration.inMicroseconds > frameUs)
        .length;
    final share = late / window.length;
    if (share >= _clearlySlow) {
      _decide(tooSlow: true);
    } else if (share >= _borderline && !_struckThisSession) {
      _struckThisSession = true;
      _strike();
    }
  }

  // A second session with a borderline window means too slow.
  Future<void> _strike() async {
    final prefs = await SharedPreferences.getInstance();
    final strikes = prefs.getInt(_strikesKey) ?? 0;
    if (strikes >= 1) {
      await _decide(tooSlow: true);
    } else {
      await prefs.setInt(_strikesKey, strikes + 1);
    }
  }

  /// How long one frame lasts on this screen, in microseconds.
  static double frameMicros() {
    final displays = SchedulerBinding.instance.platformDispatcher.displays;
    final hz = displays.isEmpty ? 60.0 : displays.first.refreshRate;
    return 1e6 / hz.clamp(30.0, 240.0);
  }

  static Map<String, dynamic>? _readJson(String? raw) {
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }
}
