import 'package:shared_preferences/shared_preferences.dart';

/// The torrent each title — or each episode — last played from, remembered
/// under `last_played_torrent_ID` or `last_played_torrent_ID_SEASON_EPISODE`
/// (ID being the IMDb id, or the TMDB id for a title without one), so
/// its quality is offered first as "Last watched" and resuming reuses what
/// was downloaded.
class LastPlayedTorrents {
  static const _prefix = 'last_played_torrent_';

  /// Forgets what the title with [ids] (its TMDB id, and IMDb id if any)
  /// last played, its episodes' too — it was removed from watch history.
  static Future<void> forgetTitle(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith(_prefix)) continue;
      final rest = key.substring(_prefix.length);
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
      }
    }
  }
}
