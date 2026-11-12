import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/movie.dart';
import 'torrent/last_played_torrents.dart';

class SavedMoviesService with ChangeNotifier {
  static const String _favoritesKey = 'favorites_v1';
  static const String _historyKey = 'watch_history_v1';
  static const String _episodeHistoryKey = 'episode_history_v1';
  static const String _episodeLengthsKey = 'episode_lengths_v1';

  /// Set once history, episode progress and episode lengths have been
  /// re-keyed by type and id (see [migrateStorageKeys]).
  static const String _migratedKey = 'storage_key_migrated_v1';

  /// A copy of each stored value, taken before the migration changes it.
  static const String _backupSuffix = '_premigration_backup';

  /// The most titles history keeps; past that the least recently watched
  /// go, with their episode progress.
  static const int maxHistoryTitles = 200;

  /// Playback saves progress every few seconds; it's written to storage at
  /// most this often (see [flush]).
  static const Duration _saveInterval = Duration(seconds: 15);

  Timer? _saveTimer;
  bool _dirty = false;

  // Singleton
  static final SavedMoviesService _instance = SavedMoviesService._internal();
  factory SavedMoviesService() => _instance;
  SavedMoviesService._internal();

  List<Movie> _favorites = [];
  // { 'type_id': { movie: {...}, last_watched: ms } }. An entry saved with
  // no type stays under its bare id (see [migrateStorageKeys]).
  Map<String, dynamic> _history = {};
  // { 'tv_id_s_e': progress }. Episodes belong to shows, so always 'tv_'.
  Map<String, dynamic> _episodeHistory = {};
  // How long the copy actually played of each episode was, in seconds
  // ({ 'tv_id_s_e': seconds }) — TMDB's runtime is the broadcast length
  // and is often off (shortened edits, recaps cut, or just rounded).
  Map<String, dynamic> _episodeLengths = {};

  static String _episodeKey(String movieId, int season, int episode) =>
      'tv_${movieId}_${season}_$episode';

  /// Re-keys stored history, episode progress and episode lengths by type
  /// and id, once. TMDB's movie and show ids are separate number spaces, so
  /// movie 1399 and show 1399 used to share progress.
  ///
  /// Nothing is lost: the original favourites, history, episode progress
  /// and episode lengths are first copied to `*_premigration_backup` keys
  /// (never overwriting an earlier copy), and the flag is set last, so an
  /// interrupted run is simply repeated. An entry whose movie has no stored
  /// type stays under its bare id and is still found there. Anything that
  /// can't be read is left as it is, with the flag unset.
  static Future<void> migrateStorageKeys(SharedPreferences prefs) async {
    if (prefs.getBool(_migratedKey) == true) return;

    for (final key in [
      _favoritesKey,
      _historyKey,
      _episodeHistoryKey,
      _episodeLengthsKey,
    ]) {
      final raw = prefs.getString(key);
      if (raw != null && !prefs.containsKey('$key$_backupSuffix')) {
        await prefs.setString('$key$_backupSuffix', raw);
      }
    }

    Map<String, dynamic>? read(String key) {
      final raw = prefs.getString(key);
      if (raw == null) return <String, dynamic>{};
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    }

    final history = read(_historyKey);
    final episodeHistory = read(_episodeHistoryKey);
    final episodeLengths = read(_episodeLengthsKey);
    if (history == null || episodeHistory == null || episodeLengths == null) {
      print('Storage-key migration skipped: stored data is unreadable');
      return;
    }

    final newHistory = <String, dynamic>{};
    for (final e in history.entries) {
      var key = e.key;
      final movie = e.value is Map ? (e.value as Map)['movie'] : null;
      final type = movie is Map ? movie['type'] : null;
      // A bare id (no '_') whose movie says what it is: 'tv_1399'.
      if (!key.contains('_') && type is String && type.isNotEmpty) {
        key = '${type}_$key';
      }
      final clash = newHistory[key];
      if (clash == null || _lastWatchedOf(e.value) >= _lastWatchedOf(clash)) {
        newHistory[key] = e.value;
      }
    }

    final episodeKey = RegExp(r'^\d+_\d+_\d+$');
    Map<String, dynamic> withShowPrefix(Map<String, dynamic> m) => {
          for (final e in m.entries)
            episodeKey.hasMatch(e.key) ? 'tv_${e.key}' : e.key: e.value,
        };

    final newEpisodes = withShowPrefix(episodeHistory);
    final newLengths = withShowPrefix(episodeLengths);

    if (prefs.getString(_episodeHistoryKey) != null) {
      await prefs.setString(_episodeHistoryKey, jsonEncode(newEpisodes));
    }
    if (prefs.getString(_episodeLengthsKey) != null) {
      await prefs.setString(_episodeLengthsKey, jsonEncode(newLengths));
    }
    if (prefs.getString(_historyKey) != null) {
      await prefs.setString(_historyKey, jsonEncode(newHistory));
    }
    await prefs.setBool(_migratedKey, true);
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await migrateStorageKeys(prefs);
    } catch (e) {
      print("Error migrating storage keys: $e");
    }

    // Whatever is stored now is what's loaded: nothing pending to write.
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;

    _favorites = [];
    _history = {};
    _episodeHistory = {};
    _episodeLengths = {};

    // Load Favorites
    final favJson = prefs.getString(_favoritesKey);
    if (favJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(favJson);
        // One unreadable entry is left out, not the whole list.
        _favorites = [
          for (final e in decoded)
            if (_tryParse(e) case final movie?) movie,
        ];
      } catch (e) {
        print("Error loading favorites: $e");
      }
    }

    // Load History
    final historyJson = prefs.getString(_historyKey);
    if (historyJson != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(historyJson);
        _history = decoded;
      } catch (e) {
        print("Error loading history: $e");
      }
    }

    // Load Episode History
    final epHistoryJson = prefs.getString(_episodeHistoryKey);
    if (epHistoryJson != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(epHistoryJson);
        _episodeHistory = decoded;
      } catch (e) {
        print("Error loading episode history: $e");
      }
    }

    final lengthsJson = prefs.getString(_episodeLengthsKey);
    if (lengthsJson != null) {
      try {
        _episodeLengths = jsonDecode(lengthsJson);
      } catch (e) {
        print("Error loading episode lengths: $e");
      }
    }

    _historyCache = null;
    _historyById.clear();
    notifyListeners();
  }

  /// A stored movie, or null if it can't be read.
  static Movie? _tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return Movie.fromStorageJson(json);
    } catch (e) {
      print("Skipping unreadable saved movie: $e");
      return null;
    }
  }

  /// The movie stored in history entry [entry], or null.
  static Movie? _movieOf(Object? entry) =>
      entry is Map ? _tryParse(entry['movie']) : null;

  static int _lastWatchedOf(Object? entry) {
    final t = entry is Map ? entry['last_watched'] : null;
    return t is num ? t.toInt() : 0;
  }

  /// The length in minutes of the copy of this episode that was played, if
  /// it has been — see [saveEpisodeLength].
  int? getEpisodeMinutes(String movieId, int season, int episode) {
    final seconds = _episodeLengths[_episodeKey(movieId, season, episode)] as num?;
    if (seconds == null) return null;
    return (seconds / 60).round().clamp(1, 1 << 20);
  }

  /// Remembers how long the played copy of an episode is, so its card
  /// shows that (and the time left in it) instead of TMDB's runtime.
  Future<void> saveEpisodeLength(
      String movieId, int season, int episode, Duration length) async {
    if (length.inSeconds < 60) return;
    final key = _episodeKey(movieId, season, episode);
    if (_episodeLengths[key] == length.inSeconds) return;
    _episodeLengths[key] = length.inSeconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_episodeLengthsKey, jsonEncode(_episodeLengths));
  }

  // --- Favorites API ---

  List<Movie> get favorites => List.unmodifiable(_favorites);

  /// Whether the title with this [id] is a favourite. Pass its [type]
  /// ('movie' or 'tv'): without it a movie and a show with the same id
  /// can't be told apart and either one counts.
  bool isFavorite(String id, {String? type}) {
    return _favorites.any((m) => m.id == id && (type == null || m.type == type));
  }

  // Decoded once each till history changes: every poster asks, in every
  // build, and decoding the stored JSON each time added up.
  final Map<String, Movie?> _historyById = {};

  /// Whether the entry kept under [key] was saved with no type.
  bool _isTypeless(String key) {
    final entry = _history[key];
    final movie = entry is Map ? entry['movie'] : null;
    return movie is Map && movie['type'] == null;
  }

  /// The key the history entry for [id] is kept under, or null if there is
  /// none. With a [type] that's `type_id` — or, for a movie, an entry saved
  /// with no type under the bare id. Without one, whichever of a show, a
  /// movie or such an entry was watched last.
  String? _historyKeyFor(String id, String? type) {
    if (type != null) {
      final key = '${type}_$id';
      if (_history.containsKey(key)) return key;
      if (type == 'movie' && _history.containsKey(id) && _isTypeless(id)) {
        return id;
      }
      return null;
    }
    String? best;
    for (final key in ['tv_$id', 'movie_$id', id]) {
      if (!_history.containsKey(key)) continue;
      if (best == null ||
          _lastWatchedOf(_history[key]) > _lastWatchedOf(_history[best])) {
        best = key;
      }
    }
    return best;
  }

  /// The history entry for the title with this [id]. Pass its [type]
  /// ('movie' or 'tv') so a movie and a show with the same id stay apart.
  Movie? getMovieFromHistory(String id, {String? type}) {
    final key = _historyKeyFor(id, type);
    if (key == null) return null;
    return _historyById.putIfAbsent(key, () => _movieOf(_history[key]));
  }

  double? getEpisodeProgress(String movieId, int season, int episode) {
    final key = _episodeKey(movieId, season, episode);
    if (_episodeHistory.containsKey(key)) {
      return (_episodeHistory[key] as num).toDouble();
    }
    return null;
  }

  Future<void> toggleFavorite(Movie movie) async {
    if (isFavorite(movie.id, type: movie.type)) {
      _favorites.removeWhere((m) => m.id == movie.id && m.type == movie.type);
    } else {
      // Newest favorite first, matching how it reads as a "recently added"
      // list rather than a chronological log.
      _favorites.insert(0, movie);
    }
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      _favorites.map((m) => m.toStorageJson()).toList(),
    );
    await prefs.setString(_favoritesKey, encoded);
  }

  // --- History API ---

  // Cached so repeated reads in the same frame (this getter is called up to
  // 4x per home-screen build) don't re-sort and re-decode the whole map each
  // time. Invalidated wherever _history is mutated.
  List<Movie>? _historyCache;

  List<Movie> get history {
    if (_historyCache != null) return _historyCache!;

    // Return movies sorted by last_watched (descending)
    final entries = _history.entries.toList();
    entries.sort(
        (a, b) => _lastWatchedOf(b.value).compareTo(_lastWatchedOf(a.value)));

    // An entry that can't be read is left out rather than failing the
    // whole list (and every home-screen build with it).
    _historyCache = [
      for (final e in entries)
        if (_movieOf(e.value) case final movie?) movie,
    ];
    return _historyCache!;
  }

  Future<void> addToHistory(
    Movie movie, {
    int? season,
    int? episode,
    double? progress,
  }) async {
    // Get existing movie data to preserve progress if not updating
    double? existingProgress;
    bool isSameEpisode = true;
    
    // Where it's kept now (an entry saved with no type is moved to its
    // 'type_id' key below).
    final oldKey = _historyKeyFor(movie.id, movie.type);
    final prevMovie = oldKey == null ? null : _movieOf(_history[oldKey]);
    if (prevMovie != null) {
      existingProgress = prevMovie.progress;
      
      // If we are passing specific season/episode, check if it changed
      if (season != null && episode != null) {
        if (prevMovie.currentSeason != season || prevMovie.currentEpisode != episode) {
          isSameEpisode = false;
          // We switched episodes! We should NOT use the old episode's progress.
          // Instead, look up the progress for the NEW episode we are switching to.
          existingProgress = _episodeHistory[_episodeKey(movie.id, season, episode)];
        }
      }
    }

    // Create a copy of the movie with updated history data if provided
    final movieToSave = Movie(
      id: movie.id,
      title: movie.title,
      year: movie.year,
      image: movie.image,
      backdrop: movie.backdrop,
      rating: movie.rating,
      voteCount: movie.voteCount,
      description: movie.description,
      type: movie.type,
      inCinemas: movie.inCinemas,
      director: movie.director,
      cast: movie.cast,
      genres: movie.genres,
      logoUrl: movie.logoUrl,
      runtime: movie.runtime,
      mpaa: movie.mpaa,
      certification: movie.certification,
      seasons: movie.seasons,
      trailerUrl: movie.trailerUrl,
      imdbId: movie.imdbId,
      // Update history fields
      currentSeason: season ?? (isSameEpisode ? movie.currentSeason : null),
      currentEpisode: episode ?? (isSameEpisode ? movie.currentEpisode : null),
      // Preserve existing progress if new progress is null.
      // If we switched episodes and have no saved progress, it must be null (not the old movie's progress).
      progress: progress ?? existingProgress ?? (isSameEpisode ? movie.progress : null),
    );



    print(
        "DEBUG: Saving history for ID=${movie.id} progress=$progress (prev=$existingProgress)");
    if (oldKey != null && oldKey != movie.storageKey) _history.remove(oldKey);
    _history[movie.storageKey] = {
      'movie': movieToSave.toStorageJson(),
      'last_watched': DateTime.now().millisecondsSinceEpoch,
    };
    _historyCache = null;
    _historyById.clear();

    // Save specific episode progress
    if (season != null && episode != null && progress != null) {
      _episodeHistory[_episodeKey(movie.id, season, episode)] = progress;
    }
    _evictOldest();

    _markDirty();
    notifyListeners();
  }

  /// Drops the least recently watched titles (and their episodes) past
  /// [maxHistoryTitles].
  void _evictOldest() {
    while (_history.length > maxHistoryTitles) {
      final oldest = _history.entries.reduce((a, b) =>
          _lastWatchedOf(a.value) <= _lastWatchedOf(b.value) ? a : b);
      _history.remove(oldest.key);
      _historyById.remove(oldest.key);
      if (oldest.key.startsWith('tv_')) {
        final prefix = '${oldest.key}_';
        _episodeHistory.removeWhere((key, _) => key.startsWith(prefix));
        _episodeLengths.removeWhere((key, _) => key.startsWith(prefix));
      }
    }
    _historyCache = null;
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer ??= Timer(_saveInterval, flush);
  }

  /// Writes any history changes to storage now. Otherwise they're written
  /// at most every 15 seconds, since playback reports progress every few:
  /// call this when the app goes to the background and when a player
  /// closes.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty) return;
    _dirty = false;
    try {
      await _saveEpisodeHistory();
      await _saveHistory();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_episodeLengthsKey, jsonEncode(_episodeLengths));
    } catch (e) {
      print("Error saving history: $e");
      _dirty = true;
      _saveTimer ??= Timer(_saveInterval, flush);
    }
  }

  Future<void> removeFromHistory(String movieId, {String? type}) async {
    final historyKey = _historyKeyFor(movieId, type);
    if (historyKey != null) {
      final removed = getMovieFromHistory(movieId, type: type);
      final imdbId = removed?.imdbId;
      _history.remove(historyKey);
      _historyCache = null;
      _historyById.clear();
      await _saveHistory();

      // And which copy it last played: nothing to resume any more, so its
      // quality shouldn't come up as "Last watched".
      await LastPlayedTorrents.forgetTitle([movieId, if (imdbId != null) imdbId]);

      // Clear associated episode history — of a show only: a movie with
      // the same id has none, and the show's is not its to lose.
      if (removed?.type == 'tv') {
        final prefix = 'tv_${movieId}_';
        _episodeHistory.removeWhere((key, _) => key.startsWith(prefix));
        _episodeLengths.removeWhere((key, _) => key.startsWith(prefix));
      }
      await _saveEpisodeHistory();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_episodeLengthsKey, jsonEncode(_episodeLengths));
      notifyListeners();
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_history));
  }

  Future<void> _saveEpisodeHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_episodeHistoryKey, jsonEncode(_episodeHistory));
  }
}
