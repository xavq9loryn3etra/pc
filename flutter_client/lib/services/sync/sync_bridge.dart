import 'package:shared_preferences/shared_preferences.dart';

import '../audio_language_service.dart';
import '../saved_movies_service.dart';
import 'sync_data.dart';
import 'sync_ledger.dart';

/// Between the app's saved lists and SyncData: [gather] reads what's saved
/// on this device into a page, [apply] puts a combined page back.
///
/// Times come from SyncLedger. Anything saved before it existed has none,
/// so it gets one that loses to any real change: a history entry its
/// last-watched time, everything else a time near 1970, in list order.
class SyncBridge {
  /// The one global setting synced: the subtitle language.
  static const String subtitleLangKey = 'player_subtitle_lang';

  static bool isSyncedSetting(String key) =>
      key == subtitleLangKey || key.startsWith(AudioLanguageService.keyPrefix);

  /// This device's saved lists and choices, as a page.
  static Future<SyncData> gather() async {
    final prefs = await SharedPreferences.getInstance();
    await AudioLanguageService().ensureLoaded();
    final settings = <String, String>{
      for (final key in prefs.getKeys())
        if (isSyncedSetting(key))
          if (prefs.get(key) case final String value) key: value,
    };
    final saved = SavedMoviesService().exportForSync();
    return fromLocal(
      favorites: saved.favorites,
      history: saved.history,
      episodes: saved.episodes,
      lengths: saved.lengths,
      settings: settings,
      ledger: SyncLedger(),
    );
  }

  /// [gather], from given lists: for tests.
  static SyncData fromLocal({
    required List<Map<String, dynamic>> favorites,
    required Map<String, dynamic> history,
    required Map<String, dynamic> episodes,
    required Map<String, dynamic> lengths,
    required Map<String, String> settings,
    required SyncLedger ledger,
  }) {
    final data = SyncData();

    for (var i = 0; i < favorites.length; i++) {
      final movie = favorites[i];
      final key = '${movie['type'] ?? 'movie'}_${movie['id']}';
      data['list'][key] = {
        // Older than any real change, newest first as the list is.
        't': ledger.changedAt('list', key) ?? favorites.length - i,
        'v': movie,
      };
    }

    final watchedAt = <String, int>{};
    for (final e in history.entries) {
      final lastWatched = e.value is Map ? e.value['last_watched'] : null;
      final t = ledger.changedAt('history', e.key) ??
          (lastWatched is num ? lastWatched.toInt() : 1);
      watchedAt[e.key] = t;
      data['history'][e.key] = {'t': t, 'v': e.value};
    }

    for (final e in episodes.entries) {
      if (e.value is! num) continue;
      // 'tv_1399_1_3' belongs to 'tv_1399'.
      final parts = e.key.split('_');
      final show = parts.length >= 2 ? '${parts[0]}_${parts[1]}' : e.key;
      data['episodes'][e.key] = {
        't': ledger.changedAt('episodes', e.key) ?? watchedAt[show] ?? 1,
        'v': e.value,
      };
    }

    for (final e in lengths.entries) {
      if (e.value is num) data.lengths[e.key] = e.value as num;
    }

    for (final e in settings.entries) {
      data['settings'][e.key] = {
        't': ledger.changedAt('settings', e.key) ?? 1,
        'v': e.value,
      };
    }

    // What was removed here, unless it's back since.
    for (final section in SyncData.sections) {
      for (final e in ledger.removedIn(section).entries) {
        final have = data[section][e.key];
        if (have == null || SyncData.timeOf(have) < e.value) {
          data[section][e.key] = {'t': e.value, 'removed': true};
        }
      }
    }
    return data;
  }

  /// Puts [merged] in place of what's saved here, and records its times.
  ///
  /// Everything in memory is replaced before the first pause, so a change
  /// made meanwhile (SyncLedger.generation) is never overwritten: check for
  /// one right before calling this.
  static Future<void> apply(SyncData merged) async {
    final live = <String, List<MapEntry<String, Map<String, dynamic>>>>{
      for (final s in SyncData.sections) s: merged.live(s).toList(),
    };

    SyncLedger().replace(
      {
        for (final s in SyncData.sections)
          s: {for (final e in live[s]!) e.key: SyncData.timeOf(e.value)},
      },
      {
        for (final s in SyncData.sections)
          s: {
            for (final e in merged[s].entries)
              if (SyncData.isRemoved(e.value)) e.key: SyncData.timeOf(e.value),
          },
      },
    );

    // My List, newest first; a tie (two saved before sync) in key order,
    // the same on every device.
    final list = live['list']!
      ..sort((a, b) {
        final byTime = SyncData.timeOf(b.value).compareTo(SyncData.timeOf(a.value));
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });

    // Its lists are swapped before its first pause.
    final saving = SavedMoviesService().replaceFromSync(
      favorites: [
        for (final e in list)
          if (e.value['v'] is Map)
            Map<String, dynamic>.from(e.value['v'] as Map),
      ],
      history: {
        for (final e in live['history']!)
          if (e.value['v'] is Map) e.key: e.value['v'],
      },
      episodes: {
        for (final e in live['episodes']!)
          if (e.value['v'] is num) e.key: e.value['v'],
      },
      lengths: {...merged.lengths},
    );
    await saving;

    final settings = <String, String>{
      for (final e in live['settings']!)
        if (isSyncedSetting(e.key) && e.value['v'] is String)
          e.key: e.value['v'] as String,
    };
    await AudioLanguageService().applyFromSync({
      for (final e in settings.entries)
        if (e.key.startsWith(AudioLanguageService.keyPrefix)) e.key: e.value,
    });
    final subtitles = settings[subtitleLangKey];
    if (subtitles != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(subtitleLangKey, subtitles);
    }
  }
}
