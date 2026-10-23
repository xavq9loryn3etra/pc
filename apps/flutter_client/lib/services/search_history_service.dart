import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's most recent movie/TV searches, newest first, kept on-device.
///
/// Only deliberate searches are recorded (keyboard submit, or opening a
/// result) — not every debounced as-you-type query, which would fill the
/// list with fragments like "stra" and "stran".
class SearchHistoryService {
  static final SearchHistoryService _instance =
      SearchHistoryService._internal();
  factory SearchHistoryService() => _instance;
  SearchHistoryService._internal();

  static const int maxEntries = 4;
  static const String _prefsKey = 'search_history_v1';

  final ValueNotifier<List<String>> entries = ValueNotifier(const []);
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      entries.value = List.unmodifiable(
        (prefs.getStringList(_prefsKey) ?? const []).take(maxEntries),
      );
    } catch (_) {}
  }

  /// Moves [query] to the top (case-insensitive de-dupe), keeping the
  /// newest [maxEntries].
  Future<void> add(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final updated = [
      q,
      ...entries.value.where((e) => e.toLowerCase() != q.toLowerCase()),
    ].take(maxEntries).toList();
    await _save(updated);
  }

  Future<void> remove(String query) async {
    await _save(entries.value.where((e) => e != query).toList());
  }

  Future<void> _save(List<String> updated) async {
    entries.value = List.unmodifiable(updated);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, updated);
    } catch (_) {}
  }
}
