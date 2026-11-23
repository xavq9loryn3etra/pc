import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie.dart';
import 'saved_movies_service.dart';
import 'sync/sync_ledger.dart';
import 'tmdb_service.dart';

/// Whether the episode after a finished one is out (see
/// [NewEpisodeWatch.nextAfter]).
enum NextEpisodeState { out, notYet, unknown }

class NextEpisodeCheck {
  final NextEpisodeState state;

  /// The episode that's out, and its season ([state] out only).
  final int? season;
  final int? episode;

  const NextEpisodeCheck.out(int this.season, int this.episode)
      : state = NextEpisodeState.out;
  const NextEpisodeCheck._(this.state)
      : season = null,
        episode = null;

  static const notYet = NextEpisodeCheck._(NextEpisodeState.notYet);
  static const unknown = NextEpisodeCheck._(NextEpisodeState.unknown);

  @override
  String toString() => state == NextEpisodeState.out
      ? 'out S${season}E$episode'
      : state.name;
}

/// Series taken off Continue Watching because their latest episode was
/// watched (see PlayerScreen's dispose), waiting for the next one: when
/// TMDB says it's out, the series comes back to Continue Watching at that
/// episode, as on Netflix.
///
/// Kept per show (`tv_id`): the show as history stored it, the season and
/// episode finished, and when. Synced with the other devices (SyncData's
/// `waiting` section); when each show was last looked up is this device's
/// own.
class NewEpisodeWatch {
  static final NewEpisodeWatch _instance = NewEpisodeWatch._();
  factory NewEpisodeWatch() => _instance;
  NewEpisodeWatch._();

  static const String _key = 'waiting_new_episode_v1';
  static const String _checkKey = 'waiting_new_episode_next_check_v1';

  /// Its section in the sync (SyncLedger, SyncData).
  static const String section = 'waiting';

  /// The most shows kept; past that the longest waiting go.
  static const int maxShows = 50;

  /// How long a show waits before it's given up on.
  static const Duration keepFor = Duration(days: 730);

  /// How often each show is looked up: a day, or a week once TMDB says it
  /// has ended (a revival still brings it back).
  static const Duration checkEvery = Duration(days: 1);
  static const Duration checkEndedEvery = Duration(days: 7);

  /// After the app's started (or come back to the front), how long before
  /// looking, so it never competes with the first screens loading.
  static const Duration _startDelay = Duration(seconds: 30);

  /// 'tv_id' → {movie, season, episode, since}.
  Map<String, dynamic> _waiting = {};

  /// 'tv_id' → when to look it up next (ms). This device's own.
  Map<String, int> _nextCheck = {};

  Timer? _soon;
  Timer? _periodic;
  Future<void>? _running;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _waiting = _readMap(prefs.getString(_key));
    _nextCheck = {
      for (final e in _readMap(prefs.getString(_checkKey)).entries)
        if (e.value is num) e.key: (e.value as num).toInt(),
    };
  }

  static Map<String, dynamic> _readMap(String? raw) {
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (e) {
      debugPrint('Waiting-for-new-episode list unreadable: $e');
      return {};
    }
  }

  /// The shows waiting, by key.
  Map<String, dynamic> get waiting => Map.unmodifiable(_waiting);

  bool isWaiting(String showId) => _waiting.containsKey('tv_$showId');

  // --- What's next (pure) ---

  /// The season after [season] among [seasons] (the show's, by number),
  /// not the specials (season 0).
  static int? followingSeason(int season, Iterable<int> seasons) {
    final later = [for (final s in seasons) if (s > season && s > 0) s]..sort();
    return later.isEmpty ? null : later.first;
  }

  /// The first of [episodes] after episode [episode], if there is one.
  static Episode? laterInSeason(List<Episode> episodes, int episode) {
    Episode? best;
    for (final e in episodes) {
      if (e.episodeNumber <= episode) continue;
      if (best == null || e.episodeNumber < best.episodeNumber) best = e;
    }
    return best;
  }

  /// Whether [e] has aired: an air date that's today or earlier. Stricter
  /// than ![Episode.isUnreleased], which counts an episode with no date
  /// yet as out — TMDB often lists a new season's episodes before it
  /// dates them.
  static bool hasAired(Episode e) {
    final raw = e.airDate;
    if (raw == null || raw.isEmpty || DateTime.tryParse(raw) == null) {
      return false;
    }
    return !e.isUnreleased;
  }

  /// What comes after season [season] episode [episode], given that
  /// season's episodes ([seasonEpisodes]) and, when it was the season's
  /// last, the next season's number and episodes: the next in this
  /// season, else the next season's first — out (aired), not yet, or
  /// unknown (the season couldn't be read).
  static NextEpisodeCheck nextAfter({
    required int season,
    required int episode,
    required List<Episode> seasonEpisodes,
    int? followingSeason,
    List<Episode>? followingEpisodes,
  }) {
    if (seasonEpisodes.isEmpty) return NextEpisodeCheck.unknown;
    final later = laterInSeason(seasonEpisodes, episode);
    if (later != null) {
      return hasAired(later)
          ? NextEpisodeCheck.out(season, later.episodeNumber)
          : NextEpisodeCheck.notYet;
    }
    if (followingSeason == null) return NextEpisodeCheck.notYet;
    // Not listed yet (or not looked up): nothing out.
    final first = laterInSeason(followingEpisodes ?? const [], 0);
    if (first == null) return NextEpisodeCheck.notYet;
    return hasAired(first)
        ? NextEpisodeCheck.out(followingSeason, first.episodeNumber)
        : NextEpisodeCheck.notYet;
  }

  /// Drops from [waiting] what's waited longer than [keepFor] and, past
  /// [maxShows], the longest waiting. Returns the keys dropped.
  static Set<String> trim(Map<String, dynamic> waiting, {required int now}) {
    final dropped = <String>{};
    final oldest = now - keepFor.inMilliseconds;
    waiting.removeWhere((key, value) {
      final gone = _sinceOf(value) < oldest;
      if (gone) dropped.add(key);
      return gone;
    });
    if (waiting.length > maxShows) {
      final byAge = waiting.entries.toList()
        ..sort((a, b) {
          final t = _sinceOf(b.value).compareTo(_sinceOf(a.value));
          return t != 0 ? t : a.key.compareTo(b.key);
        });
      for (final e in byAge.skip(maxShows)) {
        waiting.remove(e.key);
        dropped.add(e.key);
      }
    }
    return dropped;
  }

  static int _sinceOf(Object? entry) {
    final t = entry is Map ? entry['since'] : null;
    return t is num ? t.toInt() : 0;
  }

  // --- Changes ---

  /// [show]'s latest episode out, season [season] episode [episode], was
  /// watched and it left Continue Watching: wait for the next one. Series
  /// only, and not for a special (season 0).
  Future<void> remember(Movie show,
      {required int season, required int episode}) async {
    if (show.type != 'tv' || season < 1) return;
    final key = show.storageKey;
    final now = SyncLedger().now();
    _waiting[key] = {
      'movie': {
        ...show.toStorageJson(),
        'current_season': season,
        'current_episode': episode,
        'progress': null,
      },
      'season': season,
      'episode': episode,
      'since': now,
    };
    // Just found not out: looked up again tomorrow.
    _nextCheck[key] = DateTime.now().add(checkEvery).millisecondsSinceEpoch;
    SyncLedger().touch(section, key);
    _trimAndForget(now);
    await _save();
  }

  /// The viewer's watching [showId] again by themselves: no need to wait
  /// for it any more. Cheap when it isn't waiting (called on every save
  /// of watch progress).
  void forget(String showId) {
    final key = 'tv_$showId';
    if (!_waiting.containsKey(key)) return;
    _waiting.remove(key);
    _nextCheck.remove(key);
    SyncLedger().remove(section, key);
    unawaited(_save());
  }

  void _trimAndForget(int now) {
    final dropped = trim(_waiting, now: now);
    if (dropped.isEmpty) return;
    // Not removals: every device trims the same way.
    SyncLedger().forget(section, dropped.contains);
    _nextCheck.removeWhere((key, _) => dropped.contains(key));
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_waiting));
    await prefs.setString(_checkKey, jsonEncode(_nextCheck));
  }

  // --- Looking up ---

  /// Starts looking a little after the app's first frame, then twice a
  /// day while it stays open (a TV or PC left on). Each show is still
  /// looked up at most once a day.
  void start() {
    checkSoon();
    _periodic ??=
        Timer.periodic(const Duration(hours: 12), (_) => unawaited(checkNow()));
  }

  /// Looks again shortly (the app came back to the front).
  void checkSoon() {
    if (_soon != null || _waiting.isEmpty) return;
    _soon = Timer(_startDelay, () {
      _soon = null;
      unawaited(checkNow());
    });
  }

  /// Looks up every show due a look, one at a time. One run at a time.
  /// [tmdb] and [ignoreSchedule] (every show, due or not) are for tests.
  Future<void> checkNow({TMDBService? tmdb, bool ignoreSchedule = false}) =>
      _running ??= _checkAll(tmdb ?? TMDBService(), ignoreSchedule)
          .whenComplete(() {
        _running = null;
      });

  Future<void> _checkAll(TMDBService tmdb, bool ignoreSchedule) async {
    _trimAndForget(SyncLedger().now());
    final history = SavedMoviesService();
    var changed = false;
    final keys = _waiting.keys.toList()
      ..sort((a, b) => _sinceOf(_waiting[b]).compareTo(_sinceOf(_waiting[a])));
    for (final key in keys) {
      final entry = _waiting[key];
      if (entry is! Map) continue;
      final movieJson = entry['movie'];
      final season = entry['season'];
      final episode = entry['episode'];
      if (movieJson is! Map<String, dynamic> ||
          season is! num ||
          episode is! num) {
        continue;
      }
      final id = '${movieJson['id']}';
      // Back on Continue Watching already (watched again here, or on
      // another device): nothing to wait for.
      if (history.getMovieFromHistory(id, type: 'tv') != null) {
        forget(id);
        continue;
      }
      final due = _nextCheck[key] ?? 0;
      if (!ignoreSchedule && due > DateTime.now().millisecondsSinceEpoch) {
        continue;
      }

      try {
        final result = await _lookUp(
            tmdb, id, season.toInt(), episode.toInt());
        if (result == null) continue; // Couldn't ask: next time.
        final (check, ended) = result;
        // Changed meanwhile (watched again, or a sync): leave it.
        if (!identical(_waiting[key], entry)) continue;
        if (check.state == NextEpisodeState.out) {
          if (history.getMovieFromHistory(id, type: 'tv') != null) {
            forget(id);
            continue;
          }
          final show = Movie.fromStorageJson(movieJson);
          debugPrint('[new episode] ${show.title}: S${check.season}'
              'E${check.episode} is out, back on Continue Watching');
          // With no progress; addToHistory takes it off this list too
          // (see forget).
          await history.addToHistory(
            Movie.fromStorageJson({...movieJson, 'progress': null}),
            season: check.season,
            episode: check.episode,
          );
          forget(id);
          changed = true;
        } else if (check.state == NextEpisodeState.notYet) {
          _nextCheck[key] = DateTime.now()
              .add(ended ? checkEndedEvery : checkEvery)
              .millisecondsSinceEpoch;
          await _save();
        }
      } catch (e) {
        debugPrint('New episode check failed for $key: $e');
      }
      // Easy on TMDB.
      if (!ignoreSchedule) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (changed) await history.flush();
  }

  /// What comes after [season] [episode] of show [id], and whether the
  /// show has ended; null when TMDB couldn't be asked.
  Future<(NextEpisodeCheck, bool)?> _lookUp(
      TMDBService tmdb, String id, int season, int episode) async {
    final show = await tmdb.showSeasons(id);
    if (show == null) return null;
    final episodes = await tmdb.getSeasonDetails(id, season);
    if (episodes.isEmpty) return null;
    final following = followingSeason(season, show.seasons);
    List<Episode>? next;
    if (following != null && laterInSeason(episodes, episode) == null) {
      next = await tmdb.getSeasonDetails(id, following);
    }
    return (
      nextAfter(
        season: season,
        episode: episode,
        seasonEpisodes: episodes,
        followingSeason: following,
        followingEpisodes: next,
      ),
      show.ended,
    );
  }

  // --- Sync (see SyncBridge) ---

  /// A copy of the list, as it's stored.
  Map<String, dynamic> exportForSync() =>
      jsonDecode(jsonEncode(_waiting)) as Map<String, dynamic>;

  /// Replaces the list with what a sync settled on, and stores it.
  Future<void> replaceFromSync(Map<String, dynamic> waiting) async {
    _waiting = waiting;
    _trimAndForget(SyncLedger().now());
    _nextCheck.removeWhere((key, _) => !_waiting.containsKey(key));
    try {
      await _save();
    } catch (e) {
      debugPrint('Error saving the synced waiting list: $e');
    }
  }

  /// For tests: forget everything.
  @visibleForTesting
  void reset() {
    _soon?.cancel();
    _soon = null;
    _periodic?.cancel();
    _periodic = null;
    _running = null;
    _waiting = {};
    _nextCheck = {};
  }
}
