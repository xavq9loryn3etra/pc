import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// When each synced item last changed on this device, and what was removed
/// when (see SyncData) — kept beside the lists themselves, which stay in
/// the layout every app version knows.
///
/// Kept whether sync is on or not: a title removed while it was off must
/// still be known as removed once it's on again, or a copy on another
/// device brings it back.
///
/// Times are on Google's clock as best known: this device's, corrected by
/// how far off it was at the last sync ([offsetMs]).
class SyncLedger {
  static final SyncLedger _instance = SyncLedger._();
  factory SyncLedger() => _instance;
  SyncLedger._();

  static const String _key = 'sync_ledger_v1';
  static const String _offsetKey = 'sync_clock_offset_ms';

  /// section → key → when it last changed.
  final Map<String, Map<String, int>> _changed = {};

  /// section → key → when it was removed.
  final Map<String, Map<String, int>> _removed = {};

  int offsetMs = 0;

  /// Goes up with every change recorded: a sync that read the lists checks
  /// it's unchanged before putting its result in their place.
  int generation = 0;

  /// Called with the section after anything is recorded — SyncService
  /// plans a sync.
  void Function(String section)? onChange;

  Timer? _saveTimer;
  bool _loaded = false;

  /// Now, on Google's clock as best known.
  int now() => DateTime.now().millisecondsSinceEpoch + offsetMs;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    offsetMs = prefs.getInt(_offsetKey) ?? 0;
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        // Anything recorded before this finished (it's newer) stays.
        _readInto(_changed, json['changed']);
        _readInto(_removed, json['removed']);
      } catch (e) {
        debugPrint('Sync ledger unreadable, starting afresh: $e');
      }
    }
    _loaded = true;
  }

  static void _readInto(Map<String, Map<String, int>> into, Object? raw) {
    if (raw is! Map) return;
    for (final section in raw.entries) {
      final keys = section.value;
      if (section.key is! String || keys is! Map) continue;
      final out = into.putIfAbsent(section.key as String, () => {});
      for (final e in keys.entries) {
        if (e.key is String && e.value is num) {
          out.putIfAbsent(e.key as String, () => (e.value as num).toInt());
        }
      }
    }
  }

  /// When [key] in [section] last changed here, if it's known.
  int? changedAt(String section, String key) => _changed[section]?[key];

  /// Everything removed from [section], and when.
  Map<String, int> removedIn(String section) =>
      Map.unmodifiable(_removed[section] ?? const {});

  /// [key] in [section] was added or changed, just now.
  void touch(String section, String key) {
    _changed.putIfAbsent(section, () => {})[key] = now();
    _removed[section]?.remove(key);
    _recorded(section);
  }

  /// Every one of [keys] in [section] changed, just now (titles brought
  /// back). With none, just says something changed.
  void touchAll(String section, Iterable<String> keys) {
    final t = now();
    final changed = _changed.putIfAbsent(section, () => {});
    for (final key in keys) {
      changed[key] = t;
      _removed[section]?.remove(key);
    }
    _recorded(section);
  }

  /// [key] in [section] was removed, just now.
  void remove(String section, String key) {
    _removed.putIfAbsent(section, () => {})[key] = now();
    _changed[section]?.remove(key);
    _recorded(section);
  }

  /// Forgets when [key] changed, without counting it as removed: for
  /// titles that fall off the end of history, which every device trims
  /// the same way.
  void forget(String section, bool Function(String key) test) {
    _changed[section]?.removeWhere((key, _) => test(key));
  }

  /// Replaces everything with what a sync settled on.
  void replace(
    Map<String, Map<String, int>> changed,
    Map<String, Map<String, int>> removed,
  ) {
    _changed
      ..clear()
      ..addAll({for (final e in changed.entries) e.key: {...e.value}});
    _removed
      ..clear()
      ..addAll({for (final e in removed.entries) e.key: {...e.value}});
    _scheduleSave();
  }

  /// Sets how far this device's clock is from Google's, and pulls back any
  /// time recorded ahead of Google's now (a clock that ran fast before the
  /// first sync), so it can't win every change for months.
  Future<void> setOffset(int offset) async {
    offsetMs = offset;
    final ceiling = now();
    for (final map in [..._changed.values, ..._removed.values]) {
      for (final e in map.entries) {
        if (e.value > ceiling) map[e.key] = ceiling;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_offsetKey, offset);
    _scheduleSave();
  }

  void _recorded(String section) {
    generation++;
    _scheduleSave();
    onChange?.call(section);
  }

  void _scheduleSave() {
    _saveTimer ??= Timer(const Duration(seconds: 2), flush);
  }

  /// Writes it to storage now.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    // Not over what's stored before that's been read.
    if (!_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode({'changed': _changed, 'removed': _removed}));
  }

  /// For tests: forget everything.
  void reset() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _changed.clear();
    _removed.clear();
    offsetMs = 0;
    onChange = null;
    _loaded = true;
  }
}
