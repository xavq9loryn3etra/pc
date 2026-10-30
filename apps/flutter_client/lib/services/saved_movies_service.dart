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

  // Singleton
  static final SavedMoviesService _instance = SavedMoviesService._internal();
  factory SavedMoviesService() => _instance;
  SavedMoviesService._internal();

  List<Movie> _favorites = [];
  Map<String, dynamic> _history =
      {}; // { id: { progress: 0.5, last_watched: ms } }
  Map<String, dynamic> _episodeHistory = {}; // { 'movieId_s_e': progress }
  // How long the copy actually played of each episode was, in seconds
  // ({ 'movieId_s_e': seconds }) — TMDB's runtime is the broadcast length
  // and is often off (shortened edits, recaps cut, or just rounded).
  Map<String, dynamic> _episodeLengths = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    // Load Favorites
    final favJson = prefs.getString(_favoritesKey);
    if (favJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(favJson);
        _favorites = decoded.map((e) => Movie.fromStorageJson(e)).toList();
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
    notifyListeners();
  }

  /// The length in minutes of the copy of this episode that was played, if
  /// it has been — see [saveEpisodeLength].
  int? getEpisodeMinutes(String movieId, int season, int episode) {
    final seconds = _episodeLengths['${movieId}_${season}_$episode'] as num?;
    if (seconds == null) return null;
    return (seconds / 60).round().clamp(1, 1 << 20);
  }

  /// Remembers how long the played copy of an episode is, so its card
  /// shows that (and the time left in it) instead of TMDB's runtime.
  Future<void> saveEpisodeLength(
      String movieId, int season, int episode, Duration length) async {
    if (length.inSeconds < 60) return;
    final key = '${movieId}_${season}_$episode';
    if (_episodeLengths[key] == length.inSeconds) return;
    _episodeLengths[key] = length.inSeconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_episodeLengthsKey, jsonEncode(_episodeLengths));
  }

  // --- Favorites API ---

  List<Movie> get favorites => List.unmodifiable(_favorites);

  bool isFavorite(String id) {
    return _favorites.any((m) => m.id == id);
  }

  Movie? getMovieFromHistory(String id) {
    if (_history.containsKey(id)) {
      try {
        return Movie.fromStorageJson(_history[id]['movie']);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  double? getEpisodeProgress(String movieId, int season, int episode) {
    final key = '${movieId}_${season}_$episode';
    if (_episodeHistory.containsKey(key)) {
      return (_episodeHistory[key] as num).toDouble();
    }
    return null;
  }

  Future<void> toggleFavorite(Movie movie) async {
    if (isFavorite(movie.id)) {
      _favorites.removeWhere((m) => m.id == movie.id);
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
    entries.sort((a, b) {
      final tA = a.value['last_watched'] as int? ?? 0;
      final tB = b.value['last_watched'] as int? ?? 0;
      return tB.compareTo(tA);
    });

    _historyCache = entries.map((e) {
      final movieJson = e.value['movie'];
      return Movie.fromStorageJson(movieJson);
    }).toList();
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
    
    if (_history.containsKey(movie.id)) {
      final prevMovie = Movie.fromStorageJson(_history[movie.id]['movie']);
      existingProgress = prevMovie.progress;
      
      // If we are passing specific season/episode, check if it changed
      if (season != null && episode != null) {
        if (prevMovie.currentSeason != season || prevMovie.currentEpisode != episode) {
          isSameEpisode = false;
          // We switched episodes! We should NOT use the old episode's progress.
          // Instead, look up the progress for the NEW episode we are switching to.
          existingProgress = _episodeHistory['${movie.id}_${season}_$episode'];
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
    _history[movie.id] = {
      'movie': movieToSave.toStorageJson(),
      'last_watched': DateTime.now().millisecondsSinceEpoch,
    };
    _historyCache = null;

    // Save specific episode progress
    if (season != null && episode != null && progress != null) {
      _episodeHistory['${movie.id}_${season}_$episode'] = progress;
      await _saveEpisodeHistory();
    }

    await _saveHistory();
    notifyListeners();
  }

  Future<void> removeFromHistory(String movieId) async {
    if (_history.containsKey(movieId)) {
      final imdbId = getMovieFromHistory(movieId)?.imdbId;
      _history.remove(movieId);
      _historyCache = null;
      await _saveHistory();

      // And which copy it last played: nothing to resume any more, so its
      // quality shouldn't come up as "Last watched".
      await LastPlayedTorrents.forgetTitle([movieId, if (imdbId != null) imdbId]);

      // Clear associated episode history
      _episodeHistory.removeWhere((key, _) => key.startsWith('${movieId}_'));
      await _saveEpisodeHistory();
      _episodeLengths.removeWhere((key, _) => key.startsWith('${movieId}_'));
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
