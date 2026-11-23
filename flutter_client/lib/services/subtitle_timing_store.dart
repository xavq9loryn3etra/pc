import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync/sync_ledger.dart';

/// A subtitle's timing on one copy of a video: mpv's sub-delay (seconds)
/// and sub-speed.
typedef SubtitleTiming = ({double delay, double speed});

/// The subtitle timings that listening confirmed, per copy (torrent) and
/// subtitle file: next time that copy plays with that subtitle, it's in
/// time at once. The same copy is the same file on every device, so they
/// go to the other devices too (SyncData's `subtitle_timings` section).
///
/// Each is kept under `<infohash>_<subtitle id>` (the infohash in lower
/// case) as `{d: delay, s: speed, t: when it last changed}`. The player
/// names them `subtitle_timing2_<infohash>_<subtitle id>`, as it did when
/// each was a setting of its own; both names are understood.
class SubtitleTimingStore {
  static final SubtitleTimingStore _instance = SubtitleTimingStore._();
  factory SubtitleTimingStore() => _instance;
  SubtitleTimingStore._();

  static const String _key = 'subtitle_timings_v1';

  /// How each was kept before this, one setting each:
  /// `subtitle_timing2_<infohash>_<subtitle id>` → `'delay|speed|confirmed'`.
  static const String legacyPrefix = 'subtitle_timing2_';

  /// Its section in the sync (SyncLedger, SyncData).
  static const String section = 'subtitle_timings';

  /// The most kept; past that the longest unchanged go.
  static const int maxKept = 500;

  /// Key → {d, s, t}.
  Map<String, Map<String, dynamic>> _timings = {};

  Future<void>? _loading;

  /// Reads them from storage, once (every method waits for it).
  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            for (final e in decoded.entries) {
              final entry = _entryFrom(e.value);
              if (e.key is String && entry != null) {
                // Anything kept before this finished (it's newer) stays.
                _timings.putIfAbsent(e.key as String, () => entry);
              }
            }
          }
        } catch (e) {
          debugPrint('Subtitle timings unreadable, starting afresh: $e');
        }
      }
      await _migrate(prefs);
    } catch (e) {
      debugPrint('Subtitle timings could not be read: $e');
    }
  }

  /// Takes in the timings kept the old way, one setting each, and removes
  /// those settings. Every start, so one written the old way since is
  /// still found. They're given a time near 1970, so any real change on
  /// another device wins over them.
  Future<void> _migrate(SharedPreferences prefs) async {
    final legacy =
        prefs.getKeys().where((k) => k.startsWith(legacyPrefix)).toList();
    if (legacy.isEmpty) return;
    var added = false;
    for (final prefsKey in legacy) {
      final key = keyOf(prefsKey);
      final timing = parseLegacy(prefs.get(prefsKey));
      if (timing != null && !_timings.containsKey(key)) {
        _timings[key] = {'d': timing.delay, 's': timing.speed, 't': 1};
        added = true;
      }
    }
    if (added) {
      _trim();
      await _save(prefs);
    }
    for (final prefsKey in legacy) {
      await prefs.remove(prefsKey);
    }
  }

  /// A timing kept the old way (`'delay|speed|confirmed'`), if it's one.
  static SubtitleTiming? parseLegacy(Object? value) {
    if (value is! String) return null;
    final parts = value.split('|');
    if (parts.length < 3 || parts[2] != 'confirmed') return null;
    final delay = double.tryParse(parts[0]);
    final speed = double.tryParse(parts[1]);
    if (delay == null || speed == null) return null;
    return (delay: delay, speed: speed);
  }

  /// [key] as it's kept: the player's name for it without its prefix.
  static String keyOf(String key) => key.startsWith(legacyPrefix)
      ? key.substring(legacyPrefix.length)
      : key;

  /// The key for [subtitleId]'s timing on the copy [infoHash].
  static String keyFor(String infoHash, String subtitleId) =>
      '${infoHash.toLowerCase()}_$subtitleId';

  static Map<String, dynamic>? _entryFrom(Object? raw) {
    if (raw is! Map) return null;
    final d = raw['d'], s = raw['s'], t = raw['t'];
    if (d is! num || s is! num || t is! num) return null;
    return {'d': d.toDouble(), 's': s.toDouble(), 't': t.toInt()};
  }

  // --- The player's ---

  /// The timing confirmed for [key], if one is kept.
  Future<SubtitleTiming?> timingOf(String key) async {
    await init();
    return kept(key);
  }

  /// [timingOf], without waiting: once [init] has finished.
  SubtitleTiming? kept(String key) {
    final entry = _timings[keyOf(key)];
    if (entry == null) return null;
    return (
      delay: (entry['d'] as num).toDouble(),
      speed: (entry['s'] as num).toDouble(),
    );
  }

  /// Keeps [timing] as confirmed for [key].
  Future<void> remember(String key, SubtitleTiming timing) async {
    await init();
    final k = keyOf(key);
    final have = _timings[k];
    if (have != null && have['d'] == timing.delay && have['s'] == timing.speed) {
      return;
    }
    _timings[k] = {
      'd': timing.delay,
      's': timing.speed,
      't': SyncLedger().now(),
    };
    SyncLedger().touch(section, k);
    _trim();
    await _save();
  }

  /// Forgets the timing kept for [key] here and on the other devices.
  Future<void> forget(String key) async {
    await init();
    final k = keyOf(key);
    if (_timings.remove(k) == null) return;
    SyncLedger().remove(section, k);
    await _save();
  }

  /// Past [maxKept], drops the longest unchanged — not as removals: every
  /// device trims the same way.
  void _trim() {
    final dropped = trim(_timings);
    if (dropped.isNotEmpty) SyncLedger().forget(section, dropped.contains);
  }

  /// Drops from [timings] the longest unchanged past [maxKept] (on a tie,
  /// the same ones on every device). Returns the keys dropped.
  static Set<String> trim(Map<String, Map<String, dynamic>> timings,
      {int max = maxKept}) {
    if (timings.length <= max) return const {};
    final byAge = timings.entries.toList()
      ..sort((a, b) {
        final t = (b.value['t'] as num).compareTo(a.value['t'] as num);
        return t != 0 ? t : a.key.compareTo(b.key);
      });
    final dropped = {for (final e in byAge.skip(max)) e.key};
    timings.removeWhere((key, _) => dropped.contains(key));
    return dropped;
  }

  Future<void> _save([SharedPreferences? prefs]) async {
    try {
      prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_timings));
    } catch (e) {
      debugPrint('Error saving subtitle timings: $e');
    }
  }

  // --- Sync (see SyncBridge) ---

  /// Every timing kept, as synced items: key → `{t, v: {d, s}}`.
  Future<Map<String, Map<String, dynamic>>> exportForSync() async {
    await init();
    return {
      for (final e in _timings.entries)
        e.key: {
          't': e.value['t'],
          'v': {'d': e.value['d'], 's': e.value['s']},
        },
    };
  }

  /// Replaces them with what a sync settled on — its live items, key →
  /// `{t, v: {d, s}}` — and stores them. Swapped before the first pause.
  Future<void> replaceFromSync(Map<String, Map<String, dynamic>> items) async {
    final next = <String, Map<String, dynamic>>{};
    for (final e in items.entries) {
      final v = e.value['v'];
      final entry = v is Map
          ? _entryFrom({'d': v['d'], 's': v['s'], 't': e.value['t']})
          : null;
      if (entry != null) next[e.key] = entry;
    }
    _timings = next;
    _trim();
    // Not read over what's just been put in place.
    _loading ??= Future.value();
    await _save();
  }

  /// For tests: forget everything (storage is left as it is).
  @visibleForTesting
  void reset() {
    _timings = {};
    _loading = null;
  }
}
