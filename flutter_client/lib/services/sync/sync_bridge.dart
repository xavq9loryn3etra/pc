import 'package:shared_preferences/shared_preferences.dart';

import '../audio_language_service.dart';
import '../gemini_key_service.dart';
import '../saved_movies_service.dart';
import '../torrent/last_played_torrents.dart';
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

  /// What My List's titles leave out of the page: the longest parts of
  /// it, and loaded afresh anyway when a title's page opens. A device keeps
  /// its own copies of them (see [apply]).
  static const _leftOutOfList = {'description', 'trailer_url'};

  /// The settings synced (all text): the subtitle language, each title's
  /// audio language, the Gemini key, and the copy each title and episode
  /// last played (and in which language).
  static bool isSyncedSetting(String key) =>
      key == subtitleLangKey ||
      key == GeminiKeyService.prefsKey ||
      key.startsWith(AudioLanguageService.keyPrefix) ||
      LastPlayedTorrents.prefixes.any(key.startsWith);

  /// This device's saved lists and choices, as a page.
  static Future<SyncData> gather() async {
    final prefs = await SharedPreferences.getInstance();
    await AudioLanguageService().ensureLoaded();
    final settings = <String, String>{
      for (final key in prefs.getKeys())
        if (isSyncedSetting(key))
          if (prefs.get(key) case final String value)
            if (value.isNotEmpty || key == subtitleLangKey) key: value,
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
        'v': {
          for (final e in movie.entries)
            if (!_leftOutOfList.contains(e.key)) e.key: e.value,
        },
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

  /// Titles in My List and Continue Watching on this device ([local]) that
  /// [account] — every device's pages combined — doesn't have: what a
  /// device signing in is asked about (keep them in the account, or not).
  static ({int list, int history}) onlyHere(SyncData local, SyncData account) {
    int count(String section) {
      final there = account.live(section).map((e) => e.key).toSet();
      return local.live(section).where((e) => !there.contains(e.key)).length;
    }

    return (list: count('list'), history: count('history'));
  }

  /// Puts [merged] in place of what's saved here, and records its times.
  /// With [replace], anything synced that [merged] doesn't have is taken
  /// away here too — the account's lists only, nothing of this device's.
  ///
  /// Everything in memory is replaced before the first pause, so a change
  /// made meanwhile (SyncLedger.generation) is never overwritten: check for
  /// one right before calling this.
  static Future<void> apply(SyncData merged, {bool replace = false}) async {
    final live = <String, List<MapEntry<String, Map<String, dynamic>>>>{
      for (final s in SyncData.sections) s: merged.live(s).toList(),
    };

    // What My List's titles left out of the page, kept from this device's
    // own copies where it has them.
    final saved = SavedMoviesService().exportForSync();
    final here = {
      for (final m in saved.favorites) '${m['type'] ?? 'movie'}_${m['id']}': m,
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
            {
              ...?here[e.key],
              ...Map<String, dynamic>.from(e.value['v'] as Map),
            },
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

    await _applySettings(merged, replace: replace);
  }

  static Future<void> _applySettings(SyncData merged, {required bool replace}) async {
    final prefs = await SharedPreferences.getInstance();
    final keep = <String, String>{
      for (final e in merged.live('settings'))
        if (isSyncedSetting(e.key) && e.value['v'] is String)
          e.key: e.value['v'] as String,
    };
    // Taken away: what was removed on another device, and, replacing,
    // whatever this device has that the account doesn't.
    final drop = <String>{
      for (final e in merged['settings'].entries)
        if (SyncData.isRemoved(e.value)) e.key,
      if (replace)
        for (final key in prefs.getKeys())
          if (isSyncedSetting(key) && !keep.containsKey(key)) key,
    }..removeWhere(keep.containsKey);

    final languages = AudioLanguageService();
    await languages.applyFromSync({
      for (final e in keep.entries)
        if (e.key.startsWith(AudioLanguageService.keyPrefix)) e.key: e.value,
    });
    await languages.removeFromSync(
        drop.where((k) => k.startsWith(AudioLanguageService.keyPrefix)));

    final gemini = GeminiKeyService();
    if (keep.containsKey(GeminiKeyService.prefsKey)) {
      await gemini.applyFromSync(keep[GeminiKeyService.prefsKey]);
    } else if (drop.contains(GeminiKeyService.prefsKey)) {
      await gemini.applyFromSync(null);
    }

    // The rest are read straight from storage where they're used.
    for (final e in keep.entries) {
      if (e.key.startsWith(AudioLanguageService.keyPrefix) ||
          e.key == GeminiKeyService.prefsKey) {
        continue;
      }
      if (prefs.getString(e.key) != e.value) await prefs.setString(e.key, e.value);
    }
    for (final key in drop) {
      if (key.startsWith(AudioLanguageService.keyPrefix) ||
          key == GeminiKeyService.prefsKey) {
        continue;
      }
      await prefs.remove(key);
    }
  }

  /// Takes away everything synced from this device — My List, Continue
  /// Watching, episode progress, language choices, the Gemini key, the
  /// copies last played — and what it recorded of them (signing out).
  static Future<void> clearLocal() async {
    await apply(SyncData(), replace: true);
    SyncLedger().clear();
  }
}
