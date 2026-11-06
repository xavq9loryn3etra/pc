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
///    clearly struggling switches; one only slightly behind, in two
///    separate sessions — a phone can just be busy or hot for a while —
///    unless the probe found it had room to spare ([_roomy]).
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
      final share = decision['share'];
      _probeShare = share is num ? share.toDouble() : null;
    } else {
      // New install, a new version or a new probe: measure again — a phone
      // once too slow gets another chance as the app gets lighter. And
      // start its count of borderline sessions over.
      _needsProbe = true;
      unawaited(prefs.remove(_strikesKey));
    }
    _update();
    _followPowerSave();
    // Not straight away: the first seconds after launch (loading the
    // home, decoding its pictures) are slow on any phone.
    Timer(const Duration(seconds: 5), _watch);
  }

  /// GlassProbe's verdict: whether the blur was too slow on this phone,
  /// and its typical frame's share of the frame's time ([share]).
  Future<void> probeResult({required bool tooSlow, double? share}) async {
    _needsProbe = false;
    _probeShare = share;
    await _decide(tooSlow: tooSlow);
  }

  // The probe's measure of this phone (see probeResult): under
  // [_roomyShare], it has room to spare for the glass, and the watcher
  // only steps in for sustained, clear slowness — not a heavy moment or
  // two, which twice switched a Galaxy S25 Ultra (drawing the probe in
  // 1.5–3 ms of its 8.3) to plain glass: once on opening a person's sheet
  // and pulling it closed, in each of two sessions.
  double? _probeShare;
  static const _roomyShare = 0.5;
  bool get _roomy => (_probeShare ?? 1) < _roomyShare;

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
          if (_probeShare != null) 'share': _probeShare,
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

  // What's judged is whether frames come one screen refresh after another
  // while something moves — a stutter is a refresh with nothing new on
  // it, a gap between frames. How long frames take to draw doesn't tell:
  // a Galaxy S25 Ultra at 120 Hz drew frames in 10–15 ms (8.3 ms between
  // refreshes) without missing one, its spare buffers absorbing it, and
  // was twice taken for too slow by rules built on that.
  //
  // Frames one after another make up a run (an animation, a scroll); a gap
  // of more than this many refreshes ends it — the screen was still, or
  // only updated now and then.
  static const _runBreakRefreshes = 4.0;
  // A gap of more than this many refreshes within a run is a stutter.
  static const _stutterRefreshes = 1.5;
  // How many gaps make up one judgement.
  static const _window = 60;
  // Stutters in a window: at least this share, twice in a session, is
  // clearly too slow, and switches at once…
  static const _clearlySlow = 0.40;
  // …and at least this share is borderline: a strike for this session —
  // each only from a second such window in a session (see _judge). A
  // Galaxy S25 Ultra, smooth with the glass, still had a window at 12%
  // while opening and closing pages over and over — 10% struck it twice.
  static const _borderline = 0.20;

  int? _lastVsync;
  int? _lastFinish;
  final List<bool> _run = [];
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
      _lastVsync = null;
      _lastFinish = null;
      return;
    }
    final refreshUs = frameMicros();
    for (final t in timings) {
      // Frames with nothing built, only a video's new picture shown, go
      // at the video's pace; they're no sign of the app keeping up or not.
      if (t.buildDuration.inMicroseconds < 50) continue;
      final vsync = t.timestampInMicroseconds(FramePhase.vsyncStart);
      final last = _lastVsync, finished = _lastFinish;
      _lastVsync = vsync;
      _lastFinish = t.timestampInMicroseconds(FramePhase.rasterFinish);
      if (last == null || finished == null) continue;
      final gap = vsync - last;
      if (gap > refreshUs * _runBreakRefreshes) {
        _run.clear();
        continue;
      }
      // Not asked for until well after the last frame was done: something
      // updating at its own pace, not a frame the phone was late with —
      // Ask's orb, 30 times a second (see AskClock), was taken for 3 in 4
      // frames missed at 120 Hz, and switched the S25 Ultra to plain.
      if (vsync - finished > refreshUs) continue;
      _run.add(gap > refreshUs * _stutterRefreshes);
      if (_run.length == _window) {
        _judge(_run);
        _run.clear();
      }
    }
  }

  // Windows this session past each mark. One alone is a heavy moment —
  // a person's sheet opening on a Galaxy S25 Ultra had 28% while it laid
  // out its whole page at once — not a phone that can't keep up: that
  // counts only when it happens again.
  int _slowWindows = 0;
  int _borderlineWindows = 0;

  void _judge(List<bool> stutters) {
    final share = stutters.where((s) => s).length / stutters.length;
    if (share >= _clearlySlow && ++_slowWindows >= 2) {
      _decide(tooSlow: true);
    } else if (!_roomy &&
        share >= _borderline &&
        ++_borderlineWindows >= 2 &&
        !_struckThisSession) {
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
