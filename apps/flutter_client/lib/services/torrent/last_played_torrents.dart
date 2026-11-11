import 'package:shared_preferences/shared_preferences.dart';

import '../../models/movie.dart';
import '../audio_language_service.dart';

/// The torrent each title — or each episode — last played from, remembered
/// under `last_played_torrent_ID` or `last_played_torrent_ID_SEASON_EPISODE`
/// (ID being the IMDb id, or the TMDB id for a title without one), so
/// its quality is offered first as "Last watched" and resuming reuses what
/// was downloaded.
///
/// For a title with a choice of audio language (see AudioLanguageService),
/// also the language it played in, under `last_played_language_…`: the
/// same copy often has both soundtracks, and is listed in both languages —
/// it's only "Last watched" in the one it was watched in.
class LastPlayedTorrents {
  static const _prefix = 'last_played_torrent_';
  static const _languagePrefix = 'last_played_language_';

  static String _languageKey(String key) =>
      _languagePrefix + key.substring(_prefix.length);

  /// Remembers that [key]'s torrent (just saved) played in [title]'s audio
  /// language as it's saved now.
  static Future<void> rememberLanguage(
      SharedPreferences prefs, String key, Movie title) async {
    if (!AudioLanguageService.appliesTo(title)) return;
    final languages = AudioLanguageService();
    await languages.ensureLoaded();
    await prefs.setString(_languageKey(key), languages.of(title).name);
  }

  /// The torrent [key] last played from — for a title with a choice of
  /// audio language, only if it played in [language] (by default, the one
  /// saved for it). One remembered before languages were (no language
  /// with it) counts as played in the saved one.
  static Future<String?> lastPlayed(
    SharedPreferences prefs,
    String key,
    Movie title, {
    AudioLanguage? language,
  }) async {
    final hash = prefs.getString(key);
    if (hash == null || !AudioLanguageService.appliesTo(title)) return hash;
    final languages = AudioLanguageService();
    await languages.ensureLoaded();
    final saved = languages.of(title);
    final stored = prefs.getString(_languageKey(key));
    final playedIn = stored == null
        ? saved
        : (stored == AudioLanguage.english.name
            ? AudioLanguage.english
            : AudioLanguage.original);
    return playedIn == (language ?? saved) ? hash : null;
  }

  /// Forgets what the title with [ids] (its TMDB id, and IMDb id if any)
  /// last played, its episodes' too — it was removed from watch history.
  static Future<void> forgetTitle(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      final prefix = key.startsWith(_prefix)
          ? _prefix
          : (key.startsWith(_languagePrefix) ? _languagePrefix : null);
      if (prefix == null) continue;
      final rest = key.substring(prefix.length);
      // "ID" or "ID_SEASON_EPISODE": the underscore keeps tt123 from matching
      // tt1234's keys.
      if (ids.any((id) => rest == id || rest.startsWith('${id}_'))) {
        await prefs.remove(key);
      }
    }
  }

  /// Forgets every title and episode that last played torrent [infoHash] —
  /// its download was deleted, so there's nothing left to resume from it.
  static Future<void> forgetTorrent(String infoHash) async {
    final prefs = await SharedPreferences.getInstance();
    final hash = infoHash.toLowerCase();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(_prefix) &&
          prefs.getString(key)?.toLowerCase() == hash) {
        await prefs.remove(key);
        await prefs.remove(_languageKey(key));
      }
    }
  }
}
